//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct TransactionStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case write, delete, update
    }

    let kind: Kind
    let entity: String
    let uuid: String
    let values: [String: RecordValue]

    init(kind: Kind = .write, entity: String, uuid: String, values: [String: RecordValue] = [:]) {
        self.kind = kind
        self.entity = entity
        self.uuid = uuid
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .write
        entity = try container.decode(String.self, forKey: .entity)
        uuid = try container.decode(String.self, forKey: .uuid)
        values = try container.decode([String: RecordValue].self, forKey: .values)
    }
}

public struct TransactionDraft {
    private(set) var steps: [TransactionStep] = []

    public mutating func write(_ values: [String: RecordValue], entity: String, uuid: String = UUID().uuidString) {
        steps.append(TransactionStep(entity: entity, uuid: uuid, values: values))
    }

    public mutating func delete(entity: String, uuid: String) {
        steps.append(TransactionStep(kind: .delete, entity: entity, uuid: uuid))
    }

    /// Patches an existing record.
    ///
    /// The given values overwrite their fields, the rest of the record stays.
    /// Setting absolute values keeps replays idempotent.
    ///
    public mutating func update(_ values: [String: RecordValue], entity: String, uuid: String) {
        steps.append(TransactionStep(kind: .update, entity: entity, uuid: uuid, values: values))
    }
}

extension TransactionStep {
    fileprivate func isFreshWrite(of entity: String, seen uuids: inout Set<String>) -> Bool {
        guard kind == .write, self.entity == entity else {
            return false
        }
        return uuids.insert(uuid).inserted
    }
}

extension EntityDefinition {
    static var transaction: EntityDefinition {
        EntityDefinition(
            entity: EntityStore.transactionEntity, version: 1,
            fields: [
                FieldDefinition(name: "status", type: .string, storage: .slot(.string, "s_00"), required: true, allowed: ["pending", "committed"]),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                FieldDefinition(name: "steps", type: .bytes, storage: .payload, required: true),
            ])
    }
}

extension EntityStore {
    static let transactionEntity = "_txn"

    @discardableResult public func transaction(_ body: (inout TransactionDraft) throws -> Void) async throws -> String {
        var draft = TransactionDraft()
        try body(&draft)

        let uuid = UUID().uuidString
        let steps = try JSONEncoder().encode(draft.steps)
        try await writeTransaction(status: "pending", steps: steps, uuid: uuid)
        try await apply(draft.steps)
        try await writeTransaction(status: "committed", steps: steps, uuid: uuid)
        return uuid
    }

    @discardableResult public func repairTransactions(olderThan cutoff: Date? = nil) async throws -> Int {
        var filters = [Filter(field: "status", op: .equals, value: .string("pending"))]
        if let cutoff {
            filters.append(Filter(field: "date", op: .lessThan, value: .date(cutoff)))
        }

        let pending = try await read(entity: Self.transactionEntity, filters: filters)
        for transaction in pending {
            guard case .bytes(let data)? = transaction.values["steps"] else {
                continue
            }
            try await apply(try JSONDecoder().decode([TransactionStep].self, from: data))
            try await writeTransaction(status: "committed", steps: data, uuid: transaction.uuid)
        }
        return pending.count
    }

    @discardableResult public func compactTransactions(olderThan cutoff: Date) async throws -> Int {
        try await purge(
            entity: Self.transactionEntity,
            filters: [
                Filter(field: "status", op: .equals, value: .string("committed")),
                Filter(field: "date", op: .lessThan, value: .date(cutoff)),
            ])
    }

    private func writeTransaction(status: String, steps: Data, uuid: String) async throws {
        try await write(["status": .string(status), "date": .date(Date()), "steps": .bytes(steps)], entity: Self.transactionEntity, uuid: uuid)
    }

    private func apply(_ steps: [TransactionStep]) async throws {
        var index = 0
        while index < steps.count {
            switch steps[index].kind {
            case .update:
                var order: [String] = []
                var run: [TransactionStep] = []
                while index < steps.count, steps[index].kind == .update {
                    if !order.contains(steps[index].entity) {
                        order.append(steps[index].entity)
                    }
                    run.append(steps[index])
                    index += 1
                }
                for entity in order {
                    var uuids: [String] = []
                    var patches: [String: [String: RecordValue]] = [:]
                    for step in run where step.entity == entity {
                        if patches[step.uuid] == nil {
                            uuids.append(step.uuid)
                        }
                        patches[step.uuid, default: [:]].merge(step.values) { _, latest in latest }
                    }
                    try await update(entity: entity, uuids: uuids) { record in
                        for (name, value) in patches[record.uuid] ?? [:] {
                            record.values[name] = value
                        }
                    }
                }
            case .delete:
                var order: [String] = []
                var targets: [String: [String]] = [:]
                while index < steps.count, steps[index].kind == .delete {
                    if targets[steps[index].entity] == nil {
                        order.append(steps[index].entity)
                    }
                    targets[steps[index].entity, default: []].append(steps[index].uuid)
                    index += 1
                }
                for entity in order {
                    try await delete(entity: entity, uuids: targets[entity] ?? [])
                }
            case .write:
                if enforceReferences {
                    let entity = steps[index].entity
                    var uuids: Set<String> = []
                    var batch: [EntityWrite] = []
                    while index < steps.count, steps[index].isFreshWrite(of: entity, seen: &uuids) {
                        batch.append(EntityWrite(values: steps[index].values, uuid: steps[index].uuid))
                        index += 1
                    }
                    try await write(batch, entity: entity)
                    continue
                }
                var order: [String] = []
                var batches: [String: [[EntityWrite]]] = [:]
                var seen: [String: Set<String>] = [:]
                while index < steps.count, steps[index].kind == .write {
                    let step = steps[index]
                    if batches[step.entity] == nil {
                        order.append(step.entity)
                        batches[step.entity] = [[]]
                        seen[step.entity] = []
                    }
                    if seen[step.entity]?.insert(step.uuid).inserted == false {
                        batches[step.entity]?.append([])
                        seen[step.entity] = [step.uuid]
                    }
                    let last = (batches[step.entity]?.count ?? 1) - 1
                    batches[step.entity]?[last].append(EntityWrite(values: step.values, uuid: step.uuid))
                    index += 1
                }
                for entity in order {
                    for batch in batches[entity] ?? [] {
                        try await write(batch, entity: entity)
                    }
                }
            }
        }
    }
}
