//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func viewCount(entity: String, any branches: [[Filter]]) async throws -> Int? {
        let definition = try await registry.definition(for: entity)

        guard definition.views?.isEmpty == false, var query = CountQuery(any: branches, envelopeDate: definition.envelopeDate) else {
            return nil
        }

        query.key(in: definition)

        if query.numericField != nil {
            guard query.from == nil, query.to == nil, let (view, cells) = query.histogramPlan(in: definition) else {
                return nil
            }

            let records = try await gridRecords(
                entity: entity,
                view: view.name,
                group: query.serverGroup,
                counts: cells
            )

            var total = 0
            for record in records {
                guard let key = record["group_key"] as? String, query.covers(key) else {
                    continue
                }
                for index in cells {
                    total += Int(record.count(at: index))
                }
            }
            return total
        }

        guard let folded = try await gridFold(query, of: nil, by: nil, entity: entity, in: definition) else {
            return nil
        }
        return folded.values.reduce(0) { $0 + $1.count }
    }

    struct GridFold: Equatable, Sendable {
        var count = 0
        var value: Double?
    }

    func viewFold(of field: String?, folding kind: Metric = .sum, by group: String?, entity: String, filters: [Filter])
        async throws -> [String: GridFold]?
    {
        try await viewFold(
            of: field,
            folding: kind,
            by: group,
            entity: entity,
            any: [filters]
        )
    }

    func viewFold(of field: String?, folding kind: Metric = .sum, by group: String?, entity: String, any branches: [[Filter]])
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

    func alwaysPresent(_ field: String, entity: String) async throws -> Bool {
        let definition = try await registry.definition(for: entity)

        guard let target = definition.field(named: field, at: definition.version) else {
            return false
        }

        return target.alwaysPresent
    }

    private func gridFold(
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

    func gridRecords(
        entity: String, view: String, group: String? = nil, from: Date? = nil, to: Date? = nil, counts: Range<Int>, values: Range<Int>? = nil
    ) async throws -> [CKRecord] {
        var filters = [
            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
            ServerFilter(field: "view", op: .equals, value: .string(view)),
        ]
        if let group {
            filters.append(ServerFilter(field: "group_key", op: .equals, value: .string(group)))
        }
        if let from {
            filters.append(ServerFilter(field: "date", op: .greaterThanOrEquals, value: .date(from)))
        }
        if let to {
            filters.append(ServerFilter(field: "date", op: .lessThan, value: .date(to)))
        }
        let declared = values?.filter { $0 % CKRecord.squareOffset < CKRecord.valueCellCount } ?? []
        let keys = ["date", "group_key"] + counts.map(CKRecord.countCell) + declared.map(CKRecord.valueCell)
        return try await database.allRecords(matching: CKQuery(recordType: GridSlot.recordType, filters: filters), desiredKeys: keys)
    }
}
