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
    public func update(entity: String, uuid: String, maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void) async throws {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        var attempt = 0
        var existing = try await items(entity: entity, uuids: [uuid]).first
        var prepared: EntityCoder.Rewrite?

        while true {
            let rewrite: EntityCoder.Rewrite
            if let merged = prepared {
                rewrite = merged
                prepared = nil
            } else {
                guard let stored = existing else {
                    throw SchemaError.notFound(uuid)
                }
                rewrite = try coder.rewrite(stored, using: definition, transform: transform)
            }
            do {
                try await database.write(record: rewrite.record)
            } catch let conflict as RecordConflictError {
                attempt += 1
                guard attempt < maxRetry else { throw conflict }
                // The conflict already carries the winning record. When the two
                // sides edited disjoint fields, graft this side's changes onto the
                // winner instead of re-running the transform — nothing to re-decide.
                let winner = try coder.decode(conflict.serverRecord, using: definition)
                let mine = Self.changedFields(from: rewrite.previous, to: rewrite.next)
                let theirs = Self.changedFields(from: rewrite.previous, to: winner)
                if rewrite.previous.deleted == rewrite.next.deleted, Set(mine.keys).isDisjoint(with: theirs.keys) {
                    prepared = try coder.rewrite(conflict.serverRecord, using: definition) { record in
                        for (field, value) in mine {
                            record.values[field] = value
                        }
                    }
                } else {
                    existing = conflict.serverRecord
                }
                continue
            }
            // The staged asset copies existed only for the upload; the landed
            // rewrite retires them.
            EntityCoder.discardStagedAssets(in: [rewrite.record])
            // Rebalance the views outside the CAS loop: drop the stored record's old
            // contribution, add the new one. A grid conflict here must not retry the update.
            try await GridAggregator(database: database).rebalance(removing: [rewrite.previous], adding: [rewrite.next], using: definition)
            try await recordRevisions([rewrite.previous], using: definition)
            noteChange(entity: entity)
            return
        }
    }

    // The fields whose values differ between two states of one record; a field
    // the later state removed carries nil.
    private static func changedFields(from base: EntityRecord, to next: EntityRecord) -> [String: RecordValue?] {
        var changes: [String: RecordValue?] = [:]
        for field in Set(base.values.keys).union(next.values.keys) where base.values[field] != next.values[field] {
            changes.updateValue(next.values[field], forKey: field)
        }
        return changes
    }

    public func read(entity: String, filters: [Filter] = [], limit: Int, after cursor: EntityCursor? = nil) async throws -> EntityPage {
        try await read(entity: entity, any: [filters], limit: limit, after: cursor)
    }

    /// Reads one keyset page of the records matching any of the OR branches.
    ///
    /// Every branch reads its own page from the shared cursor concurrently; the
    /// union's first `limit` rows in key order are exactly the page a single scan
    /// over the disjunction would produce, since a row the union keeps is in its
    /// own branch's top `limit` too.
    ///
    public func read(entity: String, any branches: [[Filter]], limit: Int, after cursor: EntityCursor? = nil) async throws -> EntityPage {
        let definition = try await registry.definition(for: entity)
        guard let dateField = definition.envelopeDate else {
            throw SchemaError.invalidDefinition("Pagination requires an envelope date")
        }
        let pages = try await withThrowingTaskGroup(of: [EntityRecord].self) { group in
            for branch in branches {
                group.addTask { try await self.page(entity: entity, filters: branch, dateField: dateField, cursor: cursor, limit: limit, using: definition) }
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

    // Reads one keyset page. The envelope date is sorted and bounded server-side, and the
    // query cursor is followed only until `limit` post-filter rows are in hand — so a page
    // read costs about one page of records, not the whole result set the way a full scan
    // through `read(entity:filters:)` would. Ties on the date are broken by uuid here.
    private func page(entity: String, filters: [Filter], dateField: String, cursor: EntityCursor?, limit: Int, using definition: EntityDefinition) async throws
        -> [EntityRecord]
    {
        var pageFilters = filters
        if let cursor {
            pageFilters.append(Filter(field: dateField, op: .greaterThanOrEquals, value: .date(cursor.date)))
        }
        let (query, included) = try liveQuery(pageFilters, entity: entity, sort: try serverSort([Sort(field: dateField)], using: definition), using: definition)

        let collected = try await boundedRecords(matching: query, desiredKeys: nil, limit: limit, using: definition) { record in
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
        entity: String, filters: [Filter] = [], orderedBy field: String, descending: Bool = false, limit: Int, after cursor: FieldCursor? = nil
    ) async throws -> FieldPage {
        try await read(entity: entity, any: [filters], orderedBy: field, descending: descending, limit: limit, after: cursor)
    }

    /// Reads one field-ordered keyset page of the records matching any of the
    /// OR branches; the same page-merge argument as the envelope-date variant.
    public func read(
        entity: String, any branches: [[Filter]], orderedBy field: String, descending: Bool = false, limit: Int, after cursor: FieldCursor? = nil
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
                        entity: entity, filters: branch, field: field, descending: descending, cursor: cursor, limit: limit, using: definition)
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

    // One branch's bounded page: the field is range-bounded and sorted server-side,
    // and the cursor is followed only until `limit` post-filter rows are in hand.
    private func fieldPage(
        entity: String, filters: [Filter], field: String, descending: Bool, cursor: FieldCursor?, limit: Int, using definition: EntityDefinition
    ) async throws -> [EntityRecord] {
        var pageFilters = filters
        if let cursor {
            pageFilters.append(Filter(field: field, op: descending ? .lessThanOrEquals : .greaterThanOrEquals, value: cursor.value))
        }
        let sort = try serverSort([Sort(field: field, ascending: !descending)], using: definition)
        let (query, included) = try liveQuery(pageFilters, entity: entity, sort: sort, using: definition)

        let collected = try await boundedRecords(matching: query, desiredKeys: nil, limit: limit, using: definition) { record in
            guard included(record), record.values[field] != nil else { return false }
            guard let cursor else { return true }
            return Self.beyond(record, field, cursor, descending: descending)
        }
        return Array(collected.sorted { Self.ordered($0, $1, by: field, descending: descending) }.prefix(limit))
    }

    // Whether the record lies strictly beyond the cursor in the page order; ties
    // on the field fall back to ascending uuids in both directions.
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

    private static func pageKey(_ record: EntityRecord, _ dateField: String) -> (Date, String) {
        guard case .date(let date)? = record.values[dateField] else { return (.distantPast, record.uuid) }
        return (date, record.uuid)
    }

    public func stream(entity: String, filters: [Filter] = [], pageSize: Int = 100) -> AsyncThrowingStream<EntityRecord, any Error> {
        stream(entity: entity, any: [filters], pageSize: pageSize)
    }

    /// Streams every record matching any of the OR branches, page by page.
    public func stream(entity: String, any branches: [[Filter]], pageSize: Int = 100) -> AsyncThrowingStream<EntityRecord, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: EntityCursor?
                do {
                    repeat {
                        let page = try await read(entity: entity, any: branches, limit: pageSize, after: cursor)
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

    @discardableResult public func updateAll(entity: String, filters: [Filter] = [], maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void)
        async throws -> Int
    {
        try await updateAll(entity: entity, any: [filters], maxRetry: maxRetry, transform: transform)
    }

    /// Rewrites every record matching any of the OR branches; a record matching
    /// several branches is transformed once.
    ///
    /// Each save is conditional on the record being unchanged on the server; a
    /// record that lost its race is re-transformed from the winning record and
    /// retried, like a single `update`. Exhausting `maxRetry` throws the conflict
    /// after the records that did land are accounted for.
    ///
    @discardableResult public func updateAll(entity: String, any branches: [[Filter]], maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void)
        async throws -> Int
    {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        var seen: Set<String> = []
        var pending: [EntityCoder.Rewrite] = []
        for branch in branches {
            for item in try await matchedItems(entity: entity, filters: branch, using: definition) {
                guard let uuid = item["uuid"] as? String, seen.insert(uuid).inserted else { continue }
                pending.append(try coder.rewrite(item, using: definition, transform: transform))
            }
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
            // The conflicts already carry the winning records — retry against them
            // instead of re-querying.
            pending = try conflicts.map { try coder.rewrite($0, using: definition, transform: transform) }
        }
        // Rebalance the views for the records that landed: drop the old
        // contributions, add the new ones.
        try await GridAggregator(database: database).rebalance(removing: applied.map(\.previous), adding: applied.map(\.next), using: definition)
        try await recordRevisions(applied.map(\.previous), using: definition)
        if applied.count > 0 {
            noteChange(entity: entity)
        }
        if let unresolved {
            throw RecordConflictError(serverRecord: unresolved)
        }
        return applied.count
    }

    // The live stored records behind a filtered read, kept as CKRecords rather than
    // decoded — a rewrite must encode back into the source record, which `read` discards.
    func matchedItems(entity: String, filters: [Filter], using definition: EntityDefinition) async throws -> [CKRecord] {
        let (query, included) = try liveQuery(filters, entity: entity, using: definition)
        let coder = EntityCoder(keyProvider: keyProvider)
        return try await database.allRecords(matching: query, inZone: zoneID).filter { record in
            if let trustedWriters {
                guard let creator = record.recordCreator, trustedWriters.contains(creator) else { return false }
            }
            return included(try coder.decode(record, using: definition))
        }
    }

    @discardableResult public func deleteAll(entity: String, filters: [Filter] = []) async throws -> Int {
        try await deleteAll(entity: entity, any: [filters])
    }

    /// Tombstones every record matching any of the OR branches.
    @discardableResult public func deleteAll(entity: String, any branches: [[Filter]]) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let victims = try await read(entity: entity, any: branches)
        let tombstones = try victims.map { try tombstone(entity: entity, uuid: $0.uuid, definition: definition, values: $0.values) }
        try await database.write(records: tombstones)
        try await GridAggregator(database: database).remove(victims, using: definition)
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
        try await GridAggregator(database: database).remove(expired, using: definition)
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
    public func fetch(uuid: String) async throws -> EntityRecord? {
        let query = ckQuery(Entity.recordType, filters: [ServerFilter(field: "uuid", op: .equals, value: .string(uuid))])
        guard let record = try await database.allRecords(matching: query, inZone: zoneID).first else { return nil }
        guard let entity = record["entity"] as? String else { return nil }
        let definition = try await registry.definition(for: entity)
        let decoded = try decode([record], using: definition)
        return decoded.first { !$0.deleted }
    }

    // Chunk lookups are independent, so they run concurrently; the shared request
    // limiter still bounds the actual CloudKit fan-out.
    func items(entity: String, uuids: [String]) async throws -> [CKRecord] {
        // CKRecord gains its Sendable annotation above this deployment target; each
        // chunk's records are freshly fetched and handed over whole, never shared
        // between tasks.
        struct Chunk: @unchecked Sendable {
            let index: Int
            let records: [CKRecord]
        }
        let database = database
        return try await withThrowingTaskGroup(of: Chunk.self) { group in
            for (index, chunk) in uuids.chunked(into: 100).enumerated() {
                group.addTask {
                    let query = ckQuery(
                        Entity.recordType,
                        filters: [
                            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                            ServerFilter(field: "uuid", op: .in, value: .strings(chunk)),
                        ])
                    return Chunk(index: index, records: try await database.allRecords(matching: query, inZone: zoneID))
                }
            }
            var chunks: [Int: [CKRecord]] = [:]
            for try await chunk in group {
                chunks[chunk.index] = chunk.records
            }
            return chunks.sorted { $0.key < $1.key }.flatMap(\.value)
        }
    }
}
