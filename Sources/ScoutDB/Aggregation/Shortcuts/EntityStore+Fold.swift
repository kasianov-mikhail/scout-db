//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func fold(of field: String?, folding kind: Metric = .sum, by group: String?, entity: String, filters: [Filter])
        async throws -> [String: GridFold]?
    {
        try await fold(
            of: field,
            folding: kind,
            by: group,
            entity: entity,
            any: [filters]
        )
    }

    func fold(of field: String?, folding kind: Metric = .sum, by group: String?, entity: String, any branches: [[Filter]])
        async throws -> [String: GridFold]?
    {
        let definition = try await registry.definition(for: entity)

        guard definition.views?.isEmpty == false, var query = CountQuery(any: branches, envelopeDate: definition.envelopeDate) else {
            return nil
        }

        query.key(in: definition)

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

    func gridFold(
        _ query: CountQuery, of field: String?, folding kind: Metric = .sum, by group: String?, entity: String,
        in definition: EntityDefinition
    ) async throws -> [String: GridFold]? {
        guard group == nil || query.groupField == nil || query.groupField == group else {
            return nil
        }
        guard let view = query.foldPlan(in: definition, folding: field.map { (kind, $0) }, grouping: group) else {
            return nil
        }

        let covers = view.cellFilter(from: query.from, to: query.to)
        let cells = 0..<CKRecord.squareOffset

        let records = try await gridRecords(
            entity: entity,
            view: view.name,
            group: query.serverGroup,
            from: view.gridStart(from: query.from),
            to: query.to,
            counts: cells,
            values: field == nil ? nil : cells
        )

        var folded: [String: GridFold] = [:]
        for record in records {
            guard let start = record["date"] as? Date, let key = record["group_key"] as? String, query.covers(key) else {
                continue
            }

            var bucketed = folded[group == nil ? "" : key] ?? GridFold()
            for index in cells where covers(start, index) {
                let count = Int(record.count(at: index))
                guard count != 0 else {
                    continue
                }
                bucketed.count += count
                if let cell = record.value(at: index) {
                    bucketed.value = bucketed.value.map { kind.combine($0, cell) } ?? cell
                }
            }

            if bucketed.count > 0 {
                folded[group == nil ? "" : key] = bucketed
            }
        }
        return folded
    }
}

extension CountQuery {
    var serverGroup: String? {
        groupKeys?.count == 1 ? groupKeys?.first : nil
    }

    func covers(_ key: String) -> Bool {
        groupKeys?.contains(key) ?? true
    }
}
