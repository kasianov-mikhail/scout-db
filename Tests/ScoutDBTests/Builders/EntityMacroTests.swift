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

// The macro-derived counterpart of the hand-written TypedPurchase: property
// names snake_case by default, @Field overrides, @Transient stays out.
@Entity("purchase")
private struct MacroPurchase {
    var productId: String?
    var quantity: Int64?
    @Field("amount") var price: Double?
    @Transient var badge: String?

    var caption: String {
        productId ?? "unknown"
    }
}

// Without an argument the entity name falls out of the type name.
@Entity
private struct CartEvent {
    var kind: String?
}

// A stored property with an observer stays a schema field — didSet/willSet
// must not make the macro treat it as computed and drop it.
@Entity("observed")
private struct ObservedEntity {
    var kind: String?
    var tally: Int64? {
        didSet {}
    }
}

@Suite("Entity macro")
struct EntityMacroTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await store.schema("purchase")
            .field("product_id", .string, .required)
            .field("quantity", .int)
            .field("amount", .double)
            .field("date", .timestamp)
            .envelopeDate("date")
            .create()
    }

    @Test("The derived conformance decodes, encodes, and resolves key paths")
    func derivedConformance() async throws {
        #expect(MacroPurchase.entityName == "purchase")
        #expect(CartEvent.entityName == "cart_event")
        #expect(MacroPurchase.fieldName(for: \.productId) == "product_id")
        #expect(MacroPurchase.fieldName(for: \.price) == "amount")
        #expect(MacroPurchase.fieldName(for: \.badge) == nil)

        try await store.write(
            ["product_id": .string("sku-1"), "quantity": .int(2), "amount": .double(25), "date": .date(Date(timeIntervalSince1970: 1_000))],
            entity: "purchase", uuid: "p-1")
        try await store.write(
            ["product_id": .string("sku-2"), "quantity": .int(7), "amount": .double(70), "date": .date(Date(timeIntervalSince1970: 2_000))],
            entity: "purchase", uuid: "p-2")

        // Typed queries run through the macro's key-path map.
        let big = try await store.query(MacroPurchase.self).filter(\.quantity > 5).all()
        #expect(big.map(\.productId) == ["sku-2"])
        #expect(big.first?.price == 70)
        #expect(big.first?.badge == nil)

        // recordValues encodes back through the same field map.
        let values = try #require(big.first?.recordValues)
        #expect(values["product_id"] == .string("sku-2"))
        #expect(values["amount"] == .double(70))
        #expect(values["badge"] == nil)
    }

    @Test("A stored property with a didSet observer still maps to a field")
    func observedStoredProperty() {
        #expect(ObservedEntity.fieldName(for: \.tally) == "tally")
        #expect(ObservedEntity(kind: "k", tally: 4).recordValues["tally"] == .int(4))
        let decoded = ObservedEntity(record: EntityRecord(entity: "observed", uuid: "o-1", schemaVersion: 1, values: ["tally": .int(9)]))
        #expect(decoded.tally == 9)
    }
}
