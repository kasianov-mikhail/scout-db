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

extension EntityStore {
    public func update(entity: String, uuid: String, maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void) async throws {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        var attempt = 0
        var existing = try await items(entity: entity, uuids: [uuid]).first

        while true {
            guard let stored = existing else {
                throw SchemaError.notFound(uuid)
            }
            let rewrite = try coder.rewrite(stored, using: definition, transform: transform)
            do {
                try await database.write(record: rewrite.record)
            } catch let conflict as RecordConflictError {
                attempt += 1
                guard attempt < maxRetry else { throw conflict }
                // The conflict already carries the winning record — retry against it
                // instead of re-querying.
                existing = conflict.serverRecord
                continue
            }
            // Rebalance the views outside the CAS loop: drop the stored record's old
            // contribution, add the new one. A grid conflict here must not retry the update.
            try await GridAggregator(database: database).rebalance(removing: [rewrite.previous], adding: [rewrite.next], using: definition)
            return
        }
    }

    public func read(entity: String, filters: [Filter] = [], limit: Int, after cursor: EntityCursor? = nil) async throws -> EntityPage {
        let definition = try await registry.definition(for: entity)
        guard let dateField = definition.envelopeDate else {
            throw SchemaError.invalidDefinition("Pagination requires an envelope date")
        }
        let records = try await page(entity: entity, filters: filters, dateField: dateField, cursor: cursor, limit: limit, using: definition)
        let next = records.count == limit ? records.last.map { EntityCursor(date: Self.pageKey($0, dateField).0, uuid: $0.uuid) } : nil
        return EntityPage(records: records, cursor: next)
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

    private static func pageKey(_ record: EntityRecord, _ dateField: String) -> (Date, String) {
        guard case .date(let date)? = record.values[dateField] else { return (.distantPast, record.uuid) }
        return (date, record.uuid)
    }

    public func stream(entity: String, filters: [Filter] = [], pageSize: Int = 100) -> AsyncThrowingStream<EntityRecord, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: EntityCursor?
                do {
                    repeat {
                        let page = try await read(entity: entity, filters: filters, limit: pageSize, after: cursor)
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

    @discardableResult public func updateAll(entity: String, filters: [Filter] = [], transform: (inout EntityRecord) throws -> Void) async throws -> Int {
        try await updateAll(entity: entity, any: [filters], transform: transform)
    }

    /// Rewrites every record matching any of the OR branches; a record matching
    /// several branches is transformed once.
    @discardableResult public func updateAll(entity: String, any branches: [[Filter]], transform: (inout EntityRecord) throws -> Void) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        var seen: Set<String> = []
        var rewrites: [EntityCoder.Rewrite] = []
        for branch in branches {
            for item in try await matchedItems(entity: entity, filters: branch, using: definition) {
                guard let uuid = item["uuid"] as? String, seen.insert(uuid).inserted else { continue }
                rewrites.append(try coder.rewrite(item, using: definition, transform: transform))
            }
        }
        try await database.write(records: rewrites.map(\.record))
        // Rebalance the views: drop the old contributions, add the new ones.
        try await GridAggregator(database: database).rebalance(removing: rewrites.map(\.previous), adding: rewrites.map(\.next), using: definition)
        return rewrites.count
    }

    // The live stored records behind a filtered read, kept as CKRecords rather than
    // decoded — a rewrite must encode back into the source record, which `read` discards.
    func matchedItems(entity: String, filters: [Filter], using definition: EntityDefinition) async throws -> [CKRecord] {
        let (query, included) = try liveQuery(filters, entity: entity, using: definition)
        let coder = EntityCoder(keyProvider: keyProvider)
        return try await database.allRecords(matching: query).filter { record in
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
        let tombstones = try victims.map { try Self.tombstone(entity: entity, uuid: $0.uuid, definition: definition) }
        try await database.write(records: tombstones)
        try await GridAggregator(database: database).remove(victims, using: definition)
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
        let expired = try decode(try await database.allRecords(matching: query), using: definition).filter { !$0.deleted }

        let tombstones = try expired.map(\.uuid).sorted().map { try Self.tombstone(entity: entity, uuid: $0, definition: definition) }
        try await database.write(records: tombstones)
        try await GridAggregator(database: database).remove(expired, using: definition)
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
        guard let record = try await database.allRecords(matching: query).first else { return nil }
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
                    return Chunk(index: index, records: try await database.allRecords(matching: query))
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
