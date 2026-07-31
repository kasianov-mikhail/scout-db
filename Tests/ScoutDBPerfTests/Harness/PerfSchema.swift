//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CryptoKit
import Foundation

@testable import ScoutDB

enum PerfSchema {
    static let customer = "customer"
    static let order = "order"
    static let item = "item"
    static let session = "session"

    static let keyID = "perf-key"

    static let products = [
        "sku-air", "sku-pro", "sku-max", "sku-mini", "sku-studio", "sku-ultra",
        "sku-lite", "sku-plus", "sku-core", "sku-nano", "sku-edge", "sku-prime",
    ]
    static let countries = ["de", "fr", "gb", "it", "es", "pl", "nl", "se"]
    static let statuses = ["placed", "paid", "shipped", "refunded"]
    static let devices = ["iphone", "ipad", "mac", "watch", "vision"]
    static let interests = ["photo", "music", "travel", "fitness", "reading", "cooking"]

    static var customerDefinition: EntityDefinition {
        EntityDefinition(
            entity: customer, version: 1,
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_00"), required: true),
                FieldDefinition(name: "email", type: .string, storage: .slot(.string, "s_01"), required: true),
                FieldDefinition(name: "country", type: .string, storage: .slot(.string, "s_02"), required: true, allowed: countries),
                FieldDefinition(name: "signup", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                FieldDefinition(name: "points", type: .double, storage: .slot(.double, "d_00")),
                FieldDefinition(name: "tags", type: .stringList, storage: .slot(.stringList, "ls_00")),
                FieldDefinition(name: "avatar", type: .asset, storage: .slot(.asset, "a_00")),
                FieldDefinition(name: "bio", type: .text, storage: .payload),
            ], uniqueKeys: [["email"]],
            views: [AggregateView(name: "by_country", groupBy: "country")])
    }

    static var orderDefinition: EntityDefinition {
        EntityDefinition(
            entity: order, version: 1,
            fields: [
                FieldDefinition(name: "customer", type: .string, storage: .slot(.string, "s_00"), required: true, references: customer),
                FieldDefinition(name: "product", type: .string, storage: .slot(.string, "s_01"), required: true, allowed: products),
                FieldDefinition(name: "status", type: .string, storage: .slot(.string, "s_02"), required: true, allowed: statuses),
                FieldDefinition(name: "quantity", type: .int, storage: .slot(.int, "i_00"), required: true, min: 1, max: 20),
                FieldDefinition(name: "total", type: .double, storage: .slot(.double, "d_00"), required: true),
                FieldDefinition(name: "date", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                FieldDefinition(name: "note", type: .string, storage: .payload),
            ],
            views: [
                AggregateView(name: "revenue", groupBy: "product", sum: "total"),
                AggregateView(name: "peak", groupBy: "product", max: "total", exact: true),
                AggregateView(name: "by_status", groupBy: "status"),
                AggregateView(name: "by_quantity", groupBy: "quantity"),
            ])
    }

    static var itemDefinition: EntityDefinition {
        EntityDefinition(
            entity: item, version: 1,
            fields: [
                FieldDefinition(name: "order", type: .string, storage: .slot(.string, "s_00"), required: true, references: order),
                FieldDefinition(name: "sku", type: .string, storage: .slot(.string, "s_01"), required: true, allowed: products),
                FieldDefinition(name: "quantity", type: .int, storage: .slot(.int, "i_00"), required: true),
                FieldDefinition(name: "price", type: .double, storage: .slot(.double, "d_00"), required: true),
                FieldDefinition(name: "added", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
            ])
    }

    static var sessionDefinition: EntityDefinition {
        EntityDefinition(
            entity: session, version: 1,
            fields: [
                FieldDefinition(name: "customer", type: .string, storage: .slot(.string, "s_00"), required: true, references: customer),
                FieldDefinition(name: "device", type: .string, storage: .slot(.string, "s_01"), required: true, allowed: devices),
                FieldDefinition(name: "started", type: .timestamp, storage: .slot(.timestamp, "t_00"), required: true),
                FieldDefinition(name: "seconds", type: .int, storage: .slot(.int, "i_00")),
                FieldDefinition(name: "token", type: .string, storage: .payload, encrypted: true),
            ], views: nil, keyID: keyID)
    }

    static var definitions: [EntityDefinition] {
        [customerDefinition, orderDefinition, itemDefinition, sessionDefinition]
    }
}

struct PerfKeyProvider: EncryptionKeyProvider {
    func key(for keyID: String) throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 7, count: 32))
    }
}
