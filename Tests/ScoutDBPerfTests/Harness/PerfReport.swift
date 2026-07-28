//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

/// Prints the sweep as two tables and writes it as JSON.
///
/// Nothing here asserts: the numbers are the deliverable, and a budget that
/// fails the build would have to be maintained for every scenario on every
/// database. The JSON is what makes two runs — before and after an
/// optimization — diffable.
///
enum PerfReport {
    private struct Column<Row>: Sendable {
        let title: String
        let width: Int
        let value: @Sendable (Row) -> String
    }

    // MARK: - Measurements

    private static let columns: [Column<PerfResult>] = [
        Column(title: "feature", width: 14) { $0.feature },
        Column(title: "scenario", width: 34) { $0.scenario },
        Column(title: "size", width: 7) { $0.size.rawValue },
        Column(title: "iter", width: 5) { "\($0.iterations)" },
        Column(title: "query", width: 6) { "\($0.app[.query])" },
        Column(title: "cont", width: 5) { "\($0.app[.continuation])" },
        Column(title: "fetch", width: 6) { "\($0.app[.fetch])" },
        Column(title: "save", width: 5) { "\($0.app[.save])" },
        Column(title: "modify", width: 7) { "\($0.app[.modify])" },
        Column(title: "cas", width: 5) { "\($0.app[.conditionalSave])" },
        Column(title: "other", width: 6) { "\(other(of: $0.app))" },
        Column(title: "total", width: 6) { "\($0.app.total)" },
        Column(title: "req/op", width: 7) { number($0.perOperation) },
        Column(title: "sql", width: 5) { "\($0.sql)" },
        Column(title: "over", width: 8) { $0.overhead.map { "\(number($0))×" } ?? "—" },
        Column(title: "wire", width: 6) { "\($0.wire.total)" },
        Column(title: "err", width: 4) { $0.failure == nil ? "\($0.app.failures)" : "!" },
    ]

    /// The table's opening, printed before the sweep starts.
    ///
    /// Rows stream out as each scenario settles rather than arriving as one
    /// block at the end: a full sweep runs for minutes, and a silent terminal
    /// gives no way to tell a slow scenario from a stuck one.
    ///
    static func header(title: String) -> String {
        [
            "", title,
            "requests the store made per call, against the statements a relational database would spend on the same work",
            String(repeating: "=", count: width(of: columns)),
            columns.map { pad($0.title, $0.width) }.joined(),
            String(repeating: "-", count: width(of: columns)),
        ].joined(separator: "\n")
    }

    static func row(_ result: PerfResult, after previous: PerfResult?) -> String {
        let line = columns.map { pad($0.value(result), $0.width) }.joined()
        guard let previous, previous.feature != result.feature || previous.size != result.size else { return line }
        return "\n" + line
    }

    static func footer(_ results: [PerfResult]) -> String {
        var lines = [String(repeating: "-", count: width(of: columns)), summary(results)]
        for result in results where result.failure != nil {
            lines.append("!  \(result.feature)/\(result.scenario) [\(result.size.rawValue)]: \(result.failure ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Projection

    /// One scenario's cost fitted across the databases it ran on.
    ///
    /// The fit is a power law, `requests ≈ base · (N / N_base) ^ k`, taken from
    /// the two largest databases the sweep covered — the smallest one saturates
    /// at a single request for anything that scans, so a slope through it would
    /// read flatter than the truth.
    ///
    struct Projection: Sendable {
        let feature: String
        let scenario: String
        let sql: Int
        let cost: PerfScenario.Cost?
        let measured: [(size: DatasetSize, perOperation: Double)]
        let exponent: Double
        let base: Double
        let baseRecords: Int

        func requests(at records: Int) -> Double {
            guard base > 0, baseRecords > 0 else { return base }
            return base * pow(Double(records) / Double(baseRecords), exponent)
        }

        /// How many requests the call spends for each statement SQL would
        /// spend, on the largest database measured.
        var overhead: Double? {
            sql > 0 ? base / Double(sql) : nil
        }

        var growth: String {
            switch exponent {
            case ..<0.15: "flat"
            case ..<0.75: "sub"
            case ..<1.15: "linear"
            default: "super"
            }
        }
    }

    /// The volumes the fit is projected to, beyond the largest database measured.
    static let levels = [100_000, 1_000_000, 10_000_000]

    /// Where a scenario with no declared cost stops being worth a look and
    /// starts being a failure.
    ///
    /// The table calls anything above 0.15 growing, which is deliberately
    /// sensitive — a row worth reading, not a verdict. Failing the sweep is a
    /// verdict, so it waits for growth no measurement wobble explains: at 0.3
    /// the ten-million projection is some six times the twenty-thousand cost.
    ///
    static let leakingExponent = 0.3

    static func projections(_ results: [PerfResult]) -> [Projection] {
        var order: [String] = []
        var grouped: [String: [PerfResult]] = [:]
        for result in results where result.failure == nil {
            let key = "\(result.feature)\u{1}\(result.scenario)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(result)
        }
        return order.compactMap { key in
            guard let rows = grouped[key], let last = rows.last else { return nil }
            let measured = rows.sorted { $0.size.records < $1.size.records }.map { (size: $0.size, perOperation: $0.perOperation) }
            var exponent = 0.0
            if measured.count > 1 {
                let (near, far) = (measured[measured.count - 2], measured[measured.count - 1])
                if near.perOperation > 0, far.perOperation > 0, near.size.records != far.size.records {
                    let span = log(Double(far.size.records) / Double(near.size.records))
                    exponent = max(0, log(far.perOperation / near.perOperation) / span)
                }
            }
            let base = measured.last ?? (size: last.size, perOperation: last.perOperation)
            return Projection(
                feature: last.feature, scenario: last.scenario, sql: last.sql, cost: last.cost, measured: measured, exponent: exponent,
                base: base.perOperation, baseRecords: base.size.records)
        }
    }

    /// The projection table's columns, sized from the run's own sizes.
    ///
    /// `projected` drops the fit and everything downstream of it, for a run that
    /// measured one database and so has no slope to project along.
    ///
    private static func projectionColumns(sample: Projection, projected: Bool = true) -> [Column<Projection>] {
        var columns: [Column<Projection>] = [
            Column(title: "feature", width: 14) { $0.feature },
            Column(title: "scenario", width: 34) { $0.scenario },
            Column(title: "sql", width: 5) { "\($0.sql)" },
        ]
        for (index, point) in sample.measured.enumerated() {
            columns.append(
                Column(title: volume(point.size.records), width: 8) { projection in
                    projection.measured.indices.contains(index) ? number(projection.measured[index].perOperation) : "—"
                })
        }
        columns.append(Column(title: "over", width: 8) { $0.overhead.map { "\(number($0))×" } ?? "—" })
        guard projected else {
            columns.append(Column(title: "cost", width: 10) { $0.cost?.rawValue ?? "—" })
            return columns
        }
        columns.append(Column(title: "k", width: 6) { String(format: "%.2f", $0.exponent) })
        columns.append(Column(title: "cost", width: 10) { $0.cost?.rawValue ?? "—" })
        for level in levels {
            columns.append(Column(title: volume(level), width: 10) { number($0.requests(at: level)) })
        }
        columns.append(
            Column(title: "over@\(volume(levels[levels.count - 1]))", width: 12) { projection in
                guard projection.sql > 0 else { return "—" }
                return "\(number(projection.requests(at: levels[levels.count - 1]) / Double(projection.sql)))×"
            })
        return columns
    }

    /// What the run concluded: how many scenarios grew, and what their growth
    /// means — with the ones claiming to be bounded named, since those are the
    /// rows a reader has to act on.
    private static func verdict(_ projections: [Projection]) -> [String] {
        let growing = projections.filter { $0.exponent >= 0.15 }
        let overhead = growing.filter { $0.cost == nil }
        var lines = [
            "\(projections.count) scenarios · \(projections.count - growing.count) hold flat at any volume · \(growing.count) grow with the database",
            "of those, \(growing.filter { $0.cost == .result }.count) cost what they return, "
                + "\(growing.filter { $0.cost == .elective }.count) are passes over the whole database, "
                + "and \(overhead.count) are bounded work that should not have grown",
        ]
        for projection in overhead.sorted(by: { $0.exponent > $1.exponent }) {
            lines.append("  ↳ \(projection.feature) · \(projection.scenario)")
        }
        return lines
    }

    static func projectionTable(_ results: [PerfResult]) -> String {
        let projections = projections(results)
        guard let sample = projections.first, sample.measured.count > 1 else {
            return "\nProjection needs at least two databases; run without SCOUTDB_PERF_SIZES to fit one."
        }
        let columns = projectionColumns(sample: sample)

        var lines = [
            "", "Projection — requests per call at larger volumes",
            "fitted as base × (N / \(volume(sample.baseRecords))) ^ k from the two largest databases measured; k is the growth exponent",
            String(repeating: "=", count: width(of: columns)),
            columns.map { pad($0.title, $0.width) }.joined(),
            String(repeating: "-", count: width(of: columns)),
        ]
        var growth: String?
        for projection in projections.sorted(by: { ($0.exponent, $0.base) > ($1.exponent, $1.base) }) {
            if let growth, growth != projection.growth {
                lines.append("")
            }
            growth = projection.growth
            lines.append(columns.map { pad($0.value(projection), $0.width) }.joined())
        }
        lines.append(String(repeating: "-", count: width(of: columns)))
        lines += verdict(projections)
        return lines.joined(separator: "\n")
    }

    // MARK: - Step summary

    /// The run as a page of its own: the verdict, the scenarios that grew when
    /// they claimed they would not, and what every feature costs.
    ///
    /// The full table is a hundred and thirty lines under the output of every
    /// other test in the run, which nobody scrolls to. This is the same numbers
    /// arranged to be read. The group that should be empty comes first, because
    /// a row there is why the job failed; the feature roll-up under it covers
    /// the rest of the sweep, since a scenario that holds flat still has a
    /// coefficient against SQL worth knowing, and a reader looking up one
    /// feature should not have to know in advance whether it grew.
    ///
    static func page(_ results: [PerfResult]) -> String {
        let projections = projections(results)
        var lines = ["## ScoutDB — request cost by feature", "", summary(results)]
        guard let sample = projections.first else { return lines.joined(separator: "\n") }
        let fitted = sample.measured.count > 1

        if fitted {
            lines += ["", "```", verdict(projections).joined(separator: "\n"), "```"]
            if sample.measured.count < DatasetSize.allCases.count {
                lines += [
                    "",
                    "> \(sample.measured.count) of \(DatasetSize.allCases.count) databases measured. The fit reads one extra page as a curve at "
                        + "these sizes, so a row below is a lead, not a verdict — only a full sweep decides.",
                ]
            }
        } else {
            lines += ["", "> One database measured, so nothing is fitted; run without `SCOUTDB_PERF_SIZES` for the projection."]
        }

        let columns = projectionColumns(sample: sample, projected: fitted)
        if fitted {
            let grew = projections.filter { $0.exponent >= 0.15 && $0.cost == nil }.sorted { ($0.exponent, $0.base) > ($1.exponent, $1.base) }
            if grew.count > 0 {
                lines += block(
                    "Bounded work that grew", note: "work that claimed to cost the same whatever the database holds, and did not",
                    columns: columns, rows: grew)
            }
        }
        lines += block(
            "Every feature", note: "one call of each of the feature's scenarios, added up, against the statements SQL would spend on the same work",
            columns: featureColumns, rows: features(projections).sorted { ($0.overhead ?? 0, $0.requests) > ($1.overhead ?? 0, $1.requests) })

        lines += [
            "", "<details>", "<summary>Every scenario</summary>", "", "```",
            columns.map { pad($0.title, $0.width) }.joined(),
            String(repeating: "-", count: width(of: columns)),
        ]
        var feature: String?
        for projection in projections {
            if let feature, feature != projection.feature { lines.append("") }
            feature = projection.feature
            lines.append(columns.map { pad($0.value(projection), $0.width) }.joined())
        }
        lines += ["```", "", "</details>"]
        return lines.joined(separator: "\n")
    }

    /// One feature's scenarios as a single line.
    private struct Feature: Sendable {
        let name: String
        let scenarios: Int
        /// One call of each of the feature's scenarios, on the largest database
        /// measured.
        let requests: Double
        let sql: Int
        let growing: Int
        /// The scenario that spends the most requests per statement.
        let worst: Projection?

        var overhead: Double? {
            sql > 0 ? requests / Double(sql) : nil
        }
    }

    private static let featureColumns: [Column<Feature>] = [
        Column(title: "feature", width: 18) { $0.name },
        Column(title: "scen", width: 6) { "\($0.scenarios)" },
        Column(title: "req/op", width: 8) { number($0.requests) },
        Column(title: "sql", width: 6) { "\($0.sql)" },
        Column(title: "over", width: 8) { $0.overhead.map { "\(number($0))×" } ?? "—" },
        Column(title: "grows", width: 7) { "\($0.growing)" },
        Column(title: "worst", width: 8) { $0.worst?.overhead.map { "\(number($0))×" } ?? "—" },
        Column(title: "its scenario", width: 34) { $0.worst?.scenario ?? "—" },
    ]

    private static func features(_ projections: [Projection]) -> [Feature] {
        var order: [String] = []
        var grouped: [String: [Projection]] = [:]
        for projection in projections {
            if grouped[projection.feature] == nil { order.append(projection.feature) }
            grouped[projection.feature, default: []].append(projection)
        }
        return order.map { name in
            let rows = grouped[name] ?? []
            return Feature(
                name: name, scenarios: rows.count, requests: rows.reduce(0) { $0 + $1.base }, sql: rows.reduce(0) { $0 + $1.sql },
                growing: rows.filter { $0.exponent >= 0.15 }.count,
                worst: rows.max { ($0.overhead ?? -1) < ($1.overhead ?? -1) })
        }
    }

    private static func block<Row>(_ title: String, note: String, columns: [Column<Row>], rows: [Row]) -> [String] {
        var lines = [
            "", "### \(title)", "", note, "", "```",
            columns.map { pad($0.title, $0.width) }.joined(),
            String(repeating: "-", count: width(of: columns)),
        ]
        lines += rows.map { row in columns.map { pad($0.value(row), $0.width) }.joined() }
        lines.append("```")
        return lines
    }

    /// Appends the page wherever the run was told to leave it — on CI, the
    /// job's step summary, which the workflow renders on the run's own page.
    static func write(_ page: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = (page + "\n").data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - JSON

    static func write(_ results: [PerfResult], name: String) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dump = Dump(rows: results.map(Row.init), projections: projections(results).map(ProjectionRow.init))
        guard let data = try? encoder.encode(dump) else { return nil }
        let url = destination(name: name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private static func destination(name: String) -> URL {
        if let path = ProcessInfo.processInfo.environment["SCOUTDB_PERF_OUTPUT"] {
            let base = URL(fileURLWithPath: path)
            return base.pathExtension == "json" ? base : base.appendingPathComponent("\(name).json")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/perf/\(name).json")
    }

    private static func summary(_ results: [PerfResult]) -> String {
        let requests = results.reduce(0) { $0 + $1.app.total }
        let wire = results.reduce(0) { $0 + $1.wire.total }
        let statements = results.reduce(0) { $0 + $1.sql * $1.iterations }
        let failed = results.filter { $0.failure != nil }.count
        let errors = results.reduce(0) { $0 + $1.app.failures }
        let overhead = statements > 0 ? Double(requests) / Double(statements) : 0
        return String(
            format: "%d scenarios · %d requests (%d at the wire) · %d SQL statements · %.1f× overall · %d failed calls · %d broken scenarios",
            results.count, requests, wire, statements, overhead, errors, failed)
    }

    private static func other(of tally: PerfRecorder.Tally) -> Int {
        tally[.subscriptionSave] + tally[.subscriptionDelete] + tally[.subscriptionList]
    }

    private static func width<Row>(of columns: [Column<Row>]) -> Int {
        columns.reduce(0) { $0 + $1.width }
    }

    private static func number(_ value: Double) -> String {
        if value >= 1_000 { return String(format: "%.0f", value) }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    /// A record count as a short label: 20k, 1M, 10M.
    private static func volume(_ records: Int) -> String {
        if records >= 1_000_000 { return "\(records / 1_000_000)M" }
        if records >= 1_000 { return "\(records / 1_000)k" }
        return "\(records)"
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        let trimmed = value.count > width - 1 ? String(value.prefix(width - 2)) + "…" : value
        return trimmed.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private struct Dump: Encodable {
        let rows: [Row]
        let projections: [ProjectionRow]
    }

    private struct Row: Encodable {
        let feature: String
        let scenario: String
        let size: String
        let records: Int
        let iterations: Int
        let requests: [String: Int]
        let total: Int
        let perOperation: Double
        let sqlStatements: Int
        let overhead: Double?
        let wireTotal: Int
        let recordsCarried: Int
        let failedCalls: Int
        let failure: String?

        init(_ result: PerfResult) {
            feature = result.feature
            scenario = result.scenario
            size = result.size.rawValue
            records = result.size.records
            iterations = result.iterations
            requests = Dictionary(uniqueKeysWithValues: result.app.counts.map { ($0.key.rawValue, $0.value) })
            total = result.app.total
            perOperation = rounded(result.perOperation)
            sqlStatements = result.sql
            overhead = result.overhead.map(rounded)
            wireTotal = result.wire.total
            recordsCarried = result.app.records
            failedCalls = result.app.failures
            failure = result.failure
        }
    }

    private struct ProjectionRow: Encodable {
        let feature: String
        let scenario: String
        let sql: Int
        let measured: [String: Double]
        let exponent: Double
        let growth: String
        let cost: String
        let projected: [String: Double]

        init(_ projection: Projection) {
            feature = projection.feature
            scenario = projection.scenario
            sql = projection.sql
            cost = projection.cost?.rawValue ?? "bounded"
            measured = Dictionary(uniqueKeysWithValues: projection.measured.map { ("\($0.size.records)", rounded($0.perOperation)) })
            exponent = rounded(projection.exponent)
            growth = projection.growth
            projected = Dictionary(uniqueKeysWithValues: levels.map { ("\($0)", rounded(projection.requests(at: $0))) })
        }
    }
}

private func rounded(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}
