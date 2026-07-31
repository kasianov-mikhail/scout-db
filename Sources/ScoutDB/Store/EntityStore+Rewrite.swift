//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    /// Rewrites one record under compare-and-swap, retrying a lost race.
    ///
    /// A conflict whose winning fields are disjoint from the transform's is
    /// merged onto the winner instead of re-running the transform, and the
    /// retry only re-validates and re-claims the keys the merge actually moved
    /// — the claims of the keys it left alone are already ours.
    ///
    public func update(entity: String, uuid: String, maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void) async throws {
        try await update(entity: entity, uuids: [uuid], maxRetry: maxRetry, transform: transform)
    }

    func update(entity: String, uuids: [String], maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void) async throws {
        guard uuids.count > 0 else {
            return
        }
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        let owned = definition.claimedKeys + Self.exclusiveFields(of: definition).map { [$0.name] }
        var targets: [String] = []
        var seen: Set<String> = []
        for uuid in uuids where seen.insert(uuid).inserted {
            targets.append(uuid)
        }
        let fetched = try await items(entity: entity, uuids: targets)
        let stored = Dictionary(fetched.map { ($0.recordID.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        var pending = try targets.map { uuid -> EntityCoder.Rewrite in
            guard let record = stored[uuid], !Self.isTombstone(record) else {
                throw SchemaError.notFound(uuid)
            }
            return try coder.rewrite(record, using: definition, transform: transform)
        }

        var applied: [EntityCoder.Rewrite] = []
        var claimed: [String: EntityRecord] = [:]
        var attempt = 0
        var unresolved: CKRecord?
        while pending.count > 0 {
            try await claimRewrites(pending, since: claimed, using: definition)
            for rewrite in pending {
                claimed[rewrite.next.uuid] = rewrite.next
            }
            let conflicts = try await save(pending.map(\.record))
            let losers = Dictionary(conflicts.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
            applied += pending.filter { losers[$0.record.recordID] == nil }
            EntityCoder.abandonStagedAssets(in: pending.filter { losers[$0.record.recordID] != nil }.map(\.record))
            attempt += 1
            guard attempt < maxRetry else {
                unresolved = conflicts.first
                break
            }
            pending = try pending.compactMap { rewrite in
                guard let winner = losers[rewrite.record.recordID] else {
                    return nil
                }
                return try remerge(rewrite, onto: winner, with: coder, using: definition, transform: transform)
            }
        }

        EntityCoder.discardStagedAssets(in: applied.map(\.record))
        try await settle(rewritten: applied, owning: owned, using: definition)
        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
    }

    @discardableResult func updateAll(
        entity: String, any branches: [[Filter]], maxRetry: Int = 3, createdBy creator: String? = nil, transform: (inout EntityRecord) throws -> Void
    ) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        let owned = definition.claimedKeys + Self.exclusiveFields(of: definition).map { [$0.name] }
        var seen: Set<String> = []
        var applied = 0
        var unresolved: CKRecord?

        for branch in branches where unresolved == nil {
            let (query, included) = try liveQuery(branch, entity: entity, createdBy: creator, using: definition)
            try await database.forEachPage(matching: query) { page in
                guard unresolved == nil else {
                    return
                }
                let matched = try page.filter { record in
                    guard let uuid = record["uuid"] as? String, seen.insert(uuid).inserted else {
                        return false
                    }
                    guard let decoded = try decode(record, with: coder, using: definition) else {
                        return false
                    }
                    return included(decoded)
                }
                guard matched.count > 0 else {
                    return
                }

                var pending = try matched.map { try coder.rewrite($0, using: definition, transform: transform) }
                var settled: [EntityCoder.Rewrite] = []
                var claimed: [String: EntityRecord] = [:]
                var attempt = 0
                while pending.count > 0 {
                    try await claimRewrites(pending, since: claimed, using: definition)
                    for rewrite in pending {
                        claimed[rewrite.next.uuid] = rewrite.next
                    }
                    let conflicts = try await database.writeIfUnchanged(records: pending.map(\.record))
                    let losers = Set(conflicts.map(\.recordID))
                    settled += pending.filter { !losers.contains($0.record.recordID) }
                    attempt += 1
                    guard attempt < maxRetry else {
                        unresolved = conflicts.first
                        break
                    }
                    pending = try conflicts.map { try coder.rewrite($0, using: definition, transform: transform) }
                }

                guard settled.count > 0 else {
                    return
                }
                try await settle(rewritten: settled, owning: owned, using: definition)
                applied += settled.count
            }
        }

        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
        return applied
    }

    func settle(rewritten: [EntityCoder.Rewrite], owning owned: [[String]], using definition: EntityDefinition) async throws {
        let previous = rewritten.map(\.previous)
        let next = rewritten.map(\.next)
        try await withThrowingTaskGroup(of: Void.self) { group in
            if !owned.isEmpty, rewritten.count > 0 {
                group.addTask { await releaseStaleClaims(for: owned, of: Array(zip(previous, next)), using: definition) }
            }
            group.addTask { try await aggregator.rebalance(removing: previous, adding: next, using: definition) }
            group.addTask { try await recordRevisions(previous, using: definition) }
            try await group.waitForAll()
        }
    }

    private func save(_ records: [CKRecord]) async throws -> [CKRecord] {
        guard records.count > 1 else {
            do {
                try await database.write(record: records[0])
            } catch let conflict as RecordConflictError {
                return [conflict.serverRecord]
            }
            return []
        }
        return try await database.writeIfUnchanged(records: records)
    }

    private func claimRewrites(_ rewrites: [EntityCoder.Rewrite], since claimed: [String: EntityRecord], using definition: EntityDefinition) async throws {
        var touched: Set<String> = []
        for rewrite in rewrites {
            touched.formUnion(Self.changedFields(from: claimed[rewrite.next.uuid] ?? rewrite.previous, to: rewrite.next).keys)
        }
        let next = rewrites.map(\.next)
        let rekeyed = definition.claimedKeys.filter { $0.contains { touched.contains($0) } }
        if !rekeyed.isEmpty {
            try await claimKeys(rekeyed, of: next, using: definition)
        }
        let reassigned = Self.exclusiveFields(of: definition).filter { touched.contains($0.name) }
        if !reassigned.isEmpty {
            try await claimExclusivity(of: next, using: definition, fields: reassigned)
        }
    }

    private func remerge(
        _ rewrite: EntityCoder.Rewrite, onto winner: CKRecord, with coder: EntityCoder, using definition: EntityDefinition,
        transform: (inout EntityRecord) throws -> Void
    ) throws -> EntityCoder.Rewrite {
        let served = try coder.decode(winner, using: definition)
        let mine = Self.changedFields(from: rewrite.previous, to: rewrite.next)
        let theirs = Self.changedFields(from: rewrite.previous, to: served)
        if rewrite.previous.deleted == rewrite.next.deleted, Set(mine.keys).isDisjoint(with: theirs.keys) {
            return try coder.rewrite(winner, using: definition) { record in
                for (field, value) in mine {
                    record.values[field] = value
                }
            }
        }
        guard !Self.isTombstone(winner) else {
            throw SchemaError.notFound(rewrite.previous.uuid)
        }
        return try coder.rewrite(winner, using: definition, transform: transform)
    }

    private static func changedFields(from base: EntityRecord, to next: EntityRecord) -> [String: RecordValue?] {
        var changes: [String: RecordValue?] = [:]
        for field in Set(base.values.keys).union(next.values.keys) where base.values[field] != next.values[field] {
            changes.updateValue(next.values[field], forKey: field)
        }
        return changes
    }

    private static func isTombstone(_ record: CKRecord) -> Bool {
        (record["deleted"] as? Int64 ?? 0) > 0
    }
}
