//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
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

        let records = try await grid(
            entity: entity,
            view: view.name,
            group: query.serverGroup,
            values: field != nil
        )

        var folded: [String: GridFold] = [:]
        for record in records {
            guard let key = record["group_key"] as? String, query.covers(key) else {
                continue
            }

            let count = Int(record.cellCount)
            guard count > 0 else {
                continue
            }

            var entry = folded[group == nil ? "" : key] ?? GridFold()
            entry.count += count
            if let cell = record.cellValue {
                entry.value = entry.value.map { kind.combine($0, cell) } ?? cell
            }
            folded[group == nil ? "" : key] = entry
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
