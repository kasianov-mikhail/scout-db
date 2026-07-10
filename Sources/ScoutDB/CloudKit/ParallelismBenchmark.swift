//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import CloudKit
import Foundation

/// Measures how CloudKit query latency scales with concurrent in-flight requests.
///
/// Prints one line per round and a summary table. Use it to re-tune
/// `cloudKitParallelismLimit` if CloudKit's own concurrency behavior changes.
///
public func benchmarkCloudKitParallelism(container: CKContainer, recordType: String = "Entity", counts: [Int] = [1, 2, 4, 8, 16], rounds: Int = 2) async {
    let counts = counts.filter { $0 > 0 }

    print("[ScoutDBBench] concurrency sweep \(counts), \(rounds) round(s) each, record type \(recordType)")

    do {
        try await requestLimiter.withAllSlots {
            await runSweep(container.publicCloudDatabase, recordType: recordType, counts: counts, rounds: rounds)
        }
    } catch {
        print("[ScoutDBBench] cancelled while waiting for exclusive CloudKit access")
    }
}

private func runSweep(_ database: CKDatabase, recordType: String, counts: [Int], rounds: Int) async {
    do {
        let warmup = try await rawBatch(database, recordType: recordType, count: 1)
        print("[ScoutDBBench] warm-up: \(warmup.wholeMilliseconds) ms")
    } catch {
        print("[ScoutDBBench] warm-up failed: \(describe(error))")
        return
    }

    var summary: [(count: Int, average: Int)] = []

    for count in counts {
        var durations: [Duration] = []
        for round in 1...rounds {
            do {
                let duration = try await rawBatch(database, recordType: recordType, count: count)
                durations.append(duration)
                print("[ScoutDBBench] \(count) in flight, round \(round): \(duration.wholeMilliseconds) ms")
            } catch {
                print("[ScoutDBBench] \(count) in flight, round \(round) FAILED: \(describe(error))")
            }
        }
        if durations.count > 0 {
            let batch = average(durations).wholeMilliseconds
            summary.append((count: count, average: batch))
            print("[ScoutDBBench] \(count) in flight: avg \(batch) ms per batch, \(batch / count) ms effective per request")
        }
    }

    guard summary.count > 0 else {
        print("[ScoutDBBench] no successful batches — see errors above")
        return
    }

    print("[ScoutDBBench] RESULT (count → batch ms → effective ms/request):")
    for entry in summary {
        print("[ScoutDBBench]   \(entry.count) → \(entry.average) ms → \(entry.average / entry.count) ms")
    }
}

/// Verifies that `cloudKitParallelismLimit` is still the right ceiling: that
/// requests scale cleanly up to the limit and stop scaling past it.
@discardableResult public func verifyParallelismBenchmark(container: CKContainer, recordType: String = "Entity") async -> Bool {
    print("[ScoutDBVerify] checking that \(cloudKitParallelismLimit) in-flight CloudKit requests is still the right limit")

    do {
        return try await requestLimiter.withAllSlots {
            await runVerification(container.publicCloudDatabase, recordType: recordType)
        }
    } catch {
        print("[ScoutDBVerify] cancelled while waiting for exclusive CloudKit access")
        return false
    }
}

private func runVerification(_ database: CKDatabase, recordType: String) async -> Bool {
    let limit = cloudKitParallelismLimit

    do {
        try await rawRead(database, recordType: recordType)

        let single = try await rawBatch(database, recordType: recordType, count: 1, rounds: 2)
        let atLimit = try await rawBatch(database, recordType: recordType, count: limit, rounds: 2)
        print("[ScoutDBVerify] 1 in flight: \(single.wholeMilliseconds) ms, \(limit) in flight: \(atLimit.wholeMilliseconds) ms")

        guard atLimit < single * 3 else {
            let factor = String(format: "%.1f", Double(atLimit.wholeMilliseconds) / Double(single.wholeMilliseconds))
            print(
                "[ScoutDBVerify] FAIL: \(limit) parallel requests cost ×\(factor) of a single one — "
                    + "scaling degraded, consider lowering cloudKitParallelismLimit "
                    + "(run benchmarkCloudKitParallelism for the full picture)")
            return false
        }

        let beyond = try await rawBatch(database, recordType: recordType, count: limit * 2)
        print("[ScoutDBVerify] \(limit * 2) in flight: \(beyond.wholeMilliseconds) ms")

        if beyond < atLimit * 3 / 2 {
            print(
                "[ScoutDBVerify] NOTE: \(limit * 2) in flight still scales cleanly — "
                    + "consider raising cloudKitParallelismLimit "
                    + "(run benchmarkCloudKitParallelism for the full picture)")
        } else {
            print("[ScoutDBVerify] OK: scaling stops past \(limit) in flight, limit confirmed")
        }
        return true
    } catch {
        print(
            "[ScoutDBVerify] FAIL: \(describe(error)) — a throttle error here means CloudKit "
                + "no longer tolerates \(cloudKitParallelismLimit * 2) in-flight requests; "
                + "consider lowering cloudKitParallelismLimit")
        return false
    }
}

private let resultsLimit = 20

private func makeQuery(_ recordType: String) -> CKQuery {
    CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
}

/// A single query against CloudKit, bypassing the limiter (but with the same
/// operation configuration and backstop timeout as every throttled call - a
/// silent server-side stall here would otherwise pin every claimed slot).
private func rawRead(_ database: CKDatabase, recordType: String) async throws {
    _ = try await withRequestTimeout(requestTimeout) {
        try await database.configuredWith(configuration: .scoutDB) { database in
            try await database.records(matching: makeQuery(recordType), desiredKeys: [], resultsLimit: resultsLimit)
        }
    }
}

private func rawBatch(_ database: CKDatabase, recordType: String, count: Int, rounds: Int = 1) async throws -> Duration {
    var durations: [Duration] = []
    for _ in 0..<rounds {
        let duration = try await measure {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        try await rawRead(database, recordType: recordType)
                    }
                }
                try await group.waitForAll()
            }
        }
        durations.append(duration)
    }
    return average(durations)
}

private func measure(_ body: () async throws -> Void) async rethrows -> Duration {
    try await ContinuousClock().measure {
        try await body()
    }
}

private func average(_ durations: [Duration]) -> Duration {
    durations.reduce(.zero, +) / durations.count
}

extension Duration {
    fileprivate var wholeMilliseconds: Int {
        Int(self / .milliseconds(1))
    }
}

private func describe(_ error: Error) -> String {
    guard let ckError = error as? CKError else {
        return String(describing: error)
    }
    let retryAfter = ckError.retryAfterSeconds.map { ", retry after \($0)s" } ?? ""
    return "CKError \(ckError.code.rawValue): \(ckError.localizedDescription)\(retryAfter)"
}
