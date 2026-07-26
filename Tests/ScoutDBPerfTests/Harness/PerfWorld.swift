//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB
import ScoutDBTesting

/// Everything one scenario runs against: the store, the corpus it was seeded
/// from, and the two tallies around the stack.
///
/// The stack is the same shape for every feature — the in-memory double, a
/// wire-side tally, an optional cache decorator, an app-side tally, the store:
///
/// ```
/// InMemoryDatabase → ObservedDatabase(wire) → [cache] → ObservedDatabase(app) → EntityStore
/// ```
///
/// Without a cache the two tallies agree; with one, the difference between them
/// is what the cache saved.
///
struct PerfWorld: @unchecked Sendable {
    let corpus: Corpus
    let backing: InMemoryDatabase
    let database: any CloudDatabase
    let registry: SchemaRegistry
    let store: EntityStore
    let app: PerfRecorder
    let wire: PerfRecorder
    /// The cache decorator, when the scenario asked for one.
    let cache: (any CloudDatabase)?
    /// Distinguishes the records one scenario run writes from every other run's.
    let runID: String

    var size: DatasetSize {
        corpus.size
    }

    var offlineCache: OfflineCache? {
        cache as? OfflineCache
    }

    var replicaCache: ReplicaCache? {
        cache as? ReplicaCache
    }

    var migrator: Migrator {
        Migrator(database: database, registry: registry, keyProvider: PerfKeyProvider(), zoneID: PerfSchema.zoneID)
    }

    /// A uuid no corpus record holds, unique per scenario run and iteration.
    func fresh(_ prefix: String, _ iteration: Int) -> String {
        "\(prefix)-\(runID)-\(iteration)"
    }
}

/// Holds one size's database across the whole sweep and hands each scenario a
/// clean world to run in.
///
/// Rebuilding the corpus per scenario would dominate the sweep, so the records
/// are restored from the pristine snapshot instead — and only after a scenario
/// that actually wrote something.
///
final class PerfBench {
    let corpus: Corpus
    private var backing = InMemoryDatabase()
    private var dirty = true
    private var runs = 0

    init(corpus: Corpus) {
        self.corpus = corpus
    }

    func world(for scenario: PerfScenario) async throws -> PerfWorld {
        if dirty {
            restore()
        }
        dirty = scenario.writes || scenario.setUp != nil
        runs += 1

        let wire = PerfRecorder()
        let app = PerfRecorder()
        let observed = ObservedDatabase(backing: backing, observer: wire)
        let cache = Self.cache(scenario.stack, over: observed)
        let database = ObservedDatabase(backing: cache ?? observed, observer: app)
        let registry = SchemaRegistry(database: database)
        let store = EntityStore(database: database, registry: registry, keyProvider: PerfKeyProvider(), zoneID: PerfSchema.zoneID)

        try await registry.preload()
        if let replica = cache as? ReplicaCache {
            _ = try await replica.refresh()
        }
        wire.reset()
        app.reset()

        return PerfWorld(
            corpus: corpus, backing: backing, database: database, registry: registry, store: store, app: app, wire: wire, cache: cache,
            runID: "r\(runs)")
    }

    private static func cache(_ stack: PerfScenario.Stack, over database: any CloudDatabase) -> (any CloudDatabase)? {
        switch stack {
        case .direct: nil
        case .offline: OfflineCache(backing: database)
        case .replica: ReplicaCache(backing: database, zones: [PerfSchema.zoneID], readPolicy: .localFirst)
        }
    }

    /// Puts a fresh database under the next scenario, seeded from the pristine
    /// records.
    ///
    /// A new double rather than a cleaned one, because its change feed is
    /// append-only and has no reset: reusing it would hand a sync scenario
    /// every write the scenarios before it made, and its cost would depend on
    /// its position in the sweep.
    ///
    private func restore() {
        backing = InMemoryDatabase()
        backing.records = corpus.records.map(Self.clone)
        backing.zones = [PerfSchema.zoneID]
        backing.pageLimit = Self.pageLimit
    }

    /// The cap CloudKit puts on a response page.
    ///
    /// Without one the double answers any read in a single call and every read
    /// scenario would cost exactly one request — a number that says nothing
    /// about what the same read costs against the server.
    ///
    static let pageLimit = 200

    /// Copies a record the way the store's own projection does.
    ///
    /// An injected change tag or modification date lives in an associated
    /// object and does not survive `copy()`, so a plain copy would hand the
    /// scenario records the CAS and the compaction sweep cannot recognize.
    ///
    private static func clone(_ record: CKRecord) -> CKRecord {
        let copy = record.copy() as! CKRecord
        if let tag = record.recordVersionTag {
            copy.overrideChangeTag(tag)
        }
        if let date = record.recordModificationDate {
            copy.overrideModificationDate(date)
        }
        if let creator = record.recordCreator {
            copy.overrideCreator(creator)
        }
        return copy
    }
}
