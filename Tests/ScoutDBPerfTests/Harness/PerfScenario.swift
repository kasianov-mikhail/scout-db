//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// One measured operation of one feature.
///
/// The body is called `iterations` times per database, one call at a time; it
/// addresses corpus records through `world.corpus` and names anything it writes
/// through `world.fresh(_:_:)`, so repeats do not overwrite each other.
///
struct PerfScenario: Sendable {
    /// Which decorator, if any, the store talks through.
    enum Stack: Sendable {
        case direct
        case offline
    }

    /// Why this scenario's cost may grow with the database — stated where it
    /// would otherwise be read as a defect.
    ///
    /// The sweep measures requests per call; it cannot tell by itself whether a
    /// call that costs more on a larger database is leaking or simply carrying
    /// more. A scenario names the reason when there is one, and leaves it unset
    /// when there is not: an unset cost is the claim that this work is bounded
    /// whatever the database holds, and so the claim the sweep is really
    /// testing. Growth there is overhead, and the row to look at first.
    ///
    enum Cost: String, Sendable {
        /// The cost tracks what the call returns, is handed, or must touch — a
        /// batch of writes, a page run, a feed of changes, a cascade's
        /// children. A dump of every record cannot cost less than reading them.
        case result
        /// A pass over the whole database the caller opted into — a migration,
        /// an integrity sweep, a log compaction — or a fallback a declared view
        /// would have avoided.
        case elective
    }

    let feature: String
    let name: String
    /// What the same work costs a relational database, in statements.
    ///
    /// The yardstick for the overhead column, and a judgment call per scenario
    /// rather than a measurement, so it is written down next to the body it
    /// describes. The conventions:
    ///
    /// - A set-based statement counts once however many rows it touches: one
    ///   `INSERT` of four hundred rows, one `UPDATE … WHERE`, one `SELECT` with
    ///   joins, grouping and a limit.
    /// - One statement per page of a paginated read.
    /// - A read-modify-write counts one when SQL expresses it in place
    ///   (`SET points = points + 10`) and two when it genuinely needs the old
    ///   row first.
    /// - `BEGIN`/`COMMIT` are free; the statements inside the transaction count.
    /// - Nothing is charged for what an engine keeps on its own: an aggregate
    ///   view is a materialized view, a unique key is a constraint, an audit log
    ///   is a trigger, a cascade is a foreign key, a change feed is one `SELECT`
    ///   over `updated_at`. That is where the overhead comes from.
    ///
    let sql: Int
    /// Why this scenario is allowed to grow, or nil when it is not; see ``Cost``.
    let cost: Cost?
    let stack: Stack
    /// Whether the body changes the database, and so whether the corpus has to
    /// be restored before the next scenario.
    let writes: Bool
    /// Overrides the database's default repeat count, for bodies too heavy to
    /// repeat eight times over twenty thousand records.
    let iterations: Int?
    /// Arranges state the measurement needs but should not be charged for.
    ///
    /// The zone feed a sync scenario then drains, say. Runs once, before the
    /// tallies are zeroed and before the clock starts.
    ///
    let setUp: (@Sendable (PerfWorld) async throws -> Void)?
    let body: @Sendable (PerfWorld, Int) async throws -> Void

    init(
        _ feature: String, _ name: String, sql: Int, cost: Cost? = nil, stack: Stack = .direct, writes: Bool = true, iterations: Int? = nil,
        setUp: (@Sendable (PerfWorld) async throws -> Void)? = nil, body: @escaping @Sendable (PerfWorld, Int) async throws -> Void
    ) {
        self.feature = feature
        self.name = name
        self.sql = sql
        self.cost = cost
        self.stack = stack
        self.writes = writes
        self.iterations = iterations
        self.setUp = setUp
        self.body = body
    }

    func repeats(on size: DatasetSize) -> Int {
        iterations ?? size.iterations
    }

    var slug: String {
        "\(feature).\(name)"
    }
}

/// What one scenario cost on one database.
struct PerfResult: Sendable {
    let feature: String
    let scenario: String
    let size: DatasetSize
    let iterations: Int
    /// What the same operation costs a relational database, in statements.
    let sql: Int
    /// Why this scenario is allowed to grow, or nil when it is not.
    let cost: PerfScenario.Cost?
    let app: PerfRecorder.Tally
    let wire: PerfRecorder.Tally
    let failure: String?

    /// Requests one call of the scenario made.
    var perOperation: Double {
        iterations > 0 ? Double(app.total) / Double(iterations) : 0
    }

    /// How many requests the store spends for each statement SQL would spend.
    var overhead: Double? {
        sql > 0 ? perOperation / Double(sql) : nil
    }
}
