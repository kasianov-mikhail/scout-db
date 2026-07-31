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

    static func recordID(entity: String, digest: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "claim-" + contentDigest(of: [entity, digest]))
    }
}

extension EntityStore {
    private struct ClaimGroup {
        let key: [String]
        let owners: [String: String]
        let conflict: @Sendable (String) -> SchemaError
    }

    private struct PendingClaim {
        let group: Int
        let digest: String
        let owner: String
    }

    private struct ContestedClaim {
        let pending: PendingClaim
        var server: CKRecord
    }

    func claimUniqueKeys(of records: [EntityRecord], using definition: EntityDefinition) async throws {
        let groups = try keyGroups(definition.claimedKeys, of: records) + exclusivityGroups(of: records, using: definition, fields: nil)
        try await claim(groups, using: definition)
    }

    func claimKeys(_ keys: [[String]], of records: [EntityRecord], using definition: EntityDefinition) async throws {
        try await claim(try keyGroups(keys, of: records), using: definition)
    }

    func claimExclusivity(of records: [EntityRecord], using definition: EntityDefinition, fields: [FieldDefinition]?) async throws {
        try await claim(try exclusivityGroups(of: records, using: definition, fields: fields), using: definition)
    }

    static func exclusiveFields(of definition: EntityDefinition) -> [FieldDefinition] {
        definition.fields(at: definition.version).filter { $0.exclusive == true }
    }

    private func keyGroups(_ keys: [[String]], of records: [EntityRecord]) throws -> [ClaimGroup] {
        var groups: [ClaimGroup] = []
        for key in keys {
            var owners: [String: String] = [:]
            for record in records {
                guard let digest = Self.keyDigest(key, in: record.values) else {
                    continue
                }
                if let owner = owners[digest], owner != record.uuid {
                    throw SchemaError.duplicateKey(fields: key)
                }
                owners[digest] = record.uuid
            }
            guard owners.count > 0 else {
                continue
            }
            groups.append(ClaimGroup(key: key, owners: owners) { _ in .duplicateKey(fields: key) })
        }
        return groups
    }

    private func exclusivityGroups(of records: [EntityRecord], using definition: EntityDefinition, fields: [FieldDefinition]?) throws -> [ClaimGroup] {
        var groups: [ClaimGroup] = []
        for field in fields ?? Self.exclusiveFields(of: definition) {
            let key = [field.name]
            var owners: [String: String] = [:]
            var values: [String: String] = [:]
            for record in records {
                guard case .string(let value)? = record.values[field.name], let digest = Self.keyDigest(key, in: record.values) else {
                    continue
                }
                if let owner = owners[digest], owner != record.uuid {
                    throw SchemaError.duplicateReference(field: field.name, key: value)
                }
                owners[digest] = record.uuid
                values[digest] = value
            }
            guard owners.count > 0 else {
                continue
            }
            let display = values
            groups.append(
                ClaimGroup(key: key, owners: owners) { digest in
                    .duplicateReference(field: field.name, key: display[digest] ?? "")
                })
        }
        return groups
    }

    private func claim(_ groups: [ClaimGroup], using definition: EntityDefinition) async throws {
        var pending: [CKRecord.ID: PendingClaim] = [:]
        for (index, group) in groups.enumerated() {
            for (digest, owner) in group.owners {
                let id = UniqueClaim.recordID(entity: definition.entity, digest: digest)
                guard pending[id] == nil else {
                    continue
                }
                pending[id] = PendingClaim(group: index, digest: digest, owner: owner)
            }
        }
        guard pending.count > 0 else {
            return
        }
        let ids = pending.keys.sorted { $0.recordName < $1.recordName }
        var contested: [ContestedClaim] = []
        var seen: Set<CKRecord.ID> = []
        for server in try await claimRecords(ids: ids) {
            guard let claim = pending[server.recordID] else {
                continue
            }
            seen.insert(server.recordID)
            guard server["owner"] as? String != claim.owner else {
                continue
            }
            contested.append(ContestedClaim(pending: claim, server: server))
        }
        var fresh: [CKRecord] = []
        for id in ids where !seen.contains(id) {
            guard let claim = pending[id] else {
                continue
            }
            let record = CKRecord(recordType: UniqueClaim.recordType, recordID: id)
            record["entity"] = definition.entity
            record["key"] = groups[claim.group].key.joined(separator: "|")
            record["owner"] = claim.owner
            fresh.append(record)
        }
        for server in try await database.writeIfUnchanged(records: fresh) {
            guard let claim = pending[server.recordID] else {
                continue
            }
            contested.append(ContestedClaim(pending: claim, server: server))
        }
        try await adjudicate(contested, in: groups, using: definition)
    }

    private func adjudicate(_ contested: [ContestedClaim], in groups: [ClaimGroup], using definition: EntityDefinition) async throws {
        var round = contested.sorted { ($0.pending.group, $0.pending.digest) < ($1.pending.group, $1.pending.digest) }
        for _ in 0..<3 {
            guard round.count > 0 else {
                return
            }
            let held = try await liveHolders(of: round, using: definition)
            var taking: [CKRecord] = []
            var attempted: [CKRecord.ID: ContestedClaim] = [:]
            for contest in round {
                let holder = contest.server["owner"] as? String
                if holder == contest.pending.owner {
                    continue
                }
                let group = groups[contest.pending.group]
                if let holder, let record = held[holder], Self.keyDigest(group.key, in: record.values) == contest.pending.digest {
                    throw group.conflict(contest.pending.digest)
                }
                contest.server["owner"] = contest.pending.owner
                taking.append(contest.server)
                attempted[contest.server.recordID] = contest
            }
            var raced: [ContestedClaim] = []
            for server in try await database.writeIfUnchanged(records: taking) {
                guard var contest = attempted[server.recordID] else {
                    continue
                }
                contest.server = server
                raced.append(contest)
            }
            round = raced
        }
        guard let unresolved = round.first else {
            return
        }
        throw groups[unresolved.pending.group].conflict(unresolved.pending.digest)
    }

    private func liveHolders(of contested: [ContestedClaim], using definition: EntityDefinition) async throws -> [String: EntityRecord] {
        var uuids: [String] = []
        var seen: Set<String> = []
        for contest in contested {
            guard let holder = contest.server["owner"] as? String, holder != contest.pending.owner, seen.insert(holder).inserted else {
                continue
            }
            uuids.append(holder)
        }
        guard uuids.count > 0 else {
            return [:]
        }
        let records = try decode(try await items(entity: definition.entity, uuids: uuids), using: definition)
        return Dictionary(records.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func claimRecords(ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try await database.fetchRecords(ids: ids, batchSize: 100)
    }

    func releaseUniqueClaims(of records: [EntityRecord], using definition: EntityDefinition) async {
        let keys = definition.claimedKeys + Self.exclusiveFields(of: definition).map { [$0.name] }
        guard !keys.isEmpty, records.count > 0 else {
            return
        }
        var owners: [CKRecord.ID: String] = [:]
        for record in records {
            for key in keys {
                guard let digest = Self.keyDigest(key, in: record.values) else {
                    continue
                }
                owners[UniqueClaim.recordID(entity: definition.entity, digest: digest)] = record.uuid
            }
        }
        await release(owners)
    }

    func releaseStaleClaims(for keys: [[String]], of rewritten: [(previous: EntityRecord, next: EntityRecord)], using definition: EntityDefinition) async {
        var owners: [CKRecord.ID: String] = [:]
        for (previous, next) in rewritten {
            for key in keys {
                guard let old = Self.keyDigest(key, in: previous.values), old != Self.keyDigest(key, in: next.values) else {
                    continue
                }
                owners[UniqueClaim.recordID(entity: definition.entity, digest: old)] = previous.uuid
            }
        }
        await release(owners)
    }

    private func release(_ owners: [CKRecord.ID: String]) async {
        guard owners.count > 0 else {
            return
        }
        guard let claims = try? await claimRecords(ids: owners.keys.sorted { $0.recordName < $1.recordName }) else {
            return
        }
        let mine = claims.filter { $0["owner"] as? String == owners[$0.recordID] }.map(\.recordID)
        guard mine.count > 0 else {
            return
        }
        try? await database.delete(records: mine)
    }

    static func membership(of values: [RecordValue]) -> RecordValue? {
        switch values.first {
        case .string:
            let members = values.compactMap { value -> String? in
                guard case .string(let member) = value else {
                    return nil
                }
                return member
            }
            return members.count == values.count ? .strings(members) : nil
        case .int:
            let members = values.compactMap { value -> Int64? in
                guard case .int(let member) = value else {
                    return nil
                }
                return member
            }
            return members.count == values.count ? .ints(members) : nil
        case .double:
            let members = values.compactMap { value -> Double? in
                guard case .double(let member) = value else {
                    return nil
                }
                return member
            }
            return members.count == values.count ? .doubles(members) : nil
        case .date:
            let members = values.compactMap { value -> Date? in
                guard case .date(let member) = value else {
                    return nil
                }
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
            guard let value = values[field] else {
                return nil
            }
            parts.append("\(field)=\(value.canonical)")
        }
        return parts.joined(separator: "|")
    }
}
