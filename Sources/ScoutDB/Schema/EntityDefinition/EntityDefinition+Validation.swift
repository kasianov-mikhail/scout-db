//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    func validate() throws {
        guard !entity.hasPrefix("__") else {
            throw SchemaError.invalidDefinition(.reservedEntity(entity))
        }

        for field in fields {
            try field.validate()
        }
        for lhs in fields {
            for rhs in fields where lhs.name != rhs.name || lhs.since != rhs.since {
                let slot = lhs.storage.slot
                guard slot == rhs.storage.slot else {
                    continue
                }
                if (lhs.since ?? 1) < (rhs.until ?? .max), (rhs.since ?? 1) < (lhs.until ?? .max) {
                    throw SchemaError.invalidDefinition(.sharedSlot(lhs.name, rhs.name, slot: slot))
                }
            }
        }
        var declared: Set<String> = []
        for aggregate in aggregates where !declared.insert(aggregate.name).inserted {
            throw SchemaError.invalidDefinition(.duplicateAggregate(aggregate.name))
        }
        for aggregate in aggregates {
            try aggregate.validate(fields: fields)
        }
    }
}

extension FieldDefinition {
    fileprivate func validate() throws {
        if case .slot(let pool, let slot) = storage {
            guard type == pool else {
                throw SchemaError.invalidDefinition(.slotTypeMismatch(field: name, type: type, pool: pool))
            }
            guard let index = pool.slotIndex(slot: slot) else {
                throw SchemaError.invalidDefinition(.slotOutsidePool(slot, pool: pool))
            }
            guard index >= pool.reserved else {
                throw SchemaError.invalidDefinition(.reservedSlot(slot, pool: pool))
            }
            guard index < pool.capacity else {
                throw SchemaError.invalidDefinition(.slotBeyondCapacity(slot, pool: pool))
            }
        }
        if case .payload(let slot) = storage {
            guard let index = PayloadPool.slotIndex(slot: slot) else {
                throw SchemaError.invalidDefinition(.slotOutsidePayload(slot))
            }
            guard index < PayloadPool.capacity else {
                throw SchemaError.invalidDefinition(.slotBeyondPayload(slot))
            }
        }
        if let pattern {
            guard [.string, .text, .stringList].contains(type) else {
                throw SchemaError.invalidDefinition(.unsupportedPattern(field: name, type: type))
            }
            guard (try? Regex(pattern)) != nil else {
                throw SchemaError.invalidDefinition(.malformedPattern(field: name))
            }
        }
        if allowed != nil, ![.string, .text, .stringList].contains(type) {
            throw SchemaError.invalidDefinition(.unsupportedAllowed(field: name, type: type))
        }
        if min != nil || max != nil, ![.int, .double, .intList, .doubleList].contains(type) {
            throw SchemaError.invalidDefinition(.unsupportedBounds(field: name, type: type))
        }
    }
}

extension AggregateDefinition {
    fileprivate func validate(fields: [FieldDefinition]) throws {
        if let groupBy, !fields.contains(where: { $0.name == groupBy }) {
            throw SchemaError.invalidDefinition(.unknownGrouping(aggregate: name, field: groupBy))
        }

        if let date {
            guard let field = fields.first(where: { $0.name == date }) else {
                throw SchemaError.invalidDefinition(.unknownDate(aggregate: name, field: date))
            }
            guard field.type == .timestamp else {
                throw SchemaError.invalidDefinition(.nonTemporalDate(aggregate: name, field: date))
            }
        }

        if let histogram = measure?.histogram {
            guard groupBy == nil else {
                throw SchemaError.invalidDefinition(.groupedHistogram(aggregate: name))
            }
            guard (1...63).contains(histogram.bounds.count) else {
                throw SchemaError.invalidDefinition(.invalidBounds(aggregate: name))
            }
            guard histogram.bounds == histogram.bounds.sorted() else {
                throw SchemaError.invalidDefinition(.invalidBounds(aggregate: name))
            }
            guard Set(histogram.bounds).count == histogram.bounds.count else {
                throw SchemaError.invalidDefinition(.invalidBounds(aggregate: name))
            }
        }

        if let field = measure?.field ?? measure?.histogram?.field {
            guard let type = fields.first(where: { $0.name == field })?.type, type == .int || type == .double else {
                throw SchemaError.invalidDefinition(.nonNumericMetric(aggregate: name, field: field))
            }
        }

        if let shards, !(2...64).contains(shards) {
            throw SchemaError.invalidDefinition(.invalidShards(aggregate: name))
        }
    }
}
