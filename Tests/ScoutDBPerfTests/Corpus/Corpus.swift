//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting

@testable import ScoutDB

enum DatasetSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    var customers: Int {
        switch self {
        case .small: 20
        case .medium: 200
        case .large: 2_000
        }
    }

    var orders: Int {
        switch self {
        case .small: 100
        case .medium: 1_000
        case .large: 10_000
        }
    }

    var items: Int {
        switch self {
        case .small: 60
        case .medium: 600
        case .large: 6_000
        }
    }

    var sessions: Int {
        switch self {
        case .small: 20
        case .medium: 200
        case .large: 2_000
        }
    }

    var records: Int {
        customers + orders + items + sessions
    }

    var iterations: Int {
        switch self {
        case .small, .medium: 8
        case .large: 2
        }
    }

    var deletions: Int {
        Swift.max(8, sessions / 20)
    }

    static var selected: [DatasetSize] {
        guard let raw = ProcessInfo.processInfo.environment["SCOUTDB_PERF_SIZES"] else {
            return allCases
        }
        let names = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let picked = allCases.filter { names.contains($0.rawValue) }
        return picked.isEmpty ? allCases : picked
    }
}

struct Corpus: @unchecked Sendable {
    let size: DatasetSize
    let records: [CKRecord]
    let customers: [String]
    let orders: [String]
    let items: [String]
    let now: Date

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let span: TimeInterval = 60 * 60 * 24 * 540
}

actor CorpusCache {
    static let shared = CorpusCache()

    private var built: [DatasetSize: Corpus] = [:]

    func corpus(for size: DatasetSize) async throws -> Corpus {
        if let corpus = built[size] {
            return corpus
        }
        let corpus = try await CorpusBuilder.build(size)
        built[size] = corpus
        return corpus
    }
}

enum CorpusBuilder {
    static func build(_ size: DatasetSize) async throws -> Corpus {
        let database = InMemoryDatabase()
        let registry = SchemaRegistry(database: database)
        let store = EntityStore(database: database, registry: registry)
        for definition in PerfSchema.definitions {
            try await registry.publish(definition)
        }

        var generator = SeededGenerator(seed: 0x5C00_7DB0 &+ UInt64(size.records))
        let customers = try await writeCustomers(size, store: store, generator: &generator)
        let orders = try await writeOrders(size, customers: customers, store: store, generator: &generator)
        let items = try await writeItems(size, orders: orders, store: store, generator: &generator)
        let sessions = try await writeSessions(size, customers: customers, store: store, generator: &generator)

        for index in 0..<size.deletions {
            try await store.delete(entity: PerfSchema.session, uuid: sessions[sessions.count - 1 - index])
        }

        return Corpus(
            size: size,
            records: database.records,
            customers: customers,
            orders: orders,
            items: items,
            now: Corpus.epoch
        )
    }

    private static func writeCustomers(_ size: DatasetSize, store: EntityStore, generator: inout SeededGenerator)
        async throws -> [String]
    {
        var uuids: [String] = []
        var batch: [EntityWrite] = []
        for index in 0..<size.customers {
            let uuid = String(format: "cus-%05d", index)
            var values: [String: RecordValue] = [
                "name": .string("Customer \(index)"),
                "email": .string("user\(index)@example.com"),
                "country": .string(generator.pick(PerfSchema.countries)),
                "signup": .date(Corpus.epoch.addingTimeInterval(-generator.unit() * Corpus.span)),
                "points": .double(Double(generator.index(below: 5_000))),
                "tags": .strings(tags(&generator)),
            ]
            if generator.unit() < 0.6 {
                values["bio"] = .string(
                    "Shops from \(PerfSchema.countries[generator.index(below: PerfSchema.countries.count)]) since 2019."
                )
            }
            uuids.append(uuid)
            batch.append(EntityWrite(values: values, uuid: uuid))
            if batch.count == 200 {
                try await store.write(batch, entity: PerfSchema.customer)
                batch = []
            }
        }
        if batch.count > 0 {
            try await store.write(batch, entity: PerfSchema.customer)
        }
        return uuids
    }

    private static func writeOrders(
        _ size: DatasetSize, customers: [String], store: EntityStore, generator: inout SeededGenerator
    ) async throws -> [String] {
        var uuids: [String] = []
        var batch: [EntityWrite] = []
        for index in 0..<size.orders {
            let uuid = String(format: "ord-%06d", index)
            let quantity = 1 + generator.index(below: 20)
            let price = 4.99 + Double(generator.index(below: 400))
            var values: [String: RecordValue] = [
                "customer": .string(customers[generator.skewed(below: customers.count)]),
                "product": .string(PerfSchema.products[generator.skewed(below: PerfSchema.products.count)]),
                "status": .string(generator.pick(PerfSchema.statuses)),
                "quantity": .int(Int64(quantity)),
                "total": .double((Double(quantity) * price * 100).rounded() / 100),
                "date": .date(Corpus.epoch.addingTimeInterval(-generator.unit() * Corpus.span)),
            ]
            if generator.unit() < 0.3 {
                values["note"] = .string("gift wrap")
            }
            uuids.append(uuid)
            batch.append(EntityWrite(values: values, uuid: uuid))
            if batch.count == 200 {
                try await store.write(batch, entity: PerfSchema.order)
                batch = []
            }
        }
        if batch.count > 0 {
            try await store.write(batch, entity: PerfSchema.order)
        }
        return uuids
    }

    private static func writeItems(
        _ size: DatasetSize, orders: [String], store: EntityStore, generator: inout SeededGenerator
    ) async throws -> [String] {
        var uuids: [String] = []
        var batch: [EntityWrite] = []
        for index in 0..<size.items {
            let uuid = String(format: "itm-%06d", index)
            let quantity = 1 + generator.index(below: 6)
            uuids.append(uuid)
            batch.append(
                EntityWrite(
                    values: [
                        "order": .string(orders[generator.skewed(below: orders.count)]),
                        "sku": .string(generator.pick(PerfSchema.products)),
                        "quantity": .int(Int64(quantity)),
                        "price": .double(Double(generator.index(below: 200)) + 0.99),
                        "added": .date(Corpus.epoch.addingTimeInterval(-generator.unit() * Corpus.span)),
                    ],
                    uuid: uuid
                )
            )
            if batch.count == 200 {
                try await store.write(batch, entity: PerfSchema.item)
                batch = []
            }
        }
        if batch.count > 0 {
            try await store.write(batch, entity: PerfSchema.item)
        }
        return uuids
    }

    private static func writeSessions(
        _ size: DatasetSize, customers: [String], store: EntityStore, generator: inout SeededGenerator
    ) async throws -> [String] {
        var uuids: [String] = []
        var batch: [EntityWrite] = []
        for index in 0..<size.sessions {
            let uuid = String(format: "ses-%05d", index)
            uuids.append(uuid)
            batch.append(
                EntityWrite(
                    values: [
                        "customer": .string(customers[generator.skewed(below: customers.count)]),
                        "device": .string(generator.pick(PerfSchema.devices)),
                        "started": .date(Corpus.epoch.addingTimeInterval(-generator.unit() * 60 * 60 * 24 * 90)),
                        "seconds": .int(Int64(generator.index(below: 7_200))),
                    ],
                    uuid: uuid
                )
            )
            if batch.count == 200 {
                try await store.write(batch, entity: PerfSchema.session)
                batch = []
            }
        }
        if batch.count > 0 {
            try await store.write(batch, entity: PerfSchema.session)
        }
        return uuids
    }

    private static func tags(_ generator: inout SeededGenerator) -> [String] {
        var picked: [String] = []
        for interest in PerfSchema.interests where generator.unit() < 0.35 {
            picked.append(interest)
        }
        return picked
    }
}
