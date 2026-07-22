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
            guard claims.count > 0 else { continue }
            for holder in try await keyHolders(key, of: records, using: definition) {
                guard let digest = Self.keyDigest(key, in: holder.values), let owner = claims[digest], owner != holder.uuid else { continue }
                throw SchemaError.duplicateKey(fields: key)
            }
        }
    }

    // The live records that could already hold one of the batch's key values.
    //
    // A holder of a claimed digest necessarily matches the batch on every field
    // of the key, so narrowing on one of them — a membership test the server can
    // run — keeps the read to a handful of requests for the whole batch instead
    // of one per record. The exact digests are compared by the caller, since the
    // narrowed set is a superset.
    private func keyHolders(_ key: [String], of records: [EntityRecord], using definition: EntityDefinition) async throws -> [EntityRecord] {
        let probe = key.first { field in
            guard case .slot? = definition.field(named: field, at: definition.version)?.storage else { return false }
            return true
        }
        // Without a slot-backed field there is nothing the server can narrow on,
        // so the batch costs one scan of the entity — still one read rather than
        // one per record.
        let values = probe.map { field in records.compactMap { $0.values[field] } } ?? []
        guard let probe, Self.membership(of: values) != nil else {
            return try await read(entity: definition.entity)
        }
        var holders: [EntityRecord] = []
        for chunk in values.chunked(into: 100) {
            guard let list = Self.membership(of: chunk) else { continue }
            holders += try await read(entity: definition.entity, filters: [Filter(field: probe, op: .in, value: list)])
        }
        return holders
    }

    // The values as a single list value, for an `in` filter — nil when they do
    // not share one kind the server can compare, which sends the caller down
    // its unnarrowed path.
    static func membership(of values: [RecordValue]) -> RecordValue? {
        switch values.first {
        case .string:
            let members = values.compactMap { value -> String? in
                guard case .string(let member) = value else { return nil }
                return member
            }
            return members.count == values.count ? .strings(members) : nil
        case .int:
            let members = values.compactMap { value -> Int64? in
                guard case .int(let member) = value else { return nil }
                return member
            }
            return members.count == values.count ? .ints(members) : nil
        case .double:
            let members = values.compactMap { value -> Double? in
                guard case .double(let member) = value else { return nil }
                return member
            }
            return members.count == values.count ? .doubles(members) : nil
        case .date:
            let members = values.compactMap { value -> Date? in
                guard case .date(let member) = value else { return nil }
                return member
            }
            return members.count == values.count ? .dates(members) : nil
        default:
            return nil
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
