//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

struct GridFolder: Sendable {
    let database: any CloudDatabase
    let entity: String
    let field: String?
    let kind: Metric
    let group: String?
    let definition: EntityDefinition

    func fold(matching query: FilterPlan) async throws -> [String: GridFold]? {
        guard group == nil || query.groupField == nil || query.groupField == group else {
            return nil
        }
        guard let view = query.foldPlan(in: definition, folding: kind, of: field, grouping: group) else {
            return nil
        }

        let records = try await database.allRecords(
            matching: .grid(entity: entity, view: view.name, group: query.serverGroup)
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
