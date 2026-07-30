//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting

@testable import ScoutDB

struct PerfWorld: @unchecked Sendable {
    let corpus: Corpus
    let database: InMemoryDatabase
    let registry: SchemaRegistry
    let store: EntityStore
    let runID: String
    let repeats: Int
    let stage: PerfStage

    var size: DatasetSize {
        corpus.size
    }

    var migrator: Migrator {
        Migrator(database: database, registry: registry, keyProvider: PerfKeyProvider())
    }

    func fresh(_ prefix: String, _ iteration: Int) -> String {
        "\(prefix)-\(runID)-\(iteration)"
    }
}

final class PerfStage: @unchecked Sendable {
    var uuids: [String] = []
    var entities: [String] = []
    var records: [EntityRecord] = []
}

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

        let registry = SchemaRegistry(database: backing)
        let store = EntityStore(database: backing, registry: registry, keyProvider: PerfKeyProvider())

        try await registry.preload()
        backing.resetRequests()

        return PerfWorld(
            corpus: corpus, database: backing, registry: registry, store: store,
            runID: "r\(runs)", repeats: scenario.repeats(on: corpus.size), stage: PerfStage())
    }

    private func restore() {
        backing = InMemoryDatabase()
        backing.records = corpus.records.map(Self.clone)
        backing.pageLimit = Self.pageLimit
    }

    static let pageLimit = 200

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
