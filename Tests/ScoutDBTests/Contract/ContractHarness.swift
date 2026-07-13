//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB
import ScoutDBTesting
import Testing

/// The backend a contract run exercises.
///
/// By default every contract test runs against `InMemoryDatabase` — fast,
/// hermetic, and part of the regular suite. Setting `SCOUTDB_CONTRACT_CONTAINER`
/// to a CloudKit container identifier switches the same tests to that
/// container's private database, which requires a signed test host with the
/// iCloud entitlement and a logged-in account — see LiveTestHost/README.md.
///
enum ContractBackend {
    static var containerID: String? {
        ProcessInfo.processInfo.environment["SCOUTDB_CONTRACT_CONTAINER"]
    }

    static var isLive: Bool {
        containerID != nil
    }

    static func makeDatabase() -> any CloudDatabase {
        guard let containerID else { return InMemoryDatabase() }
        return CKContainer(identifier: containerID).privateCloudDatabase
    }
}

struct ContractTimeoutError: Error {}

/// Polls the assertion until it holds, absorbing live CloudKit's indexing lag.
///
/// A freshly saved record reaches the query indexes seconds later, so a live
/// run retries until `timeout`; the in-memory double is immediately consistent
/// and settles on the first pass.
///
func eventually(timeout: Duration = .seconds(90), _ body: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + (ContractBackend.isLive ? timeout : .seconds(1))
    while true {
        if try await body() { return }
        guard ContinuousClock.now < deadline else { throw ContractTimeoutError() }
        try await Task.sleep(for: ContractBackend.isLive ? .seconds(2) : .milliseconds(10))
    }
}

/// One hermetic contract run: its own zone, run-salted entity names, and a
/// best-effort teardown that removes the zone and retires the schemas so a
/// live container does not accumulate state between runs.
final class ContractFixture {
    let database: any CloudDatabase
    let registry: SchemaRegistry
    let store: EntityStore
    let zoneID: CKRecordZone.ID
    private let run: String
    private var published: [String] = []

    init() async throws {
        run = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        database = ContractBackend.makeDatabase()
        zoneID = CKRecordZone.ID(zoneName: "contract_\(run)")
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry, zoneID: zoneID)
        try await store.ensureZone()
    }

    /// A run-unique entity name, so parallel and repeated runs never share schema rows.
    func entity(_ name: String) -> String {
        "c\(run)_\(name)"
    }

    @discardableResult func publish(
        _ name: String, fields: [FieldDefinition], envelopeDate: String? = nil, unique: [String]? = nil, views: [AggregateView]? = nil
    ) async throws -> String {
        let entity = entity(name)
        try await registry.publish(EntityDefinition(entity: entity, version: 1, fields: fields, envelopeDate: envelopeDate, unique: unique, views: views))
        published.append(entity)
        return entity
    }

    /// The order-like fixture most contract tests share.
    func publishOrder(views: [AggregateView]? = nil) async throws -> String {
        try await publish(
            "order",
            fields: [
                FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_00")),
                FieldDefinition(name: "quantity", type: .int, storage: .slot(.int, "i_00")),
                FieldDefinition(name: "total", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00")),
                FieldDefinition(name: "note", type: .string, storage: .payload),
            ], envelopeDate: "date", views: views)
    }

    func tearDown() async {
        for entity in published {
            try? await registry.retire(entity: entity)
        }
        // Dropping the zone drops every entity record the run wrote. The
        // in-memory double dies with the test, so only a live zone needs it.
        if let database = database as? CKDatabase {
            _ = try? await database.modifyRecordZones(saving: [], deleting: [zoneID])
        }
    }
}

/// Runs one contract test against a fresh fixture and always tears it down.
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

func orderValues(product: String = "sku-1", quantity: Int = 1, total: Double = 9.99, date: Date = Date(), note: String? = nil) -> [String: RecordValue] {
    var values: [String: RecordValue] = [
        "product": .string(product), "quantity": .int(Int64(quantity)), "total": .double(total), "date": .date(date),
    ]
    if let note {
        values["note"] = .string(note)
    }
    return values
}
