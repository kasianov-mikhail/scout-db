//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

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

extension UniversalStore {
    public func update(entity: String, uuid: String, maxRetry: Int = 3, transform: (inout EntityRecord) throws -> Void) async throws {
        let definition = try await registry.definition(for: entity)
        let coder = UniversalCoder(keyProvider: keyProvider)
        var attempt = 0

        while true {
            guard let existing = try await items(entity: entity, uuids: [uuid]).first else {
                throw UniversalSchemaError.notFound(uuid)
            }
            var entityRecord = try coder.decode(existing, using: definition)
            try transform(&entityRecord)
            var encoded = try coder.encode(entityRecord, using: definition)
            encoded.metadata = existing.metadata
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
            throw UniversalSchemaError.invalidDefinition("Pagination requires an envelope date")
        }

        var pageFilters = filters
        if let cursor {
            pageFilters.append(Filter(field: dateField, op: .greaterThanOrEquals, value: .date(cursor.date)))
        }

        let key: (EntityRecord) -> (Date, String) = { record in
            guard case .date(let date)? = record.values[dateField] else { return (.distantPast, record.uuid) }
            return (date, record.uuid)
        }
        var records = try await read(entity: entity, filters: pageFilters).sorted { key($0) < key($1) }
        if let cursor {
            records.removeAll { key($0) <= (cursor.date, cursor.uuid) }
        }
        records = Array(records.prefix(limit))

        let next = records.count == limit ? records.last.map { EntityCursor(date: key($0).0, uuid: $0.uuid) } : nil
        return EntityPage(records: records, cursor: next)
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
        let coder = UniversalCoder(keyProvider: keyProvider)

        var updated: [Record] = []
        for var record in try await read(entity: entity, filters: filters) {
            try transform(&record)
            updated.append(try coder.encode(record, using: definition))
        }
        for chunk in updated.chunked(into: 400) {
            try await database.write(records: chunk)
        }
        return updated.count
    }

    @discardableResult public func deleteAll(entity: String, filters: [Filter] = []) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let victims = try await read(entity: entity, filters: filters)
        let tombstones = victims.map { Self.tombstone(entity: entity, uuid: $0.uuid, definition: definition) }
        for chunk in tombstones.chunked(into: 400) {
            try await database.write(records: chunk)
        }
        return victims.count
    }

    @discardableResult public func reap(entity: String, asOf: Date) async throws -> Int {
        let definition = try await registry.definition(for: entity)
        let query = RecordQuery(
            recordType: Item.self,
            filters: [
                RecordQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
                RecordQuery.Filter(field: "expires", op: .lessThan, value: .date(asOf)),
                RecordQuery.Filter(field: "deleted", op: .equals, value: .int(0)),
            ])
        let expired = try await database.readAll(matching: query, fields: nil).compactMap { $0["uuid"] as String? }

        let tombstones = expired.sorted().map { Self.tombstone(entity: entity, uuid: $0, definition: definition) }
        for chunk in tombstones.chunked(into: 400) {
            try await database.write(records: chunk)
        }
        return expired.count
    }

    public func fetch(entity: String, uuids: [String]) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        let records = try await items(entity: entity, uuids: uuids)
        return try decode(records, using: definition).filter { !$0.deleted }.sorted { $0.uuid < $1.uuid }
    }

    func items(entity: String, uuids: [String]) async throws -> [Record] {
        var records: [Record] = []
        for chunk in uuids.chunked(into: 100) {
            let query = RecordQuery(
                recordType: Item.self,
                filters: [
                    RecordQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
                    RecordQuery.Filter(field: "uuid", op: .in, value: .strings(chunk)),
                ])
            records += try await database.readAll(matching: query, fields: nil)
        }
        return records
    }
}
