//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

/// Every feature, measured over a small, a medium and a large database, one
/// request at a time.
///
/// Prints what each operation costs in database requests, what the same work
/// would cost a relational database in statements, the ratio between the two,
/// and a projection of both to larger volumes.
///
/// The projection's `cost` column says how to read a scenario that grows: a
/// dump or a sweep that carries more on a bigger database is doing its job,
/// while bounded work that grows is overhead. The footer counts the three and
/// names the scenarios in the last group.
///
/// Run it deliberately:
///
/// ```
/// SCOUTDB_PERF=1 swift test --filter PerfSuite
/// SCOUTDB_PERF=1 SCOUTDB_PERF_SIZES=small,medium swift test --filter PerfSuite
/// ```
///
/// Gated, because a full sweep runs for minutes: seeding twenty thousand
/// records and scanning them page by page costs far more in the in-memory
/// double — a linear array behind a lock — than the requests it counts would
/// cost against CloudKit. Narrow it with `SCOUTDB_PERF_SIZES` while working on
/// a scenario, and point `SCOUTDB_PERF_OUTPUT` somewhere to keep the JSON.
/// `SCOUTDB_PERF_SUMMARY` takes a path to append the run's verdict and its
/// growing scenarios to, as markdown — on CI, the job's step summary.
///
/// The sweep repeats exactly — same corpus, same order, same counts — so two
/// runs are diffable column for column.
///
@Suite("Performance", .enabled(if: ProcessInfo.processInfo.environment["SCOUTDB_PERF"] != nil))
struct PerfSuite {
    @Test("Every feature, one request at a time")
    func sweep() async throws {
        print(PerfReport.header(title: "ScoutDB — request cost by feature"))
        var previous: PerfResult?
        let results = try await PerfRunner.sweep(PerfScenarios.all) { result in
            print(PerfReport.row(result, after: previous))
            previous = result
        }
        print(PerfReport.footer(results))
        print(PerfReport.projectionTable(results))
        if let url = PerfReport.write(results, name: "requests") {
            print("json: \(url.path)")
        }
        if let path = ProcessInfo.processInfo.environment["SCOUTDB_PERF_SUMMARY"] {
            PerfReport.write(PerfReport.page(results), to: path)
        }
        for result in results where result.failure != nil {
            Issue.record("\(result.feature)/\(result.scenario) [\(result.size.rawValue)] did not run: \(result.failure ?? "")")
        }
        // Only a full sweep can accuse a scenario: the exponent is fitted from the two
        // largest databases measured, and the two small ones are a handful of requests
        // apart, where one page more reads as a curve.
        for leak in PerfReport.projections(results)
        where leak.cost == nil && leak.measured.count == DatasetSize.allCases.count && leak.exponent >= PerfReport.leakingExponent {
            let measured = leak.measured.map { "\($0.size.rawValue) \(String(format: "%.1f", $0.perOperation))" }.joined(separator: ", ")
            Issue.record(
                """
                \(leak.feature)/\(leak.scenario) grows with the database: \(measured), k=\(String(format: "%.2f", leak.exponent)).
                Bounded work is what this sweep tests, so either the cost belongs to the work — say so with `cost: .result` \
                or `cost: .elective` on the scenario — or the call is doing more than it should.
                """)
        }
    }
}
