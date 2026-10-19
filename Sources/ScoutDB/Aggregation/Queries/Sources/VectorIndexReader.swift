//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorIndexReader {
    let database: any CloudDatabase
    let entity: String
    let aggregate: AggregateDefinition

    var head: IndexPage {
        get async throws {
            let index = VectorIndex(entity: entity, aggregate: aggregate.name, week: nil)

            guard let record = try await database.fetchRecord(id: index.recordID) else {
                let empty = IndexPage(weeks: [], groups: [])
                try? await VectorIndexWriter(database: database).write([index: empty])
                return empty
            }

            return try record.indexPage(named: index.recordID)
        }
    }

    func keys(weeks: [Date]) async throws -> [VectorKey] {
        let pages = weeks.map { VectorIndex(entity: entity, aggregate: aggregate.name, week: $0) }
        let named = Dictionary(uniqueKeysWithValues: zip(pages.map(\.recordID), weeks))

        let ids = named.keys.sorted { $0.recordName < $1.recordName }

        return try await database.fetchRecords(ids: ids, batchSize: maxBatchSize).flatMap { record -> [VectorKey] in
            guard let week = named[record.recordID] else {
                return []
            }
            return try record.indexPage(named: record.recordID).groups.keys(week: week)
        }
    }
}

struct VectorKey {
    let group: String
    let week: Date
}

extension [String] {
    func keys(week: Date) -> [VectorKey] {
        map { VectorKey(group: $0, week: week) }
    }
}
