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
            let index = VectorIndex(entity: entity, aggregate: aggregate.name)

            guard let record = try await database.fetchRecord(id: index.recordID) else {
                let empty = IndexPage(weeks: [], groups: [])
                try? await database.write(wanted: [index: empty])
                return empty
            }

            return try record.indexPage(id: index.recordID)
        }
    }

    func keys(weeks: [Date]) async throws -> [VectorKey] {
        var named: [CKRecord.ID: Date] = [:]

        for week in weeks {
            for part in 0..<aggregate.partCount {
                let index = VectorIndex(
                    entity: entity,
                    aggregate: aggregate.name,
                    week: week,
                    part: part
                )
                named[index.recordID] = week
            }
        }

        let pages = try await database.fetchRecords(ids: Array(named.keys), batchSize: maxBatchSize)

        return try pages.flatMap { record -> [VectorKey] in
            guard let week = named[record.recordID] else {
                return []
            }
            return try record.indexPage(id: record.recordID).groups.keys(week: week)
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
