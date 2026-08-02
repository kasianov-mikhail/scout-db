//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

enum ContractBackend {
    static var containerID: String? {
        ProcessInfo.processInfo.environment["SCOUTDB_CONTRACT_CONTAINER"]
    }

    static var isLive: Bool {
        containerID != nil
    }

    static func makeDatabase() -> any CloudDatabase {
        guard let containerID else {
            return InMemoryDatabase()
        }
        return CKContainer(identifier: containerID).publicCloudDatabase
    }
}

struct ContractTimeoutError: Error {}

func eventually(timeout: Duration = .seconds(90), _ body: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + (ContractBackend.isLive ? timeout : .seconds(1))
    while true {
        do {
            if try await body() {
                return
            }
        } catch let error as CKError where ContractBackend.isLive && error.code == .unknownItem {
        }
        guard ContinuousClock.now < deadline else {
            throw ContractTimeoutError()
        }
        try await Task.sleep(for: ContractBackend.isLive ? .seconds(2) : .milliseconds(10))
    }
}

final class ContractFixture {
    let database: any CloudDatabase
    let registry: SchemaRegistry
    let store: EntityStore
    private let run: String
    private var published: [String] = []

    init() async throws {
        run = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        database = ContractBackend.makeDatabase()
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
    }

    func entity(_ name: String) -> String {
        "c\(run)_\(name)"
    }

    @discardableResult func publish(
        _ name: String, fields: [FieldDefinition], unique: [String]? = nil, aggregates: [AggregateDefinition]? = nil
    ) async throws -> String {
        let entity = entity(name)
        try await registry.publish(
            EntityDefinition(entity: entity, version: 1, fields: fields, unique: unique, aggregates: aggregates)
        )
        published.append(entity)
        return entity
    }

    func publishOrder(aggregates: [AggregateDefinition]? = nil) async throws -> String {
        try await publish(
            "order",
            fields: [
                FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "quantity", type: .int, storage: .slot(.int, "i_00")),
                FieldDefinition(name: "total", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                FieldDefinition(name: "note", type: .string, storage: .payload),
            ],
            aggregates: aggregates
        )
    }

    func tearDown() async {
        let descriptors = published.map { CKRecord.ID(recordName: "\($0)@1") }
        try? await database.modifyRecords(saving: [], deleting: descriptors)
    }
}

func withContract(_ body: (ContractFixture) async throws -> Void) async throws {
    let fixture = try await ContractFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.tearDown()
        throw error
    }
    await fixture.tearDown()
}

func orderValues(
    product: String = "sku-1", quantity: Int = 1, total: Double = 9.99, date: Date = Date(), note: String? = nil
) -> [String: RecordValue] {
    var values: [String: RecordValue] = [
        "product": .string(product), "quantity": .int(Int64(quantity)), "total": .double(total), "date": .date(date),
    ]
    if let note {
        values["note"] = .string(note)
    }
    return values
}
