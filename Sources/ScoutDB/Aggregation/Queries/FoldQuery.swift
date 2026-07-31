//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct FoldQuery {
    let store: EntityStore
    let entity: String

    var branches: [[EntityStore.Filter]]

    func value(fold: Fold, field: String) async throws -> Double? {
        let definition = try await store.registry.definition(for: entity)

        try definition.numericField(field)

        if let folded = try await gridCells(fold: fold, field: field) {
            let count = folded.values.reduce(0) { $0 + $1.count }
            let values = folded.values.compactMap(\.value)

            return fold.apply(values: values, count: count)
        }

        let records = try await store.read(
            entity: entity,
            any: branches,
            fields: [field]
        )
        let scalars = records.compactMap { $0.values[field]?.scalar }

        return fold.apply(values: scalars, count: scalars.count)
    }

    func values(fold: Fold, field: String, group: String) async throws -> [String: Double] {
        let definition = try await store.registry.definition(for: entity)

        try definition.numericField(field)
        try definition.declaredField(group)

        if let folded = try await gridCells(fold: fold, field: field, group: group) {
            return folded.compactMapValues { cell in
                fold.apply(values: [cell.value].compactMap { $0 }, count: cell.count)
            }
        }

        let records = try await store.read(
            entity: entity,
            any: branches,
            fields: [field, group]
        )

        var buckets: [String: [Double]] = [:]
        for record in records {
            guard let key = record.values[group]?.canonical, let scalar = record.values[field]?.scalar else {
                continue
            }
            buckets[key, default: []].append(scalar)
        }

        return buckets.mapValues { scalars in
            fold.apply(values: scalars, count: scalars.count) ?? 0
        }
    }

    func counts(group: String) async throws -> [String: Int] {
        let definition = try await store.registry.definition(for: entity)

        try definition.declaredField(group)

        if let gridded = try await gridCounts(group: group) {
            return gridded
        }

        let records = try await store.read(
            entity: entity,
            any: branches,
            fields: [group]
        )

        var counts: [String: Int] = [:]
        for record in records {
            guard let key = record.values[group]?.canonical else {
                continue
            }
            counts[key, default: 0] += 1
        }
        return counts
    }
}

extension FoldQuery {
    private func gridCounts(group: String) async throws -> [String: Int]? {
        guard try await store.alwaysPresent(group, entity: entity) else {
            return nil
        }
        guard let folded = try await store.fold(of: nil, by: group, entity: entity, any: branches) else {
            return nil
        }
        return folded.mapValues(\.count)
    }

    private func gridCells(fold: Fold, field: String, group: String? = nil) async throws -> [String: GridFold]? {
        if fold == .average, try await store.alwaysPresent(field, entity: entity) == false {
            return nil
        }
        if let group, try await store.alwaysPresent(group, entity: entity) == false {
            return nil
        }

        return try await store.fold(
            of: field,
            folding: fold.metric,
            by: group,
            entity: entity,
            any: branches
        )
    }
}

extension EntityDefinition {
    @discardableResult fileprivate func numericField(_ name: String) throws -> FieldDefinition {
        guard let target = field(named: name, at: version) else {
            throw SchemaError.invalidValue(name)
        }
        guard target.isNumeric else {
            throw SchemaError.invalidValue(name)
        }
        return target
    }

    @discardableResult fileprivate func declaredField(_ name: String) throws -> FieldDefinition {
        guard let target = field(named: name, at: version) else {
            throw SchemaError.unknownField(name)
        }
        return target
    }
}

extension FieldDefinition {
    fileprivate var isNumeric: Bool {
        [.int, .double].contains(type)
    }
}
