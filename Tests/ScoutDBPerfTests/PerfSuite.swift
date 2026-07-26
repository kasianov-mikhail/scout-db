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
        for result in results where result.failure != nil {
            Issue.record("\(result.feature)/\(result.scenario) [\(result.size.rawValue)] did not run: \(result.failure ?? "")")
        }
    }
}
