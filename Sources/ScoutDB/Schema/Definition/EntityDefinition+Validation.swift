//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    func validate() throws {
        let names = Set(fields.map(\.name))
        for field in fields {
            if case .slot(let pool, let slot) = field.storage {
                guard field.type == pool else {
                    throw SchemaError.invalidDefinition(
                        "Field '\(field.name)' of type '\(field.type.rawValue)' "
                            + "cannot live in the '\(pool.rawValue)' pool"
                    )
                }
                guard let index = pool.slotIndex(slot) else {
                    throw SchemaError.invalidDefinition("Slot '\(slot)' does not belong to the '\(pool.rawValue)' pool")
                }
                guard index < pool.capacity else {
                    throw SchemaError.invalidDefinition(
                        "Slot '\(slot)' is beyond the '\(pool.rawValue)' pool capacity of \(pool.capacity)"
                    )
                }
            }
            if let pattern = field.pattern {
                guard [.string, .text, .stringList].contains(field.type) else {
                    throw SchemaError.invalidDefinition(
                        "Field '\(field.name)' of type '\(field.type.rawValue)' cannot constrain 'pattern'"
                    )
                }
                guard (try? Regex(pattern)) != nil else {
                    throw SchemaError.invalidDefinition("Field '\(field.name)' declares a malformed pattern")
                }
            }
            if field.allowed != nil, ![.string, .text, .stringList].contains(field.type) {
                throw SchemaError.invalidDefinition(
                    "Field '\(field.name)' of type '\(field.type.rawValue)' cannot constrain 'allowed'"
                )
            }
            if field.min != nil || field.max != nil, ![.int, .double, .intList, .doubleList].contains(field.type) {
                throw SchemaError.invalidDefinition(
                    "Field '\(field.name)' of type '\(field.type.rawValue)' cannot constrain 'minimum'/'maximum'"
                )
            }
        }
        for lhs in fields {
            for rhs in fields where lhs.name != rhs.name || lhs.since != rhs.since {
                guard case .slot(_, let lhsSlot) = lhs.storage else {
                    continue
                }
                guard case .slot(_, let rhsSlot) = rhs.storage else {
                    continue
                }
                if lhsSlot == rhsSlot, (lhs.since ?? 1) < (rhs.until ?? .max), (rhs.since ?? 1) < (lhs.until ?? .max) {
                    throw SchemaError.invalidDefinition(
                        "Fields '\(lhs.name)' and '\(rhs.name)' share slot '\(lhsSlot)'"
                    )
                }
            }
        }
        for key in unique ?? [] where !names.contains(key) {
            throw SchemaError.invalidDefinition("Unique key '\(key)' is not a field")
        }
        for aggregate in aggregates ?? [] {
            if let groupBy = aggregate.groupBy, !names.contains(groupBy) {
                throw SchemaError.invalidDefinition("Aggregate '\(aggregate.name)' groups by unknown '\(groupBy)'")
            }
            let metrics = [aggregate.sum, aggregate.min, aggregate.max].compactMap { $0 }
            guard metrics.count <= 1 else {
                throw SchemaError.invalidDefinition("Aggregate '\(aggregate.name)' declares more than one metric")
            }
            for field in metrics {
                guard let type = fields.first(where: { $0.name == field })?.type, type == .int || type == .double else {
                    throw SchemaError.invalidDefinition(
                        "Aggregate '\(aggregate.name)' aggregates non-numeric '\(field)'")
                }
            }
            if let shards = aggregate.shards, !(2...64).contains(shards) {
                throw SchemaError.invalidDefinition("Aggregate '\(aggregate.name)' must shard into 2...64 records")
            }
        }
    }
}
