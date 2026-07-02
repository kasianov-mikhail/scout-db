//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct TransactionStep: Codable, Equatable, Sendable {
    public let entity: String
    public let uuid: String
    public let values: [String: RecordValue]

    public init(entity: String, uuid: String, values: [String: RecordValue]) {
        self.entity = entity
        self.uuid = uuid
        self.values = values
    }
}

public struct TransactionDraft {
    public private(set) var steps: [TransactionStep] = []

    public mutating func write(_ values: [String: RecordValue], entity: String, uuid: String = UUID().uuidString) {
        steps.append(TransactionStep(entity: entity, uuid: uuid, values: values))
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
        try await write(["status": .string("pending"), "date": .date(Date()), "steps": .bytes(steps)], entity: Self.transactionEntity, uuid: uuid)
        try await apply(draft.steps)
        try await write(["status": .string("committed"), "date": .date(Date()), "steps": .bytes(steps)], entity: Self.transactionEntity, uuid: uuid)
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
            try await write(
                ["status": .string("committed"), "date": .date(Date()), "steps": .bytes(data)], entity: Self.transactionEntity, uuid: transaction.uuid)
        }
        return pending.count
    }

    private func apply(_ steps: [TransactionStep]) async throws {
        for step in steps {
            try await write(step.values, entity: step.entity, uuid: step.uuid)
        }
    }
}
