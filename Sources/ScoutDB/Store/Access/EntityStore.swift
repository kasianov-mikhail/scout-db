//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// One record of a batched `EntityStore.write(_:entity:)` call.
public struct EntityWrite: Sendable {
    public let values: [String: RecordValue]
    public let uuid: String

    public init(values: [String: RecordValue], uuid: String = UUID().uuidString) {
        self.values = values
        self.uuid = uuid
    }
}

public struct EntityStore: Sendable {
    let database: any CloudDatabase
    let registry: SchemaRegistry
    var keyProvider: (any EncryptionKeyProvider)?
    var trustedWriters: Set<String>?
    var enforceReferences = false
    var zoneID: CKRecordZone.ID?

    /// Creates a store backed by any `CloudDatabase` implementation.
    ///
    /// With `enforceReferences` on, every write checks that its reference fields
    /// name live parent records and throws `SchemaError.brokenReference` otherwise.
    /// With a `zoneID`, entity records live in that custom zone — the shape CKShare
    /// and zone-scoped sync build on; schema and aggregate bookkeeping stay in the
    /// default zone. Call `ensureZone()` once before the first zoned write.
    ///
    public init(
        database: any CloudDatabase, registry: SchemaRegistry, keyProvider: (any EncryptionKeyProvider)? = nil, trustedWriters: Set<String>? = nil,
        enforceReferences: Bool = false, zoneID: CKRecordZone.ID? = nil
    ) {
        self.database = database
        self.registry = registry
        self.keyProvider = keyProvider
        self.trustedWriters = trustedWriters
        self.enforceReferences = enforceReferences
        self.zoneID = zoneID
    }

    /// Creates the store's custom zone if one is configured; safe to repeat.
    public func ensureZone() async throws {
        guard let zoneID else { return }
        try await database.save(zone: CKRecordZone(zoneID: zoneID))
    }

    public struct Filter: Equatable, Sendable {
        public let field: String
        public let op: Match
        public let value: RecordValue
        public var radius: Double?
        /// A negated filter keeps the records its predicate does NOT match; it
        /// always runs client-side, so a record missing the field is kept.
        public var negated = false

        public init(field: String, op: Match, value: RecordValue, radius: Double? = nil, negated: Bool = false) {
            self.field = field
            self.op = op
            self.value = value
            self.radius = radius
            self.negated = negated
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
        try await write([EntityWrite(values: values, uuid: uuid)], entity: entity)[0]
    }

    /// Writes a batch of records of one entity in chunked saves, folding their
    /// aggregate-view contributions into a single write per touched grid record.
    ///
    /// Returns the stored uuid of every record, in batch order.
    ///
    @discardableResult public func write(_ batch: [EntityWrite], entity: String) async throws -> [String] {
        guard batch.count > 0 else { return [] }
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider, zoneID: zoneID)

        let entityRecords = try batch.map { entry in
            let resolved = try coder.resolve(entry.values, at: definition.version, using: definition)
            let uuid = try coder.naturalUUID(for: resolved, using: definition) ?? entry.uuid
            return EntityRecord(entity: entity, uuid: uuid, schemaVersion: definition.version, values: resolved)
        }

        if enforceReferences {
            try await validateReferences(of: entityRecords, using: definition)
        }
        // Exclusivity is declared in the schema itself, so it holds regardless of
        // the store's integrity flag.
        try await validateExclusivity(of: entityRecords, entity: entity, using: definition)

        // Views count occurrences on first write. A re-write of the same record — a
        // unique-key upsert or an explicit repeat uuid — must not inflate the grid, so fold
        // only records with no live row yet into the aggregate views. Skip the lookup
        // entirely when the entity declares no views.
        let fresh = try await freshForAggregation(entityRecords, using: definition)

        try await database.write(records: entityRecords.map { try coder.encode($0, using: definition) })
        try await GridAggregator(database: database).record(fresh, using: definition)
        return entityRecords.map(\.uuid)
    }

    // The records a batch write should fold into aggregate views: those with no live row
    // yet, deduplicated within the batch. Returns nothing when the entity has no views, so
    // a viewless write never pays for the lookup.
    private func freshForAggregation(_ records: [EntityRecord], using definition: EntityDefinition) async throws -> [EntityRecord] {
        guard definition.views?.isEmpty == false else { return [] }
        var seen = Set(try await liveRecords(entity: definition.entity, uuids: records.map(\.uuid), using: definition).map(\.uuid))
        return records.filter { seen.insert($0.uuid).inserted }
    }

    public func delete(entity: String, uuid: String) async throws {
        let definition = try await registry.definition(for: entity)
        let removed = try await liveRecords(entity: entity, uuids: [uuid], using: definition)
        try await database.write(record: tombstone(entity: entity, uuid: uuid, definition: definition))
        try await GridAggregator(database: database).remove(removed, using: definition)
    }

    // The live records behind a set of uuids, used to reverse their aggregate contributions
    // before tombstoning them. Skips the read when the entity has no views.
    func liveRecords(entity: String, uuids: [String], using definition: EntityDefinition) async throws -> [EntityRecord] {
        guard definition.views?.isEmpty == false else { return [] }
        return try decode(try await items(entity: entity, uuids: uuids), using: definition).filter { !$0.deleted }
    }

    // A tombstone is the record envelope with `deleted` set and no values; encoding
    // it through the coder keeps the envelope defined in one place — and, like any
    // write, in the store's zone.
    func tombstone(entity: String, uuid: String, definition: EntityDefinition) throws -> CKRecord {
        try EntityCoder(zoneID: zoneID)
            .encode(EntityRecord(entity: entity, uuid: uuid, schemaVersion: definition.version, values: [:], deleted: true), using: definition)
    }

    public func read(entity: String, filters: [Filter] = [], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        let (query, included) = try liveQuery(filters, entity: entity, sort: try serverSort(sort, using: definition), using: definition)
        let keys = try fields.map { try desiredKeys($0 + filters.map(\.field), using: definition) }
        // A capped read stops following the cursor once enough rows are in hand. The
        // sort ran server-side, so the first `limit` post-filter rows in arrival order
        // are the same records a full scan would keep after `prefix(limit)`.
        if let limit {
            return Array(try await boundedRecords(matching: query, desiredKeys: keys, limit: limit, using: definition, where: included).prefix(limit))
        }
        return try decode(try await database.allRecords(matching: query, desiredKeys: keys), using: definition).filter(included)
    }

    // Assembles the pieces every live read shares: tombstones excluded server-side and
    // re-checked after decode, client-side matchers reapplied to each decoded record.
    func liveQuery(_ filters: [Filter], entity: String, sort: [ServerSort] = [], using definition: EntityDefinition) throws
        -> (query: CKQuery, included: (EntityRecord) -> Bool)
    {
        var (server, client) = try split(filters, entity: entity, using: definition)
        server.append(ServerFilter(field: "deleted", op: .equals, value: .int(0)))
        let matchers = client.map { filter in
            let base = Self.matcher(for: filter)
            return filter.negated ? { !base($0) } : base
        }
        return (
            ckQuery(Entity.recordType, filters: server, sort: sort),
            { record in !record.deleted && matchers.allSatisfy { $0(record) } }
        )
    }

    // Pages through the query, following the cursor only until `limit` post-filter
    // rows are collected — so a bounded read costs about one page of records, not
    // the whole result set. May return slightly more than `limit` (the tail of the
    // final batch); callers trim.
    func boundedRecords(
        matching query: CKQuery, desiredKeys: [String]?, limit: Int, using definition: EntityDefinition, where included: (EntityRecord) -> Bool
    ) async throws -> [EntityRecord] {
        var collected: [EntityRecord] = []
        var (batch, token) = try await database.records(matching: query, desiredKeys: desiredKeys, resultsLimit: limit)
        while true {
            collected += try decode(batch.map { try $0.1.get() }, using: definition).filter(included)
            guard collected.count < limit, let cursor = token else { break }
            (batch, token) = try await database.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: limit)
        }
        return collected
    }

    private func desiredKeys(_ fields: [String], using definition: EntityDefinition) throws -> [String] {
        var keys = EntityCoder.envelopeKeys
        for name in Set(fields) {
            guard let field = definition.field(named: name, at: definition.version) else {
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

    public func read(entity: String, any branches: [[Filter]], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil) async throws -> [EntityRecord] {
        // Sort fields join the projection so the client-side ranking below has values
        // to rank on.
        let branchFields = fields.map { $0 + sort.map(\.field) }
        // A sorted union must rank every branch's records before capping, so only an
        // unsorted union can bound its branch reads and stop early. A branch holding
        // `limit` matching rows always fills the union to `limit` on its own (dupes
        // it skips are already counted), so capped branches never under-collect.
        if let limit, sort.isEmpty {
            var seen: Set<String> = []
            var union: [EntityRecord] = []
            for branch in branches {
                for record in try await read(entity: entity, filters: branch, fields: branchFields, limit: limit) where seen.insert(record.uuid).inserted {
                    union.append(record)
                    if union.count == limit { return union }
                }
            }
            return union
        }
        // Every branch must be read in full, so the independent reads run concurrently;
        // the union then dedupes in branch order.
        let results = try await withThrowingTaskGroup(of: (Int, [EntityRecord]).self) { group in
            for (index, branch) in branches.enumerated() {
                group.addTask { (index, try await self.read(entity: entity, filters: branch, fields: branchFields)) }
            }
            var collected: [Int: [EntityRecord]] = [:]
            for try await (index, records) in group {
                collected[index] = records
            }
            return collected.sorted { $0.key < $1.key }.flatMap(\.value)
        }
        var seen: Set<String> = []
        let union = results.filter { seen.insert($0.uuid).inserted }
        guard sort.count > 0 else { return union }
        let ranked = union.sorted { Self.ordered($0, $1, by: sort) }
        guard let limit else { return ranked }
        return Array(ranked.prefix(limit))
    }

    public func changes(entity: String, since cursor: Date? = nil) async throws -> (records: [EntityRecord], cursor: Date?) {
        let definition = try await registry.definition(for: entity)
        var filters = [ServerFilter(field: "entity", op: .equals, value: .string(entity))]
        if let cursor {
            filters.append(ServerFilter(field: "modificationDate", op: .greaterThan, value: .date(cursor)))
        }
        let query = ckQuery(Entity.recordType, filters: filters)
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
