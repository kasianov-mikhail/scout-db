//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

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
