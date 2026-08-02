//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct AggregateOperation {
    let store: EntityStore
    let entity: String

    let branches: [[ClientFilter]]
    let field: String?

    func value(metric: Metric) async throws -> Double? {
        guard let field else {
            return nil
        }

        let definition = try await store.registry.definition(for: entity)

        try definition.numericField(field)

        if let folded = try await gridCell(metric: metric, field: field) {
            return metric.apply(values: [folded.value].compactMap { $0 }, count: folded.count)
        }

        let records = try await ReadOperation(
            store: store,
            entity: entity
        )
        .read(any: branches)
        let scalars = records.compactMap { $0.values[field]?.scalar }

        return metric.apply(values: scalars, count: scalars.count)
    }

    private func gridCell(metric: Metric, field: String) async throws -> GridFold? {
        if metric == .average, try await store.registry.alwaysPresent(field, entity: entity) == false {
            return nil
        }

        guard let folder = try await store.folder(entity: entity, any: branches) else {
            return nil
        }
        return try await folder.fold(of: field, folding: metric)
    }
}

extension EntityDefinition {
    @discardableResult fileprivate func numericField(_ name: String) throws -> FieldDefinition {
        guard let target = fieldsByName(at: version)[name] else {
            throw SchemaError.unknownField(name)
        }
        guard target.isNumeric else {
            throw SchemaError.unsupportedQuery(.nonNumericField(name))
        }
        return target
    }
}

extension FieldDefinition {
    fileprivate var isNumeric: Bool {
        [.int, .double].contains(type)
    }
}
