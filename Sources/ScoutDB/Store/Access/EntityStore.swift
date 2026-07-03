//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

public struct EntityStore: Sendable {
    let database: any CloudDatabase
    let registry: SchemaRegistry
    var keyProvider: (any EncryptionKeyProvider)?
    var trustedWriters: Set<String>?

    /// Creates a store backed by any `CloudDatabase` implementation.
    public init(database: any CloudDatabase, registry: SchemaRegistry, keyProvider: (any EncryptionKeyProvider)? = nil, trustedWriters: Set<String>? = nil) {
        self.database = database
        self.registry = registry
        self.keyProvider = keyProvider
        self.trustedWriters = trustedWriters
    }

    public struct Filter: Equatable, Sendable {
        public let field: String
        public let op: Match
        public let value: RecordValue
        public var radius: Double?

        public init(field: String, op: Match, value: RecordValue, radius: Double? = nil) {
            self.field = field
            self.op = op
            self.value = value
            self.radius = radius
        }

        public static func between(_ field: String, _ lower: RecordValue, _ upper: RecordValue) -> [Filter] {
            [
                Filter(field: field, op: .greaterThanOrEquals, value: lower),
                Filter(field: field, op: .lessThan, value: upper),
            ]
        }

        public static func containsAll(_ field: String, _ values: [String]) -> [Filter] {
            values.map { Filter(field: field, op: .contains, value: .string($0)) }
        }

        public static func containsAny(_ field: String, _ values: [String]) -> [[Filter]] {
            values.map { [Filter(field: field, op: .contains, value: .string($0))] }
        }
    }

    public struct Sort: Equatable, Sendable {
        public let field: String
        public var ascending = true

        public init(field: String, ascending: Bool = true) {
            self.field = field
            self.ascending = ascending
        }
    }

    @discardableResult public func write(_ values: [String: RecordValue], entity: String, uuid: String = UUID().uuidString) async throws -> String {
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)
        let resolved = try coder.resolve(values, at: definition.version, using: definition)
        let recordUUID = try coder.naturalUUID(for: resolved, using: definition) ?? uuid
        let entityRecord = EntityRecord(entity: entity, uuid: recordUUID, schemaVersion: definition.version, values: resolved)
        try await database.write(record: coder.encode(entityRecord, using: definition))
        try await GridAggregator(database: database).record(entityRecord, using: definition)
        return recordUUID
    }

    public func delete(entity: String, uuid: String) async throws {
        let definition = try await registry.definition(for: entity)
        try await database.write(record: Self.tombstone(entity: entity, uuid: uuid, definition: definition))
    }

    static func tombstone(entity: String, uuid: String, definition: EntityDefinition) -> CKRecord {
        let record = CKRecord(recordType: Item.recordType, recordID: CKRecord.ID(recordName: uuid))
        record["entity"] = entity
        record["schema_version"] = Int64(definition.version)
        record["uuid"] = uuid
        record["deleted"] = Int64(1)
        return record
    }

    public func read(entity: String, filters: [Filter] = [], sort: [Sort] = [], fields: [String]? = nil) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        var (server, client) = try split(filters, entity: entity, using: definition)
        server.append(ServerFilter(field: "deleted", op: .equals, value: .int(0)))
        let query = ckQuery(Item.recordType, filters: server, sort: try serverSort(sort, using: definition))
        let keys = try fields.map { try desiredKeys($0 + filters.map(\.field), using: definition) }
        let records = try await database.allRecords(matching: query, desiredKeys: keys)
        return try decode(records, using: definition).filter { record in
            !record.deleted && client.allSatisfy { matches(record, $0) }
        }
    }

    private func desiredKeys(_ fields: [String], using definition: EntityDefinition) throws -> [String] {
        var keys = ["entity", "schema_version", "uuid", "deleted"]
        for name in Set(fields) {
            guard let field = definition.fields(at: definition.version).first(where: { $0.name == name }) else {
                throw SchemaError.unknownField(name)
            }
            switch field.storage {
            case .slot(_, let slot):
                keys.append(slot)
            case .payload:
                if !keys.contains("payload") { keys.append("payload") }
            }
        }
        return keys
    }

    public func read(entity: String, any branches: [[Filter]], sort: [Sort] = []) async throws -> [EntityRecord] {
        var seen: Set<String> = []
        var union: [EntityRecord] = []
        for branch in branches {
            for record in try await read(entity: entity, filters: branch) where seen.insert(record.uuid).inserted {
                union.append(record)
            }
        }
        guard sort.count > 0 else { return union }
        return union.sorted { Self.ordered($0, $1, by: sort) }
    }

    public func changes(entity: String, since cursor: Date? = nil) async throws -> (records: [EntityRecord], cursor: Date?) {
        let definition = try await registry.definition(for: entity)
        var filters = [ServerFilter(field: "entity", op: .equals, value: .string(entity))]
        if let cursor {
            filters.append(ServerFilter(field: "modificationDate", op: .greaterThan, value: .date(cursor)))
        }
        let query = ckQuery(Item.recordType, filters: filters)
        let records = try await database.allRecords(matching: query)
        let next = records.compactMap(\.recordModificationDate).max() ?? cursor
        return (try decode(records, using: definition), next)
    }

    func decode(_ records: [CKRecord], using definition: EntityDefinition) throws -> [EntityRecord] {
        let coder = EntityCoder(keyProvider: keyProvider)
        return try records.compactMap { record in
            if let trustedWriters {
                guard let creator = record.recordCreator, trustedWriters.contains(creator) else { return nil }
            }
            return try coder.decode(record, using: definition)
        }
    }
}
