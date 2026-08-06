//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The rule an entity definition broke.
public enum DefinitionFault: Equatable, Sendable {
    case reservedEntity(String)

    case slotTypeMismatch(field: String, type: FieldType, pool: FieldType)
    case slotOutsidePool(String, pool: FieldType)
    case slotBeyondCapacity(String, pool: FieldType)
    case reservedSlot(String, pool: FieldType)
    case sharedSlot(String, String, slot: String)
    case exhaustedPool(FieldType)

    case unsupportedPattern(field: String, type: FieldType)
    case malformedPattern(field: String)
    case unsupportedAllowed(field: String, type: FieldType)
    case unsupportedBounds(field: String, type: FieldType)

    case unknownGrouping(aggregate: String, field: String)
    case unknownDate(aggregate: String, field: String)
    case nonTemporalDate(aggregate: String, field: String)
    case nonNumericMetric(aggregate: String, field: String)
    case invalidShards(aggregate: String)
    case groupedHistogram(aggregate: String)
    case invalidBounds(aggregate: String)
}

extension DefinitionFault: CustomStringConvertible {
    public var description: String {
        switch self {
        case .reservedEntity(let name):
            "Entity '\(name)' starts with the '__' the library keeps for its own records"

        case .slotTypeMismatch(let field, let type, let pool):
            "Field '\(field)' of type '\(type.rawValue)' cannot live in the '\(pool.rawValue)' pool"
        case .slotOutsidePool(let slot, let pool):
            "Slot '\(slot)' does not belong to the '\(pool.rawValue)' pool"
        case .slotBeyondCapacity(let slot, let pool):
            "Slot '\(slot)' is beyond the '\(pool.rawValue)' pool capacity of \(pool.capacity)"
        case .reservedSlot(let slot, let pool):
            "Slot '\(slot)' is one of the \(pool.reserved) the record's envelope keeps"
        case .sharedSlot(let lhs, let rhs, let slot):
            "Fields '\(lhs)' and '\(rhs)' share slot '\(slot)'"
        case .exhaustedPool(let pool):
            "The '\(pool.rawValue)' pool is exhausted"

        case .unsupportedPattern(let field, let type):
            "Field '\(field)' of type '\(type.rawValue)' cannot constrain 'pattern'"
        case .malformedPattern(let field):
            "Field '\(field)' declares a malformed pattern"
        case .unsupportedAllowed(let field, let type):
            "Field '\(field)' of type '\(type.rawValue)' cannot constrain 'allowed'"
        case .unsupportedBounds(let field, let type):
            "Field '\(field)' of type '\(type.rawValue)' cannot constrain 'minimum'/'maximum'"

        case .unknownGrouping(let aggregate, let field):
            "Aggregate '\(aggregate)' groups by unknown '\(field)'"
        case .unknownDate(let aggregate, let field):
            "Aggregate '\(aggregate)' dates its cells by unknown '\(field)'"
        case .nonTemporalDate(let aggregate, let field):
            "Aggregate '\(aggregate)' dates its cells by non-timestamp '\(field)'"
        case .nonNumericMetric(let aggregate, let field):
            "Aggregate '\(aggregate)' aggregates non-numeric '\(field)'"
        case .invalidShards(let aggregate):
            "Aggregate '\(aggregate)' must shard into 2...64 records"
        case .groupedHistogram(let aggregate):
            "Aggregate '\(aggregate)' cannot group a histogram: its bucket is the grouping"
        case .invalidBounds(let aggregate):
            "Aggregate '\(aggregate)' must bound its histogram with 1...63 ascending, distinct values"
        }
    }
}
