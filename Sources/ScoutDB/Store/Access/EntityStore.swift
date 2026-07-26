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
    let assigned: Bool

    /// Writes under a uuid of the caller's choosing, replacing any record that
    /// already carries it.
    public init(values: [String: RecordValue], uuid: String) {
        self.values = values
        self.uuid = uuid
        self.assigned = true
    }

    /// Writes under a fresh uuid, which no stored record can hold.
    public init(values: [String: RecordValue]) {
        self.values = values
        self.uuid = UUID().uuidString
        self.assigned = false
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
        /// A negated filter keeps the records its predicate does NOT match.
        ///
        /// It runs on the server as the complementary operator when the field
        /// is always present — `required`, or carrying a default — and
        /// otherwise client-side, where a record missing the field is kept.
        ///
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
        /// A `.location` origin turns the clause into a nearest-first distance
        /// sort of a location field.
        public var origin: RecordValue?

        public init(field: String, ascending: Bool = true) {
            self.field = field
            self.ascending = ascending
        }

        /// Sorts nearest-first by the location field's distance from the point.
        public static func distance(from field: String, latitude: Double, longitude: Double) -> Sort {
            var sort = Sort(field: field)
            sort.origin = .location(latitude: latitude, longitude: longitude)
            return sort
        }
    }

    @discardableResult public func write(_ values: [String: RecordValue], entity: String, uuid: String? = nil) async throws -> String {
        let entry = uuid.map { EntityWrite(values: values, uuid: $0) } ?? EntityWrite(values: values)
        return try await write([entry], entity: entity)[0]
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

        var stored: Set<String> = []
        let entityRecords = try batch.map { entry in
            let resolved = try coder.resolve(entry.values, at: definition.version, using: definition)
            let natural = try coder.naturalUUID(for: resolved, using: definition)
            let uuid = natural ?? entry.uuid
            if natural != nil || entry.assigned {
                stored.insert(uuid)
            }
            return EntityRecord(entity: entity, uuid: uuid, schemaVersion: definition.version, values: resolved)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            if enforceReferences {
                group.addTask { try await validateReferences(of: entityRecords, using: definition) }
            }
            group.addTask { try await validateUniqueKeys(of: entityRecords, using: definition) }
            try await group.waitForAll()
        }
        try await claimUniqueKeys(of: entityRecords, using: definition)

        let (removedFromViews, addedToViews) = try await aggregationRebalance(entityRecords, stored: stored, using: definition)

        let encoded = try entityRecords.map { try coder.encode($0, using: definition) }
        try await database.write(records: encoded)
        EntityCoder.discardStagedAssets(in: encoded)
        try await GridAggregator(database: database).rebalance(removing: removedFromViews, adding: addedToViews, using: definition)
        noteChange(entity: entity)
        return entityRecords.map(\.uuid)
    }

    private func aggregationRebalance(_ records: [EntityRecord], stored: Set<String>, using definition: EntityDefinition) async throws -> (
        removing: [EntityRecord], adding: [EntityRecord]
    ) {
        guard definition.views?.isEmpty == false else { return ([], []) }
        var latest: [String: EntityRecord] = [:]
        for record in records { latest[record.uuid] = record }
        let live = try await liveRecords(entity: definition.entity, uuids: latest.keys.filter(stored.contains), using: definition)
        let liveByUUID = Dictionary(live.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var removing: [EntityRecord] = []
        var adding: [EntityRecord] = []
        for (uuid, record) in latest {
            if let old = liveByUUID[uuid] { removing.append(old) }
            adding.append(record)
        }
        return (removing, adding)
    }

    public func delete(entity: String, uuid: String) async throws {
        try await delete(entity: entity, uuids: [uuid])
    }

    func delete(entity: String, uuids: [String]) async throws {
        guard uuids.count > 0 else { return }
        var targets: [String] = []
        var seen: Set<String> = []
        for uuid in uuids where seen.insert(uuid).inserted {
            targets.append(uuid)
        }
        let definition = try await registry.definition(for: entity)
        let removed = try decode(try await items(entity: entity, uuids: targets), using: definition).filter { !$0.deleted }
        let values = Dictionary(removed.map { ($0.uuid, $0.values) }, uniquingKeysWith: { first, _ in first })
        let tombstones = try targets.map { try tombstone(entity: entity, uuid: $0, definition: definition, values: values[$0] ?? [:]) }
        try await database.write(records: tombstones)
        await releaseUniqueClaims(of: removed, using: definition)
        try await GridAggregator(database: database).remove(removed, using: definition)
        try await recordRevisions(removed, using: definition)
        noteChange(entity: entity)
    }

    func liveRecords(entity: String, uuids: [String], using definition: EntityDefinition) async throws -> [EntityRecord] {
        guard definition.views?.isEmpty == false else { return [] }
        return try decode(try await items(entity: entity, uuids: uuids), using: definition).filter { !$0.deleted }
    }

    func tombstone(entity: String, uuid: String, definition: EntityDefinition, values: [String: RecordValue] = [:]) throws -> CKRecord {
        try EntityCoder(keyProvider: keyProvider, zoneID: zoneID)
            .encode(EntityRecord(entity: entity, uuid: uuid, schemaVersion: definition.version, values: values, deleted: true), using: definition)
    }

    public func read(
        entity: String, filters: [Filter] = [], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil, createdBy creator: String? = nil
    ) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        if try clientRanked(sort, using: definition) {
            let projection = fields.map { $0 + sort.map(\.field) }
            let ranked = try await read(entity: entity, filters: filters, fields: projection, createdBy: creator)
                .sorted { Self.ordered($0, $1, by: sort) }
            guard let limit else { return ranked }
            return Array(ranked.prefix(limit))
        }
        let (query, included) = try liveQuery(filters, entity: entity, sort: try serverSort(sort, using: definition), createdBy: creator, using: definition)
        let keys = try fields.map { try desiredKeys($0 + filters.map(\.field), using: definition) }
        if let limit {
            return Array(try await boundedRecords(matching: query, desiredKeys: keys, limit: limit, using: definition, where: included).prefix(limit))
        }
        return try decode(try await database.allRecords(matching: query, inZone: zoneID, desiredKeys: keys), using: definition).filter(included)
    }

    func liveQuery(_ filters: [Filter], entity: String, sort: [ServerSort] = [], createdBy creator: String? = nil, using definition: EntityDefinition)
        throws
        -> (query: CKQuery, included: (EntityRecord) -> Bool)
    {
        var (server, client) = try split(filters, entity: entity, using: definition)
        server.append(ServerFilter(field: "deleted", op: .equals, value: .int(0)))
        if let creator {
            server.append(ServerFilter(field: "creatorUserRecordID", op: .equals, value: .reference(creator)))
        }
        let matchers = try client.map { filter in
            let base = try Self.matcher(for: filter)
            return filter.negated ? { !base($0) } : base
        }
        return (
            ckQuery(Entity.recordType, filters: server, sort: sort),
            { record in !record.deleted && matchers.allSatisfy { $0(record) } }
        )
    }

    func boundedRecords(
        matching query: CKQuery, desiredKeys: [String]?, limit: Int, using definition: EntityDefinition, where included: (EntityRecord) -> Bool
    ) async throws -> [EntityRecord] {
        var collected: [EntityRecord] = []
        var page = Swift.min(limit, CKQueryOperation.maximumResults)
        var (batch, token) = try await database.records(matching: query, inZone: zoneID, desiredKeys: desiredKeys, resultsLimit: page)
        while true {
            collected += try decode(batch.map { try $0.1.get() }, using: definition).filter(included)
            guard collected.count < limit, let cursor = token else { break }
            page = Swift.min(page * 2, CKQueryOperation.maximumResults)
            (batch, token) = try await database.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: page)
        }
        return collected
    }

    private func clientRanked(_ sort: [Sort], using definition: EntityDefinition) throws -> Bool {
        try sort.contains { clause in
            guard let field = definition.field(named: clause.field, at: definition.version) else {
                throw SchemaError.unknownField(clause.field)
            }
            guard case .payload = field.storage else { return false }
            return true
        }
    }

    func desiredKeys(_ fields: [String], using definition: EntityDefinition) throws -> [String] {
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

    public func read(
        entity: String, any branches: [[Filter]], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil, createdBy creator: String? = nil
    ) async throws -> [EntityRecord] {
        let branchFields = fields.map { $0 + sort.map(\.field) }
        if let limit, sort.isEmpty {
            var seen: Set<String> = []
            var union: [EntityRecord] = []
            for branch in branches {
                let page = try await read(entity: entity, filters: branch, fields: branchFields, limit: limit, createdBy: creator)
                for record in page where seen.insert(record.uuid).inserted {
                    union.append(record)
                    if union.count == limit { return union }
                }
            }
            return union
        }
        let results = try await withThrowingTaskGroup(of: (Int, [EntityRecord]).self) { group in
            for (index, branch) in branches.enumerated() {
                group.addTask { (index, try await self.read(entity: entity, filters: branch, fields: branchFields, createdBy: creator)) }
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
        let records = try await database.allRecords(matching: query, inZone: zoneID)
        let next = records.compactMap(\.recordModificationDate).max() ?? cursor
        return (try decode(records, using: definition), next)
    }

    func decode(_ records: [CKRecord], using definition: EntityDefinition) throws -> [EntityRecord] {
        let coder = EntityCoder(keyProvider: keyProvider)
        return try records.compactMap { try decode($0, with: coder, using: definition) }
    }

    func decode(_ record: CKRecord, with coder: EntityCoder, using definition: EntityDefinition) throws -> EntityRecord? {
        if let trustedWriters {
            guard let creator = record.recordCreator, trustedWriters.contains(creator) else { return nil }
        }
        return try coder.decode(record, using: definition)
    }
}
