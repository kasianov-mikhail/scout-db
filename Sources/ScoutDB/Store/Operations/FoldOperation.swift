//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct FoldOperation: Sendable {
    let database: any CloudDatabase
    let entity: String
    let definition: EntityDefinition
    let query: FilterPlan

    func fold(of field: String?, folding kind: Metric = .sum, by group: String?) async throws -> [String: GridFold]? {
        guard group == nil || query.groupField == nil || query.groupField == group else {
            return nil
        }
        guard let aggregate = query.foldPlan(in: definition, folding: kind, of: field, grouping: group) else {
            return nil
        }

        let records = try await database.allRecords(
            matching: .grid(entity: entity, aggregate: aggregate.name, group: query.serverGroup)
        )

        var folded: [String: GridFold] = [:]
        for record in records {
            guard let key = record[CKRecord.groupCell] as? String else {
                continue
            }
            guard query.groupField == nil || query.groupKeys.contains(key) else {
                continue
            }

            let count = Int(record[CKRecord.countCell] as? Int64 ?? 0)
            guard count > 0 else {
                continue
            }

            let bucket = group == nil ? "" : key
            let entry = folded[bucket]
            let cell = record[CKRecord.valueCell] as? Double

            folded[bucket] = GridFold(
                count: (entry?.count ?? 0) + count,
                value: kind.accumulate(entry?.value, cell)
            )
        }
        return folded
    }
}

extension FilterPlan {
    fileprivate var serverGroup: String? {
        groupKeys.count == 1 ? groupKeys.first : nil
    }
}

struct GridFold: Sendable {
    let count: Int
    let value: Double?
}
