//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct TransactionStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case write, delete, update
    }

    public let kind: Kind
    public let entity: String
    public let uuid: String
    public let values: [String: RecordValue]

    public init(kind: Kind = .write, entity: String, uuid: String, values: [String: RecordValue] = [:]) {
        self.kind = kind
        self.entity = entity
        self.uuid = uuid
        self.values = values
    }

    // Steps persisted before deletes existed carry no kind; they are writes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .write
        entity = try container.decode(String.self, forKey: .entity)
        uuid = try container.decode(String.self, forKey: .uuid)
        values = try container.decode([String: RecordValue].self, forKey: .values)
    }
}

public struct TransactionDraft {
    public private(set) var steps: [TransactionStep] = []

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

extension EntityStore {
    public static let transactionEntity = "_txn"

    public static var transactionDefinition: EntityDefinition {
        EntityDefinition(
            entity: transactionEntity, version: 1,
            fields: [
                FieldDefinition(name: "status", type: .string, storage: .slot(.string, "s_00"), required: true, allowed: ["pending", "committed"]),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                FieldDefinition(name: "steps", type: .bytes, storage: .payload, required: true),
            ], envelopeDate: "date")
    }

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

    // Replays are at-least-once: record writes are idempotent through their fixed uuids,
    // but aggregate views count every write, so a repaired transaction may double-count
    // grid cells. Keep transactional entities and view-aggregated entities separate.
    @discardableResult public func repairTransactions(olderThan cutoff: Date? = nil) async throws -> Int {
        var filters = [Filter(field: "status", op: .equals, value: .string("pending"))]
        if let cutoff {
            filters.append(Filter(field: "date", op: .lessThan, value: .date(cutoff)))
        }

        let pending = try await read(entity: Self.transactionEntity, filters: filters)
        for transaction in pending {
            guard case .bytes(let data)? = transaction.values["steps"] else { continue }
            try await apply(try JSONDecoder().decode([TransactionStep].self, from: data))
            try await writeTransaction(status: "committed", steps: data, uuid: transaction.uuid)
        }
        return pending.count
    }

    // The transaction envelope record, written once as "pending" and again as "committed".
    private func writeTransaction(status: String, steps: Data, uuid: String) async throws {
        try await write(["status": .string(status), "date": .date(Date()), "steps": .bytes(steps)], entity: Self.transactionEntity, uuid: uuid)
    }

    // Consecutive write steps on one entity flush as a single batched write — order
    // across entities and kinds is preserved, and a repeated uuid starts a new batch
    // so later steps still overwrite earlier ones the way sequential writes did.
    // Deletes tombstone one by one and updates patch through the CAS rewrite; both
    // replay idempotently. An update of a missing record throws, leaving the
    // transaction pending for a later repair.
    private func apply(_ steps: [TransactionStep]) async throws {
        var index = 0
        while index < steps.count {
            guard steps[index].kind == .write else {
                let step = steps[index]
                if step.kind == .delete {
                    try await delete(entity: step.entity, uuid: step.uuid)
                } else {
                    try await update(entity: step.entity, uuid: step.uuid) { record in
                        for (name, value) in step.values {
                            record.values[name] = value
                        }
                    }
                }
                index += 1
                continue
            }
            let entity = steps[index].entity
            var uuids: Set<String> = []
            var batch: [EntityWrite] = []
            while index < steps.count, steps[index].kind == .write, steps[index].entity == entity, uuids.insert(steps[index].uuid).inserted {
                batch.append(EntityWrite(values: steps[index].values, uuid: steps[index].uuid))
                index += 1
            }
            try await write(batch, entity: entity)
        }
    }
}
