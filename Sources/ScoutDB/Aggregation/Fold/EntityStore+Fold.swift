//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func fold(
        of field: String?, folding kind: Metric = .sum, by group: String?, entity: String, any branches: [[Filter]]
    ) async throws -> [String: GridFold]? {
        let definition = try await registry.definition(for: entity)

        guard definition.views?.isEmpty == false, var query = FilterPlan(any: branches) else {
            return nil
        }

        query.expandRange(in: definition)

        guard query.numericField == nil else {
            return nil
        }

        return try await gridFold(
            query,
            of: field,
            folding: kind,
            by: group,
            entity: entity,
            in: definition
        )
    }

    private func gridFold(
        _ query: FilterPlan, of field: String?, folding kind: Metric, by group: String?, entity: String,
        in definition: EntityDefinition
    ) async throws -> [String: GridFold]? {
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
            guard let key = record["group_key"] as? String, query.covers(key) else {
                continue
            }

            let count = Int(record[CKRecord.countCell] as? Int64 ?? 0)
            guard count > 0 else {
                continue
            }

            let entry = folded[group == nil ? "" : key]
            let cell = record[CKRecord.valueCell] as? Double
            folded[group == nil ? "" : key] = GridFold(
                count: (entry?.count ?? 0) + count,
                value: cell.map { kind.combine(entry?.value, $0) } ?? entry?.value
            )
        }
        return folded
    }
}

struct GridFold: Sendable {
    let count: Int
    let value: Double?
}

extension FilterPlan {
    fileprivate var serverGroup: String? {
        groupKeys.count == 1 ? groupKeys.first : nil
    }

    fileprivate func covers(_ key: String) -> Bool {
        groupField == nil || groupKeys.contains(key)
    }
}
