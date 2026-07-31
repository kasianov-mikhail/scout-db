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
    let slots = SlotCache()

    var aggregator: GridAggregator {
        GridAggregator(database: database, slots: slots)
    }

    /// Creates a store backed by any `CloudDatabase` implementation.
    ///
    /// With `enforceReferences` on, every write checks that its reference fields
    /// name live parent records and throws `SchemaError.brokenReference` otherwise.
    ///
    public init(
        database: any CloudDatabase, registry: SchemaRegistry, keyProvider: (any EncryptionKeyProvider)? = nil, trustedWriters: Set<String>? = nil,
        enforceReferences: Bool = false
    ) {
        self.database = database
        self.registry = registry
        self.keyProvider = keyProvider
        self.trustedWriters = trustedWriters
        self.enforceReferences = enforceReferences
    }

    struct Filter: Equatable, Sendable {
        let field: String
        let op: Match
        let value: RecordValue
        var negated = false

        init(field: String, op: Match, value: RecordValue, negated: Bool = false) {
            self.field = field
            self.op = op
            self.value = value
            self.negated = negated
        }
    }

    struct Sort: Equatable, Sendable {
        let field: String
        var ascending = true

        init(field: String, ascending: Bool = true) {
            self.field = field
            self.ascending = ascending
        }
    }

    @discardableResult public func write(_ values: [String: RecordValue], entity: String, uuid: String? = nil) async throws -> String {
        let entry = uuid.map { EntityWrite(values: values, uuid: $0) } ?? EntityWrite(values: values)
        return try await write([entry], entity: entity)[0]
    }

    @discardableResult public func write(_ batch: [EntityWrite], entity: String) async throws -> [String] {
        guard batch.count > 0 else {
            return []
        }
        let definition = try await registry.definition(for: entity)
        let coder = EntityCoder(keyProvider: keyProvider)

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

        if enforceReferences {
            try await validateReferences(of: entityRecords, using: definition)
        }
        try await claimUniqueKeys(of: entityRecords, using: definition)

        let (removedFromViews, addedToViews) = try await aggregationRebalance(entityRecords, stored: stored, using: definition)

        let encoded = try entityRecords.map { try coder.encode($0, using: definition) }
        try await database.write(records: encoded)
        try await aggregator.rebalance(removing: removedFromViews, adding: addedToViews, using: definition)
        return entityRecords.map(\.uuid)
    }

    private func aggregationRebalance(_ records: [EntityRecord], stored: Set<String>, using definition: EntityDefinition) async throws -> (
        removing: [EntityRecord], adding: [EntityRecord]
    ) {
        guard definition.views?.isEmpty == false else {
            return ([], [])
        }
        var latest: [String: EntityRecord] = [:]
        for record in records { latest[record.uuid] = record }
        let live = try await liveRecords(entity: definition.entity, uuids: latest.keys.filter(stored.contains), using: definition)
        let liveByUUID = Dictionary(live.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var removing: [EntityRecord] = []
        var adding: [EntityRecord] = []
        for (uuid, record) in latest {
            if let old = liveByUUID[uuid] {
                removing.append(old)
            }
            adding.append(record)
        }
        return (removing, adding)
    }

    public func delete(entity: String, uuid: String) async throws {
        try await delete(entity: entity, uuids: [uuid])
    }

    func delete(entity: String, uuids: [String]) async throws {
        guard uuids.count > 0 else {
            return
        }
        var targets: [String] = []
        var seen: Set<String> = []
        for uuid in uuids where seen.insert(uuid).inserted {
            targets.append(uuid)
        }
        let definition = try await registry.definition(for: entity)
        let removed = try decode(try await items(entity: entity, uuids: targets), using: definition)
        try await database.delete(records: targets.map { CKRecord.ID(recordName: $0) })
        try await settle(removed: removed, using: definition)
    }

    fileprivate func liveRecords(entity: String, uuids: [String], using definition: EntityDefinition) async throws -> [EntityRecord] {
        guard definition.views?.isEmpty == false else {
            return []
        }
        return try decode(try await items(entity: entity, uuids: uuids), using: definition)
    }

    func read(
        entity: String, filters: [Filter] = [], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil
    ) async throws -> [EntityRecord] {
        let definition = try await registry.definition(for: entity)
        if try clientRanked(sort, using: definition) {
            let projection = fields.map { $0 + sort.map(\.field) }
            let ranked = try await read(entity: entity, filters: filters, fields: projection)
                .sorted { Self.ordered($0, $1, by: sort) }
            guard let limit else {
                return ranked
            }
            return Array(ranked.prefix(limit))
        }
        let (query, included) = try liveQuery(filters, entity: entity, sort: try serverSort(sort, using: definition), using: definition)
        let keys = try fields.map { try desiredKeys($0 + filters.map(\.field), using: definition) }
        if let limit {
            return Array(try await boundedRecords(matching: query, desiredKeys: keys, limit: limit, using: definition, where: included).prefix(limit))
        }
        return try decode(try await database.allRecords(matching: query, desiredKeys: keys), using: definition).filter(included)
    }

    func liveQuery(_ filters: [Filter], entity: String, sort: [ServerSort] = [], using definition: EntityDefinition)
        throws
        -> (query: CKQuery, included: (EntityRecord) -> Bool)
    {
        let (server, client) = try split(filters, entity: entity, using: definition)
        let matchers = try Self.matchers(for: client)
        return (
            CKQuery(recordType: "Entity", filters: server, sort: sort),
            { record in matchers.allSatisfy { $0(record) } }
        )
    }

    func boundedRecords(
        matching query: CKQuery, desiredKeys: [String]?, limit: Int, using definition: EntityDefinition, where included: (EntityRecord) -> Bool
    ) async throws -> [EntityRecord] {
        var collected: [EntityRecord] = []
        var page = Self.cappedPage(limit == Int.max ? limit : limit + 1)
        var (batch, token) = try await database.records(matching: query, desiredKeys: desiredKeys, resultsLimit: page)
        while true {
            collected += try decode(batch.map { try $0.1.get() }, using: definition).filter(included)
            guard collected.count < limit, let cursor = token else {
                break
            }
            page = page < Int.max / 2 ? Self.cappedPage(page * 2) : page
            (batch, token) = try await database.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys, resultsLimit: page)
        }
        return collected
    }

    private static func cappedPage(_ rows: Int) -> Int {
        let maximum = CKQueryOperation.maximumResults
        return maximum > 0 ? Swift.min(rows, maximum) : rows
    }

    private func rankable(_ sort: [Sort], entity: String) async throws -> Bool {
        guard sort.count > 0 else {
            return true
        }
        let definition = try await registry.definition(for: entity)
        if (try? clientRanked(sort, using: definition)) == true {
            return true
        }
        return (try? serverSort(sort, using: definition)) != nil
    }

    private func clientRanked(_ sort: [Sort], using definition: EntityDefinition) throws -> Bool {
        try sort.contains { clause in
            guard let field = definition.field(named: clause.field, at: definition.version) else {
                throw SchemaError.unknownField(clause.field)
            }
            guard case .payload = field.storage else {
                return false
            }
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
                if !keys.contains("payload") {
                    keys.append("payload")
                }
            }
        }
        return keys
    }

    func read(
        entity: String, any branches: [[Filter]], sort: [Sort] = [], fields: [String]? = nil, limit: Int? = nil
    ) async throws -> [EntityRecord] {
        if branches.count == 1 {
            return try await read(entity: entity, filters: branches[0], sort: sort, fields: fields, limit: limit)
        }
        let branchFields = fields.map { $0 + sort.map(\.field) }
        if let limit, sort.isEmpty {
            var seen: Set<String> = []
            var union: [EntityRecord] = []
            for branch in branches {
                let page: [EntityRecord] = try await read(entity: entity, filters: branch, fields: branchFields, limit: limit)
                for record in page where seen.insert(record.uuid).inserted {
                    union.append(record)
                    if union.count == limit {
                        return union
                    }
                }
            }
            return union
        }
        let bounded = try await rankable(sort, entity: entity)
        let results = try await withThrowingTaskGroup(of: (Int, [EntityRecord]).self) { group in
            for (index, branch) in branches.enumerated() {
                group.addTask {
                    (
                        index,
                        try await self.read(
                            entity: entity, filters: branch, sort: bounded ? sort : [], fields: branchFields, limit: bounded ? limit : nil)
                    )
                }
            }
            var collected: [Int: [EntityRecord]] = [:]
            for try await (index, records) in group {
                collected[index] = records
            }
            return collected.sorted { $0.key < $1.key }.flatMap(\.value)
        }
        var seen: Set<String> = []
        let union = results.filter { seen.insert($0.uuid).inserted }
        guard sort.count > 0 else {
            return union
        }
        let ranked = union.sorted { Self.ordered($0, $1, by: sort) }
        guard let limit else {
            return ranked
        }
        return Array(ranked.prefix(limit))
    }

    func forEachPage(matching query: CKQuery, desiredKeys: [String]? = nil, using definition: EntityDefinition, _ body: ([EntityRecord]) async throws -> Void)
        async throws
    {
        try await database.forEachPage(matching: query, desiredKeys: desiredKeys) { page in
            try await body(try decode(page, using: definition))
        }
    }

    func forEachPage(entity: String, fields: [String]? = nil, _ body: ([EntityRecord]) async throws -> Void) async throws {
        let definition = try await registry.definition(for: entity)
        let (query, included) = try liveQuery([], entity: entity, using: definition)
        let keys = try fields.map { try desiredKeys($0, using: definition) }
        try await forEachPage(matching: query, desiredKeys: keys, using: definition) { page in
            try await body(page.filter(included))
        }
    }

    func decode(_ records: [CKRecord], using definition: EntityDefinition) throws -> [EntityRecord] {
        let coder = EntityCoder(keyProvider: keyProvider)
        return try records.compactMap { try decode($0, with: coder, using: definition) }
    }

    func decode(_ record: CKRecord, with coder: EntityCoder, using definition: EntityDefinition) throws -> EntityRecord? {
        guard trusted(record) else {
            return nil
        }
        return try coder.decode(record, using: definition)
    }

    fileprivate func trusted(_ record: CKRecord) -> Bool {
        guard let trustedWriters else {
            return true
        }
        guard let creator = record.creatorName else {
            return false
        }
        return trustedWriters.contains(creator)
    }
}
