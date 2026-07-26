//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

enum UniqueClaim {
    static let recordType = "UniqueClaim"

    static func recordID(entity: String, digest: String, zoneID: CKRecordZone.ID?) -> CKRecord.ID {
        CKRecord.ID(recordName: "claim-" + contentDigest(of: [entity, digest]), zoneID: zoneID ?? .default)
    }
}

extension EntityStore {
    func claimUniqueKeys(of records: [EntityRecord], using definition: EntityDefinition) async throws {
        try await claimKeys(definition.enforcedKeys ?? [], of: records, using: definition)
        try await claimExclusivity(of: records, using: definition)
    }

    func claimKeys(_ keys: [[String]], of records: [EntityRecord], using definition: EntityDefinition) async throws {
        for key in keys {
            var owners: [String: String] = [:]
            for record in records {
                guard let digest = Self.keyDigest(key, in: record.values) else { continue }
                if let owner = owners[digest], owner != record.uuid {
                    throw SchemaError.duplicateKey(fields: key)
                }
                owners[digest] = record.uuid
            }
            guard owners.count > 0 else { continue }
            try await claim(owners, key: key, using: definition) { _ in .duplicateKey(fields: key) }
        }
    }

    func claimExclusivity(of records: [EntityRecord], using definition: EntityDefinition, fields: [FieldDefinition]? = nil) async throws {
        for field in fields ?? Self.exclusiveFields(of: definition) {
            let key = [field.name]
            var owners: [String: String] = [:]
            var values: [String: String] = [:]
            for record in records {
                guard case .string(let value)? = record.values[field.name], let digest = Self.keyDigest(key, in: record.values) else { continue }
                if let owner = owners[digest], owner != record.uuid {
                    throw SchemaError.duplicateReference(field: field.name, key: value)
                }
                owners[digest] = record.uuid
                values[digest] = value
            }
            guard owners.count > 0 else { continue }
            let display = values
            try await claim(owners, key: key, using: definition) { digest in
                .duplicateReference(field: field.name, key: display[digest] ?? "")
            }
        }
    }

    static func exclusiveFields(of definition: EntityDefinition) -> [FieldDefinition] {
        definition.fields(at: definition.version).filter { $0.exclusive == true }
    }

    private func claim(
        _ owners: [String: String], key: [String], using definition: EntityDefinition, conflict: @escaping @Sendable (String) -> SchemaError
    ) async throws {
        var digests: [CKRecord.ID: String] = [:]
        for digest in owners.keys {
            digests[UniqueClaim.recordID(entity: definition.entity, digest: digest, zoneID: zoneID)] = digest
        }
        let existing = try await database.fetchRecords(ids: digests.keys.sorted { $0.recordName < $1.recordName })
        var contested: [(digest: String, server: CKRecord)] = []
        var fresh: [CKRecord] = []
        var seen: Set<CKRecord.ID> = []
        for server in existing {
            guard let digest = digests[server.recordID] else { continue }
            seen.insert(server.recordID)
            if server["owner"] as? String != owners[digest] {
                contested.append((digest, server))
            }
        }
        for (id, digest) in digests where !seen.contains(id) {
            let record = CKRecord(recordType: UniqueClaim.recordType, recordID: id)
            record["entity"] = definition.entity
            record["key"] = key.joined(separator: "|")
            record["owner"] = owners[digest]
            fresh.append(record)
        }
        if fresh.count > 0 {
            for (id, result) in try await database.saveIfUnchanged(fresh) {
                guard case .failure(let error) = result else { continue }
                guard let raced = RecordConflictError(error), let digest = digests[id] else { throw error }
                contested.append((digest, raced.serverRecord))
            }
        }
        for (digest, server) in contested {
            try await adjudicate(server, digest: digest, key: key, owner: owners[digest]!, using: definition, conflict: conflict)
        }
    }

    private func adjudicate(
        _ claim: CKRecord, digest: String, key: [String], owner uuid: String, using definition: EntityDefinition,
        conflict: @escaping @Sendable (String) -> SchemaError
    ) async throws {
        var server = claim
        for _ in 0..<3 {
            let holder = server["owner"] as? String
            if holder == uuid { return }
            if let holder, try await holds(holder, digest: digest, key: key, using: definition) {
                throw conflict(digest)
            }
            server["owner"] = uuid
            var raced: CKRecord?
            for (_, result) in try await database.saveIfUnchanged([server]) {
                guard case .failure(let error) = result else { continue }
                guard let lost = RecordConflictError(error) else { throw error }
                raced = lost.serverRecord
            }
            guard let raced else { return }
            server = raced
        }
        throw conflict(digest)
    }

    private func holds(_ uuid: String, digest: String, key: [String], using definition: EntityDefinition) async throws -> Bool {
        guard let record = try await items(entity: definition.entity, uuids: [uuid]).first,
            let decoded = try decode([record], using: definition).first, !decoded.deleted
        else { return false }
        return Self.keyDigest(key, in: decoded.values) == digest
    }

    func releaseUniqueClaims(of records: [EntityRecord], using definition: EntityDefinition) async {
        let keys = (definition.enforcedKeys ?? []) + Self.exclusiveFields(of: definition).map { [$0.name] }
        guard !keys.isEmpty, records.count > 0 else { return }
        var owners: [CKRecord.ID: String] = [:]
        for record in records {
            for key in keys {
                guard let digest = Self.keyDigest(key, in: record.values) else { continue }
                owners[UniqueClaim.recordID(entity: definition.entity, digest: digest, zoneID: zoneID)] = record.uuid
            }
        }
        guard owners.count > 0 else { return }
        guard let claims = try? await database.fetchRecords(ids: owners.keys.sorted { $0.recordName < $1.recordName }) else { return }
        let mine = claims.filter { $0["owner"] as? String == owners[$0.recordID] }.map(\.recordID)
        guard mine.count > 0 else { return }
        try? await database.modifyRecords(saving: [], deleting: mine)
    }

    func releaseStaleClaims(for keys: [[String]], of rewritten: [(previous: EntityRecord, next: EntityRecord)], using definition: EntityDefinition) async {
        var owners: [CKRecord.ID: String] = [:]
        for (previous, next) in rewritten {
            for key in keys {
                guard let old = Self.keyDigest(key, in: previous.values), old != Self.keyDigest(key, in: next.values) else { continue }
                owners[UniqueClaim.recordID(entity: definition.entity, digest: old, zoneID: zoneID)] = previous.uuid
            }
        }
        guard owners.count > 0 else { return }
        guard let claims = try? await database.fetchRecords(ids: owners.keys.sorted { $0.recordName < $1.recordName }) else { return }
        let mine = claims.filter { $0["owner"] as? String == owners[$0.recordID] }.map(\.recordID)
        guard mine.count > 0 else { return }
        try? await database.modifyRecords(saving: [], deleting: mine)
    }

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

    private func keyHolders(_ key: [String], of records: [EntityRecord], using definition: EntityDefinition) async throws -> [EntityRecord] {
        let probe = key.first { field in
            guard case .slot? = definition.field(named: field, at: definition.version)?.storage else { return false }
            return true
        }
        let values = probe.map { field in records.compactMap { $0.values[field] } } ?? []
        guard let probe, Self.membership(of: values) != nil else {
            return try await read(entity: definition.entity, fields: key)
        }
        var holders: [EntityRecord] = []
        for chunk in values.chunked(into: 100) {
            guard let list = Self.membership(of: chunk) else { continue }
            holders += try await read(entity: definition.entity, filters: [Filter(field: probe, op: .in, value: list)], fields: key)
        }
        return holders
    }

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

    private static func keyDigest(_ key: [String], in values: [String: RecordValue]) -> String? {
        var parts: [String] = []
        for field in key {
            guard let value = values[field] else { return nil }
            parts.append("\(field)=\(value.canonical)")
        }
        return parts.joined(separator: "|")
    }
}
