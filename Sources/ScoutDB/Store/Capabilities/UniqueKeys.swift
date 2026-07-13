//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    // Rejects a write that would give a unique key the same values as another
    // live record — one lookup per key per incoming record. Client-side and
    // best-effort like the reference checks: the lookup and the write are
    // separate round trips, so two simultaneous writers can still slip past
    // each other. Records missing any of the key's fields are exempt.
    func validateUniqueKeys(of records: [EntityRecord], using definition: EntityDefinition) async throws {
        for key in definition.uniqueKeys ?? [] {
            var claims: [String: String] = [:]
            for record in records {
                guard let digest = Self.keyDigest(key, in: record.values) else { continue }
                if let owner = claims[digest], owner != record.uuid {
                    throw SchemaError.duplicateKey(fields: key)
                }
                claims[digest] = record.uuid
            }
            for record in records {
                guard let digest = Self.keyDigest(key, in: record.values) else { continue }
                let filters = key.compactMap { field in record.values[field].map { Filter(field: field, op: .equals, value: $0) } }
                let holders = try await read(entity: definition.entity, filters: filters)
                guard holders.allSatisfy({ $0.uuid == record.uuid || Self.keyDigest(key, in: $0.values) != digest }) else {
                    throw SchemaError.duplicateKey(fields: key)
                }
            }
        }
    }

    // The key's canonical value tuple, or nil when the record misses a field.
    private static func keyDigest(_ key: [String], in values: [String: RecordValue]) -> String? {
        var parts: [String] = []
        for field in key {
            guard let value = values[field] else { return nil }
            parts.append("\(field)=\(value.canonical)")
        }
        return parts.joined(separator: "|")
    }
}
