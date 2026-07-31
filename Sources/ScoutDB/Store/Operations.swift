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

extension EntityPage: RandomAccessCollection {
    public var startIndex: Int { records.startIndex }
    public var endIndex: Int { records.endIndex }

    public subscript(position: Int) -> EntityRecord {
        records[position]
    }
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

extension FieldPage: RandomAccessCollection {
    public var startIndex: Int { records.startIndex }
    public var endIndex: Int { records.endIndex }

    public subscript(position: Int) -> EntityRecord {
        records[position]
    }
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

    func settle(removed: [EntityRecord], using definition: EntityDefinition, auditing: Bool = true) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await releaseUniqueClaims(of: removed, using: definition) }
            group.addTask { try await aggregator.remove(removed, using: definition) }
            if auditing {
                group.addTask { try await recordRevisions(removed, using: definition) }
            }
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

    func read(
        entity: String, filters: [Filter] = [], fields: [String]? = nil, limit: Int, after cursor: EntityCursor? = nil, createdBy creator: String? = nil
    ) async throws -> EntityPage {
        try await read(entity: entity, any: [filters], fields: fields, limit: limit, after: cursor, createdBy: creator)
    }

    func read(
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
            guard included(record) else {
                return false
            }
            guard let cursor else {
                return true
            }
            return Self.pageKey(record, dateField) > (cursor.date, cursor.uuid)
        }
        return Array(collected.sorted { Self.pageKey($0, dateField) < Self.pageKey($1, dateField) }.prefix(limit))
    }

    func read(
        entity: String, filters: [Filter] = [], fields: [String]? = nil, orderedBy field: String, descending: Bool = false, limit: Int,
        after cursor: FieldCursor? = nil, createdBy creator: String? = nil
    ) async throws -> FieldPage {
        try await read(
            entity: entity, any: [filters], fields: fields, orderedBy: field, descending: descending, limit: limit, after: cursor, createdBy: creator)
    }

    func read(
        entity: String, any branches: [[Filter]], fields: [String]? = nil, orderedBy field: String, descending: Bool = false, limit: Int,
        after cursor: FieldCursor? = nil, createdBy creator: String? = nil
    ) async throws -> FieldPage {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version) else {
            throw SchemaError.invalidValue(field)
        }
        guard [.string, .int, .double, .timestamp].contains(target.type) else {
            throw SchemaError.invalidValue(field)
        }
        guard case .slot = target.storage else {
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
            guard included(record), record.values[field] != nil else {
                return false
            }
            guard let cursor else {
                return true
            }
            return Self.beyond(record, field, cursor, descending: descending)
        }
        return Array(collected.sorted { Self.ordered($0, $1, by: field, descending: descending) }.prefix(limit))
    }

    private static func beyond(_ record: EntityRecord, _ field: String, _ cursor: FieldCursor, descending: Bool) -> Bool {
        switch rank(record.values[field], cursor.value) {
        case .orderedSame:
            record.uuid > cursor.uuid
        case .orderedAscending:
            descending
        case .orderedDescending:
            !descending
        }
    }

    private static func ordered(_ lhs: EntityRecord, _ rhs: EntityRecord, by field: String, descending: Bool) -> Bool {
        let order = rank(lhs.values[field], rhs.values[field])
        guard order != .orderedSame else {
            return lhs.uuid < rhs.uuid
        }
        return descending ? order == .orderedDescending : order == .orderedAscending
    }

    private static let uuidSort = ServerSort(field: "uuid", ascending: true)

    private static func pageKey(_ record: EntityRecord, _ dateField: String) -> (Date, String) {
        guard case .date(let date)? = record.values[dateField] else {
            return (.distantPast, record.uuid)
        }
        return (date, record.uuid)
    }

    func stream(entity: String, any branches: [[Filter]], fields: [String]? = nil, pageSize: Int = 100, createdBy creator: String? = nil)
        -> AsyncThrowingStream<EntityRecord, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: EntityCursor?
                do {
                    repeat {
                        let page = try await read(entity: entity, any: branches, fields: fields, limit: pageSize, after: cursor, createdBy: creator)
                        for record in page {
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

    @discardableResult func deleteAll(entity: String, any branches: [[Filter]], createdBy creator: String? = nil) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        var seen: Set<String> = []
        var removed = 0
        for branch in branches {
            let (query, included) = try liveQuery(branch, entity: entity, createdBy: creator, using: definition)
            try await forEachPage(matching: query, using: definition) { page in
                let victims = page.filter { included($0) && seen.insert($0.uuid).inserted }
                guard victims.count > 0 else {
                    return
                }
                let tombstones = try victims.map { try tombstone(entity: entity, uuid: $0.uuid, definition: definition, values: $0.values) }
                try await database.write(records: tombstones)
                try await settle(removed: victims, using: definition)
                removed += victims.count
            }
        }
        return removed
    }

    func purge(entity: String, filters: [Filter]) async throws -> Int {
        let victims = try await read(entity: entity, filters: filters, fields: [])
        let ids = victims.map { CKRecord.ID(recordName: $0.uuid) }
        try await database.delete(records: ids)
        return ids.count
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
        let id = CKRecord.ID(recordName: uuid)
        guard let record = try await database.fetchRecord(id: id) else {
            return nil
        }
        guard let entity = record["entity"] as? String else {
            return nil
        }
        let definition = try await registry.definition(for: entity)
        let decoded = try decode([record], using: definition)
        return decoded.first { !$0.deleted }
    }

    fileprivate static func isTombstone(_ record: CKRecord) -> Bool {
        (record["deleted"] as? Int64 ?? 0) > 0
    }

    func items(entity: String, uuids: [String]) async throws -> [CKRecord] {
        let ids = uuids.map { CKRecord.ID(recordName: $0) }
        return try await database.fetchRecords(ids: ids, batchSize: 100).filter { $0["entity"] as? String == entity }
    }
}
