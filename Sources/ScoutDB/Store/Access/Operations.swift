//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

public struct EntityPage: Equatable, Sendable {
    public let records: [EntityRecord]
    public let cursor: EntityCursor?
}

public struct EntityCursor: Codable, Equatable, Sendable {
    public let date: Date
    public let uuid: String

    public init(date: Date, uuid: String) {
        self.date = date
        self.uuid = uuid
    }
}

/// One keyset page ordered by an arbitrary field.
public struct FieldPage: Equatable, Sendable {
    public let records: [EntityRecord]
    public let cursor: FieldCursor?
}

/// Continuation token of a field-ordered keyset read: the last served value
/// and the uuid that breaks its ties.
public struct FieldCursor: Codable, Equatable, Sendable {
    public let value: RecordValue
    public let uuid: String

    public init(value: RecordValue, uuid: String) {
        self.value = value
        self.uuid = uuid
    }
}

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

    /// Patches a batch of records of one entity, each through the same transform.
    ///
    /// The batch reads its records, saves them, and settles their claims,
    /// aggregate views and revisions once, so a run of records costs a fixed
    /// number of round trips instead of one update's worth each. The transform
    /// sees one record at a time and can branch on its uuid; a uuid without a
    /// live record throws `SchemaError.notFound`, and a repeated uuid is
    /// patched once.
    ///
    /// Each save is conditional on the record being unchanged on the server; a
    /// record that lost its race is re-transformed from the winning record and
    /// retried, like a single `update`. Exhausting `maxRetry` throws the
    /// conflict after the records that did land are accounted for. A batch
    /// saves as a batch, which an `OfflineCache` never queues — a single
    /// `update` still lands offline.
    ///
    public func update(entity: String, uuids: [String], maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void) async throws {
        guard uuids.count > 0 else { return }
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        let owned = (definition.enforcedKeys ?? []) + Self.exclusiveFields(of: definition).map { [$0.name] }
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
                guard let winner = losers[rewrite.record.recordID] else { return nil }
                return try remerge(rewrite, onto: winner, with: coder, using: definition, transform: transform)
            }
        }

        EntityCoder.discardStagedAssets(in: applied.map(\.record))
        let previous = applied.map(\.previous)
        let next = applied.map(\.next)
        try await withThrowingTaskGroup(of: Void.self) { group in
            if !owned.isEmpty, applied.count > 0 {
                group.addTask { await releaseStaleClaims(for: owned, of: Array(zip(previous, next)), using: definition) }
            }
            group.addTask { try await aggregator.rebalance(removing: previous, adding: next, using: definition) }
            group.addTask { try await recordRevisions(previous, using: definition) }
            try await group.waitForAll()
        }
        if applied.count > 0 {
            noteChange(entity: entity)
        }
        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
    }

    /// Saves the rewritten records conditionally and answers with the server
    /// records that won a race.
    ///
    /// A lone record takes the plain save seam an `OfflineCache` queues, so a
    /// single `update` still lands offline; a real batch takes the conditional
    /// batch save, which is never queued.
    ///
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

    /// Validates and claims the keys the batch moved since the state whose
    /// claims are already ours — on a retry, the ones the merge actually moved.
    private func claimRewrites(_ rewrites: [EntityCoder.Rewrite], since claimed: [String: EntityRecord], using definition: EntityDefinition) async throws {
        var touched: Set<String> = []
        for rewrite in rewrites {
            touched.formUnion(Self.changedFields(from: claimed[rewrite.next.uuid] ?? rewrite.previous, to: rewrite.next).keys)
        }
        let next = rewrites.map(\.next)
        if let keys = definition.uniqueKeys, keys.contains(where: { $0.contains { touched.contains($0) } }) {
            try await validateUniqueKeys(of: next, using: definition)
        }
        let rekeyed = (definition.enforcedKeys ?? []).filter { $0.contains { touched.contains($0) } }
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

    public func read(
        entity: String, filters: [Filter] = [], fields: [String]? = nil, limit: Int, after cursor: EntityCursor? = nil, createdBy creator: String? = nil
    ) async throws -> EntityPage {
        try await read(entity: entity, any: [filters], fields: fields, limit: limit, after: cursor, createdBy: creator)
    }

    /// Reads one keyset page of the records matching any of the OR branches.
    ///
    /// Every branch reads its own page from the shared cursor concurrently; the
    /// union's first `limit` rows in key order are exactly the page a single scan
    /// over the disjunction would produce, since a row the union keeps is in its
    /// own branch's top `limit` too.
    ///
    /// `fields` trims every record to those values, as on an unpaged read; the
    /// envelope date the cursor is built from is always carried.
    ///
    public func read(
        entity: String, any branches: [[Filter]], fields: [String]? = nil, limit: Int, after cursor: EntityCursor? = nil, createdBy creator: String? = nil
    ) async throws -> EntityPage {
        let definition = try await registry.definition(for: entity)
        guard let dateField = definition.envelopeDate else {
            throw SchemaError.invalidDefinition("Pagination requires an envelope date")
        }
        let pages = try await withThrowingTaskGroup(of: [EntityRecord].self) { group in
            for branch in branches {
                group.addTask {
                    try await self.page(
                        entity: entity, filters: branch, fields: fields, dateField: dateField, cursor: cursor, limit: limit, createdBy: creator,
                        using: definition)
                }
            }
            return try await group.reduce(into: [[EntityRecord]]()) { $0.append($1) }
        }
        var seen: Set<String> = []
        let records = pages.flatMap { $0 }
            .sorted { Self.pageKey($0, dateField) < Self.pageKey($1, dateField) }
            .filter { seen.insert($0.uuid).inserted }
            .prefix(limit)
        let next = records.count == limit ? records.last.map { EntityCursor(date: Self.pageKey($0, dateField).0, uuid: $0.uuid) } : nil
        return EntityPage(records: Array(records), cursor: next)
    }

    private func page(
        entity: String, filters: [Filter], fields: [String]?, dateField: String, cursor: EntityCursor?, limit: Int, createdBy creator: String?,
        using definition: EntityDefinition
    ) async throws -> [EntityRecord] {
        var pageFilters = filters
        if let cursor {
            pageFilters.append(Filter(field: dateField, op: .greaterThanOrEquals, value: .date(cursor.date)))
        }
        let sort = try serverSort([Sort(field: dateField)], using: definition) + [Self.uuidSort]
        let (query, included) = try liveQuery(pageFilters, entity: entity, sort: sort, createdBy: creator, using: definition)
        let keys = try fields.map { try desiredKeys($0 + pageFilters.map(\.field) + [dateField], using: definition) }

        let collected = try await boundedRecords(matching: query, desiredKeys: keys, limit: limit, using: definition) { record in
            guard included(record) else { return false }
            guard let cursor else { return true }
            return Self.pageKey(record, dateField) > (cursor.date, cursor.uuid)
        }
        return Array(collected.sorted { Self.pageKey($0, dateField) < Self.pageKey($1, dateField) }.prefix(limit))
    }

    /// Reads one keyset page ordered by any slot-backed scalar field, ascending
    /// or descending, with ties broken by uuid.
    ///
    /// Records missing the field are skipped — a keyset cursor cannot address them.
    ///
    public func read(
        entity: String, filters: [Filter] = [], fields: [String]? = nil, orderedBy field: String, descending: Bool = false, limit: Int,
        after cursor: FieldCursor? = nil, createdBy creator: String? = nil
    ) async throws -> FieldPage {
        try await read(
            entity: entity, any: [filters], fields: fields, orderedBy: field, descending: descending, limit: limit, after: cursor, createdBy: creator)
    }

    /// Reads one field-ordered keyset page of the records matching any of the
    /// OR branches; the same page-merge argument as the envelope-date variant.
    ///
    /// `fields` trims every record to those values; the ordering field the
    /// cursor is built from is always carried.
    ///
    public func read(
        entity: String, any branches: [[Filter]], fields: [String]? = nil, orderedBy field: String, descending: Bool = false, limit: Int,
        after cursor: FieldCursor? = nil, createdBy creator: String? = nil
    ) async throws -> FieldPage {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version), [.string, .int, .double, .timestamp].contains(target.type),
            case .slot = target.storage
        else {
            throw SchemaError.invalidValue(field)
        }
        let pages = try await withThrowingTaskGroup(of: [EntityRecord].self) { group in
            for branch in branches {
                group.addTask {
                    try await self.fieldPage(
                        entity: entity, filters: branch, fields: fields, field: field, descending: descending, cursor: cursor, limit: limit,
                        createdBy: creator, using: definition)
                }
            }
            return try await group.reduce(into: [[EntityRecord]]()) { $0.append($1) }
        }
        var seen: Set<String> = []
        let records = Array(
            pages.flatMap { $0 }
                .sorted { Self.ordered($0, $1, by: field, descending: descending) }
                .filter { seen.insert($0.uuid).inserted }
                .prefix(limit))
        let next: FieldCursor? =
            records.count == limit
            ? records.last.flatMap { record in record.values[field].map { FieldCursor(value: $0, uuid: record.uuid) } }
            : nil
        return FieldPage(records: records, cursor: next)
    }

    private func fieldPage(
        entity: String, filters: [Filter], fields: [String]?, field: String, descending: Bool, cursor: FieldCursor?, limit: Int,
        createdBy creator: String?, using definition: EntityDefinition
    ) async throws -> [EntityRecord] {
        var pageFilters = filters
        if let cursor {
            pageFilters.append(Filter(field: field, op: descending ? .lessThanOrEquals : .greaterThanOrEquals, value: cursor.value))
        }
        let sort = try serverSort([Sort(field: field, ascending: !descending)], using: definition) + [Self.uuidSort]
        let (query, included) = try liveQuery(pageFilters, entity: entity, sort: sort, createdBy: creator, using: definition)
        let keys = try fields.map { try desiredKeys($0 + pageFilters.map(\.field) + [field], using: definition) }

        let collected = try await boundedRecords(matching: query, desiredKeys: keys, limit: limit, using: definition) { record in
            guard included(record), record.values[field] != nil else { return false }
            guard let cursor else { return true }
            return Self.beyond(record, field, cursor, descending: descending)
        }
        return Array(collected.sorted { Self.ordered($0, $1, by: field, descending: descending) }.prefix(limit))
    }

    private static func beyond(_ record: EntityRecord, _ field: String, _ cursor: FieldCursor, descending: Bool) -> Bool {
        switch rank(record.values[field], cursor.value) {
        case .orderedSame: record.uuid > cursor.uuid
        case .orderedAscending: descending
        case .orderedDescending: !descending
        }
    }

    private static func ordered(_ lhs: EntityRecord, _ rhs: EntityRecord, by field: String, descending: Bool) -> Bool {
        let order = rank(lhs.values[field], rhs.values[field])
        guard order != .orderedSame else { return lhs.uuid < rhs.uuid }
        return descending ? order == .orderedDescending : order == .orderedAscending
    }

    /// Breaks a keyset page's ties the way its cursor does.
    ///
    /// The cursor addresses a row by `(value, uuid)`, so rows sharing a value
    /// have to reach the client in uuid order: served in any other order, a
    /// page can end on a uuid past rows it never saw, and the next page — which
    /// keeps only what sorts after the cursor — drops them for good.
    ///
    private static let uuidSort = ServerSort(field: "uuid", ascending: true)

    private static func pageKey(_ record: EntityRecord, _ dateField: String) -> (Date, String) {
        guard case .date(let date)? = record.values[dateField] else { return (.distantPast, record.uuid) }
        return (date, record.uuid)
    }

    public func stream(entity: String, filters: [Filter] = [], fields: [String]? = nil, pageSize: Int = 100, createdBy creator: String? = nil)
        -> AsyncThrowingStream<EntityRecord, any Error>
    {
        stream(entity: entity, any: [filters], fields: fields, pageSize: pageSize, createdBy: creator)
    }

    /// Streams every record matching any of the OR branches, page by page.
    public func stream(entity: String, any branches: [[Filter]], fields: [String]? = nil, pageSize: Int = 100, createdBy creator: String? = nil)
        -> AsyncThrowingStream<EntityRecord, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: EntityCursor?
                do {
                    repeat {
                        let page = try await read(entity: entity, any: branches, fields: fields, limit: pageSize, after: cursor, createdBy: creator)
                        for record in page.records {
                            continuation.yield(record)
                        }
                        cursor = page.cursor
                    } while cursor != nil && !Task.isCancelled
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult public func updateAll(
        entity: String, filters: [Filter] = [], maxRetry: Int = 3, createdBy creator: String? = nil, transform: (inout EntityRecord) throws -> Void
    ) async throws -> Int {
        try await updateAll(entity: entity, any: [filters], maxRetry: maxRetry, createdBy: creator, transform: transform)
    }

    /// Rewrites every record matching any of the OR branches; a record matching
    /// several branches is transformed once.
    ///
    /// Each save is conditional on the record being unchanged on the server; a
    /// record that lost its race is re-transformed from the winning record and
    /// retried, like a single `update`. Exhausting `maxRetry` throws the conflict
    /// after the records that did land are accounted for.
    ///
    @discardableResult public func updateAll(
        entity: String, any branches: [[Filter]], maxRetry: Int = 3, createdBy creator: String? = nil, transform: (inout EntityRecord) throws -> Void
    ) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        var seen: Set<String> = []
        var pending: [EntityCoder.Rewrite] = []
        for item in try await matchedBranches(entity: entity, branches: branches, createdBy: creator, using: definition) {
            guard let uuid = item["uuid"] as? String, seen.insert(uuid).inserted else { continue }
            pending.append(try coder.rewrite(item, using: definition, transform: transform))
        }

        var applied: [EntityCoder.Rewrite] = []
        var attempt = 0
        var unresolved: CKRecord?
        while pending.count > 0 {
            let conflicts = try await database.writeIfUnchanged(records: pending.map(\.record))
            let losers = Set(conflicts.map(\.recordID))
            applied += pending.filter { !losers.contains($0.record.recordID) }
            attempt += 1
            guard attempt < maxRetry else {
                unresolved = conflicts.first
                break
            }
            pending = try conflicts.map { try coder.rewrite($0, using: definition, transform: transform) }
        }
        try await aggregator.rebalance(removing: applied.map(\.previous), adding: applied.map(\.next), using: definition)
        try await recordRevisions(applied.map(\.previous), using: definition)
        if applied.count > 0 {
            noteChange(entity: entity)
        }
        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
        return applied.count
    }

    private func matchedBranches(entity: String, branches: [[Filter]], createdBy creator: String?, using definition: EntityDefinition) async throws
        -> [CKRecord]
    {
        struct Branch: @unchecked Sendable {
            let index: Int
            let records: [CKRecord]
        }
        return try await withThrowingTaskGroup(of: Branch.self) { group in
            for (index, branch) in branches.enumerated() {
                group.addTask {
                    Branch(index: index, records: try await self.matchedItems(entity: entity, filters: branch, createdBy: creator, using: definition))
                }
            }
            var collected: [Int: [CKRecord]] = [:]
            for try await branch in group {
                collected[branch.index] = branch.records
            }
            return collected.sorted { $0.key < $1.key }.flatMap(\.value)
        }
    }

    func matchedItems(entity: String, filters: [Filter], createdBy creator: String? = nil, using definition: EntityDefinition) async throws -> [CKRecord] {
        let (query, included) = try liveQuery(filters, entity: entity, createdBy: creator, using: definition)
        let coder = EntityCoder(keyProvider: keyProvider)
        return try await database.allRecords(matching: query, inZone: zoneID).filter { record in
            if let trustedWriters {
                guard let creator = record.recordCreator, trustedWriters.contains(creator) else { return false }
            }
            return included(try coder.decode(record, using: definition))
        }
    }

    @discardableResult public func deleteAll(entity: String, filters: [Filter] = [], createdBy creator: String? = nil) async throws -> Int {
        try await deleteAll(entity: entity, any: [filters], createdBy: creator)
    }

    /// Tombstones every record matching any of the OR branches.
    ///
    /// A `createdBy` scope is part of the match: only that user's records are
    /// tombstoned, so a scoped delete cannot reach another user's rows.
    ///
    @discardableResult public func deleteAll(entity: String, any branches: [[Filter]], createdBy creator: String? = nil) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let victims = try await read(entity: entity, any: branches, createdBy: creator)
        let tombstones = try victims.map { try tombstone(entity: entity, uuid: $0.uuid, definition: definition, values: $0.values) }
        try await database.write(records: tombstones)
        await releaseUniqueClaims(of: victims, using: definition)
        try await aggregator.remove(victims, using: definition)
        try await recordRevisions(victims, using: definition)
        if victims.count > 0 {
            noteChange(entity: entity)
        }
        return victims.count
    }

    @discardableResult public func reap(entity: String, asOf: Date) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let query = ckQuery(
            Entity.recordType,
            filters: [
                ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                ServerFilter(field: "expires", op: .lessThan, value: .date(asOf)),
                ServerFilter(field: "deleted", op: .equals, value: .int(0)),
            ])
        let expired = try decode(try await database.allRecords(matching: query, inZone: zoneID), using: definition).filter { !$0.deleted }

        let tombstones = try expired.sorted { $0.uuid < $1.uuid }
            .map { try tombstone(entity: entity, uuid: $0.uuid, definition: definition, values: $0.values) }
        try await database.write(records: tombstones)
        await releaseUniqueClaims(of: expired, using: definition)
        try await aggregator.remove(expired, using: definition)
        if expired.count > 0 {
            noteChange(entity: entity)
        }
        return expired.count
    }

    public func fetch(entity: String, uuids: [String]) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        let records = try await items(entity: entity, uuids: uuids)
        return try decode(records, using: definition).filter { !$0.deleted }.sorted { $0.uuid < $1.uuid }
    }

    /// Fetches a single record by its identifier, resolving the entity from the record itself.
    ///
    /// The record carries the uuid as its name, so this reaches it by ID and
    /// reads a just-written record — a query would go through the index, which
    /// lags a write.
    ///
    public func fetch(uuid: String) async throws -> EntityRecord? {
        let id = CKRecord.ID(recordName: uuid, zoneID: zoneID ?? .default)
        guard let record = try await database.fetchRecord(id: id) else { return nil }
        guard let entity = record["entity"] as? String else { return nil }
        let definition = try await registry.definition(for: entity)
        let decoded = try decode([record], using: definition)
        return decoded.first { !$0.deleted }
    }

    static func isTombstone(_ record: CKRecord) -> Bool {
        (record["deleted"] as? Int64 ?? 0) > 0
    }

    func items(entity: String, uuids: [String]) async throws -> [CKRecord] {
        struct Chunk: @unchecked Sendable {
            let index: Int
            let records: [CKRecord]
        }
        let database = database
        let zoneID = zoneID
        return try await withThrowingTaskGroup(of: Chunk.self) { group in
            for (index, chunk) in uuids.chunked(into: 100).enumerated() {
                group.addTask {
                    let ids = chunk.map { CKRecord.ID(recordName: $0, zoneID: zoneID ?? .default) }
                    return Chunk(index: index, records: try await database.fetchRecords(ids: ids))
                }
            }
            var chunks: [Int: [CKRecord]] = [:]
            for try await chunk in group {
                chunks[chunk.index] = chunk.records
            }
            return chunks.sorted { $0.key < $1.key }.flatMap(\.value).filter { $0["entity"] as? String == entity }
        }
    }
}
