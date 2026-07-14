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

@Suite("Live query model")
struct LiveQueryModelTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)
        try await registry.publish(makePurchaseDefinition())
    }

    @Test("The model serves the current result and tracks local writes")
    @MainActor func tracksWrites() async throws {
        guard #available(iOS 17.0, macOS 14.0, *) else { return }
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")

        let model = store.query("purchase").live()
        try await poll { model.items.map(\.uuid) == ["p-1"] }

        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-2")
        try await poll { model.items.count == 2 }
        #expect(model.error == nil)
    }

    @Test("The model honors the built query's filters")
    @MainActor func honorsFilters() async throws {
        guard #available(iOS 17.0, macOS 14.0, *) else { return }
        var big = makePurchase().values
        big["quantity"] = .int(9)
        try await store.write(big, entity: "purchase", uuid: "p-big")
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-small")

        let model = store.query("purchase").filter("quantity" > 5).live()
        try await poll { model.items.map(\.uuid) == ["p-big"] }

        // A write leaving the filter untouched still ticks a pass; the result
        // stays filtered.
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-small-2")
        try await poll { model.items.map(\.uuid) == ["p-big"] }
    }

    @Test("A failing pass ends the tracking and surfaces the error")
    @MainActor func surfacesErrors() async throws {
        guard #available(iOS 17.0, macOS 14.0, *) else { return }
        try await store.write(makePurchase().values, entity: "purchase", uuid: "p-1")
        let model = store.query("purchase").live()
        try await poll { model.items.count == 1 }

        // The next tick's read fails; the model keeps the last result and
        // reports the failure.
        database.errors = [CKError(.notAuthenticated)]
        store.noteChange(entity: "purchase")
        try await poll { model.error != nil }
        #expect(model.items.count == 1)
    }

    @MainActor private func poll(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition never held")
    }
}
