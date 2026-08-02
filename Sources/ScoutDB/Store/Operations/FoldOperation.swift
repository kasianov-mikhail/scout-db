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

    func fold(of field: String?, folding kind: Metric = .sum) async throws -> GridFold? {
        guard let aggregate = query.foldPlan(in: definition, folding: kind, of: field) else {
            return nil
        }

        let records = try await database.allRecords(
            matching: CKQuery(gridOf: entity, aggregate: aggregate.name, group: query.serverGroup)
        )

        var folded = GridFold(count: 0, value: nil)
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

            var total = folded.value
            if let cell = record[CKRecord.valueCell] as? Double {
                total = total.map { kind.combine($0, cell) } ?? cell
            }

            folded = GridFold(count: folded.count + count, value: total)
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
