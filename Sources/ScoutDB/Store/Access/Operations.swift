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

        while true {
            guard let existing = try await items(entity: entity, uuids: [uuid]).first else {
                throw SchemaError.notFound(uuid)
            }
            var entityRecord = try coder.decode(existing, using: definition)
            try transform(&entityRecord)
            let encoded = try coder.encode(entityRecord, using: definition, into: existing)
            do {
                try await database.write(record: encoded)
                return
            } catch let conflict as RecordConflictError {
                attempt += 1
                guard attempt < maxRetry else { throw conflict }
            }
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
        let (server, client) = try split(pageFilters, entity: entity, using: definition)
        let serverFilters = server + [ServerFilter(field: "deleted", op: .equals, value: .int(0))]
        let query = ckQuery(Entity.recordType, filters: serverFilters, sort: try serverSort([Sort(field: dateField)], using: definition))

        var collected: [EntityRecord] = []
        var (batch, token) = try await database.records(matching: query, desiredKeys: nil, resultsLimit: limit)
        while true {
            for record in try decode(batch.map { try $0.1.get() }, using: definition) where !record.deleted && client.allSatisfy({ matches(record, $0) }) {
                if let cursor, Self.pageKey(record, dateField) <= (cursor.date, cursor.uuid) { continue }
                collected.append(record)
            }
            guard collected.count < limit, let nextCursor = token else { break }
            (batch, token) = try await database.records(continuingMatchFrom: nextCursor, desiredKeys: nil, resultsLimit: limit)
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
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)

        var updated: [CKRecord] = []
        for var record in try await read(entity: entity, filters: filters) {
            try transform(&record)
            updated.append(try coder.encode(record, using: definition))
        }
        try await database.write(records: updated)
        return updated.count
    }

    @discardableResult public func deleteAll(entity: String, filters: [Filter] = []) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let victims = try await read(entity: entity, filters: filters)
        let tombstones = victims.map { Self.tombstone(entity: entity, uuid: $0.uuid, definition: definition) }
        try await database.write(records: tombstones)
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
        let expired = try await database.allRecords(matching: query).compactMap { $0["uuid"] as? String }

        let tombstones = expired.sorted().map { Self.tombstone(entity: entity, uuid: $0, definition: definition) }
        try await database.write(records: tombstones)
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

    func items(entity: String, uuids: [String]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        for chunk in uuids.chunked(into: 100) {
            let query = ckQuery(
                Entity.recordType,
                filters: [
                    ServerFilter(field: "entity", op: .equals, value: .string(entity)),
                    ServerFilter(field: "uuid", op: .in, value: .strings(chunk)),
                ])
            records += try await database.allRecords(matching: query)
        }
        return records
    }
}
