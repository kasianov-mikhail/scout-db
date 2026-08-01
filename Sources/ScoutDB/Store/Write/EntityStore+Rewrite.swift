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
    /// merged onto the winner instead of re-running the transform.
    ///
    public func update(entity: String, uuid: String, maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void)
        async throws
    {
        try await update(entity: entity, uuids: [uuid], maxRetry: maxRetry, transform: transform)
    }

    func update(entity: String, uuids: [String], maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void)
        async throws
    {
        guard uuids.count > 0 else {
            return
        }
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder()
        var targets: [String] = []
        var seen: Set<String> = []
        for uuid in uuids where seen.insert(uuid).inserted {
            targets.append(uuid)
        }
        let fetched = try await items(entity: entity, uuids: targets)
        let stored = Dictionary(fetched.map { ($0.recordID.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        var pending = try targets.map { uuid -> EntityCoder.Rewrite in
            guard let record = stored[uuid] else {
                throw SchemaError.notFound(uuid)
            }
            return try coder.rewrite(record, using: definition, transform: transform)
        }

        var applied: [EntityCoder.Rewrite] = []
        var attempt = 0
        var unresolved: CKRecord?
        while pending.count > 0 {
            let conflicts = try await save(pending.map(\.record))
            let losers = Dictionary(conflicts.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
            applied += pending.filter { losers[$0.record.recordID] == nil }
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

        try await settle(rewritten: applied, using: definition)
        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
    }

    @discardableResult func updateAll(
        entity: String, any branches: [[Filter]], maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void
    ) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder()
        var seen: Set<String> = []
        var applied = 0
        var unresolved: CKRecord?

        for branch in branches where unresolved == nil {
            let (query, included) = try liveQuery(branch, entity: entity, using: definition)
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
                var attempt = 0
                while pending.count > 0 {
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
                try await settle(rewritten: settled, using: definition)
                applied += settled.count
            }
        }

        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
        return applied
    }

    func settle(rewritten: [EntityCoder.Rewrite], using definition: EntityDefinition) async throws {
        try await aggregator.rebalance(
            removing: rewritten.map(\.previous),
            adding: rewritten.map(\.next),
            using: definition
        )
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

    private func remerge(
        _ rewrite: EntityCoder.Rewrite, onto winner: CKRecord, with coder: EntityCoder,
        using definition: EntityDefinition, transform: (inout EntityRecord) throws -> Void
    ) throws -> EntityCoder.Rewrite {
        let served = try coder.decode(winner, using: definition)
        let mine = Self.changedFields(from: rewrite.previous, to: rewrite.next)
        let theirs = Self.changedFields(from: rewrite.previous, to: served)
        if Set(mine.keys).isDisjoint(with: theirs.keys) {
            return try coder.rewrite(winner, using: definition) { record in
                for (field, value) in mine {
                    record.values[field] = value
                }
            }
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
}
