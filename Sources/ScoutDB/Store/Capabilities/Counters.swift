//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// Atomically adds `delta` to a numeric field and returns the new value.
    ///
    /// Runs through the CAS rewrite, so a lost race re-applies the delta to the
    /// winning record instead of clobbering it — the counter semantics `update`
    /// callers had to hand-roll. A missing value counts from zero; an int field
    /// takes whole deltas only. Do not put increments inside a transaction:
    /// its replays are at-least-once and would double-count.
    ///
    @discardableResult public func increment(entity: String, uuid: String, field: String, by delta: Double = 1) async throws -> Double {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version) else {
            throw SchemaError.unknownField(field)
        }

        var result = 0.0
        switch target.type {
        case .int:
            guard delta == delta.rounded() else {
                throw SchemaError.invalidValue(field)
            }
            try await update(entity: entity, uuid: uuid) { record in
                var current: Int64 = 0
                if case .int(let value)? = record.values[field] {
                    current = value
                }
                let next = current + Int64(delta)
                record.values[field] = .int(next)
                result = Double(next)
            }
        case .double:
            try await update(entity: entity, uuid: uuid) { record in
                var current: Double = 0
                if case .double(let value)? = record.values[field] {
                    current = value
                }
                let next = current + delta
                record.values[field] = .double(next)
                result = next
            }
        default:
            throw SchemaError.invalidValue(field)
        }
        return result
    }
}
