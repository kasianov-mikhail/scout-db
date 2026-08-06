//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Testing

@testable import ScoutDB

@Suite("Resolve")
struct ResolveTests {
    let definition = makePurchaseDefinition()

    @Test("Resolve rejects a value of the wrong type")
    func typeMismatch() {
        var purchase = makePurchase()
        purchase.values["quantity"] = .string("three")
        #expect(throws: SchemaError.typeMismatch("quantity")) {
            try definition.resolve(purchase.values, at: purchase.schemaVersion)
        }
    }

    @Test("Resolve rejects a field missing from the definition")
    func unknownField() {
        var purchase = makePurchase()
        purchase.values["color"] = .string("red")
        #expect(throws: SchemaError.unknownField("color")) {
            try definition.resolve(purchase.values, at: purchase.schemaVersion)
        }
    }

    @Test("Defaults fill missing values")
    func defaults() throws {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(
                    name: "level",
                    type: .string,
                    storage: .slot(.string, "s_01"),
                    defaultValue: .string("info")
                )
            ]
        )
        let resolved = try definition.resolve([:], at: 2)
        #expect(resolved["level"] == .string("info"))
    }

    @Test("Missing required field throws")
    func requiredField() {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "name", type: .string, storage: .slot(.string, "s_01"), required: true)
            ]
        )
        #expect(throws: SchemaError.missingField("name")) {
            try definition.resolve([:], at: 2)
        }
    }

    @Test("Value outside the enum domain throws")
    func allowedDomain() {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(
                    name: "level",
                    type: .string,
                    storage: .slot(.string, "s_01"),
                    allowed: ["info", "error"]
                )
            ]
        )
        #expect(throws: SchemaError.invalidValue(.outsideDomain(field: "level"))) {
            try definition.resolve(["level": .string("debug")], at: 2)
        }
    }

    @Test("Value below the minimum throws")
    func range() {
        let definition = makeDefinition(
            entity: "log",
            fields: [
                FieldDefinition(name: "count", type: .int, storage: .slot(.int, "i_01"), min: 0)
            ]
        )
        #expect(throws: SchemaError.invalidValue(.belowMinimum(field: "count", minimum: 0))) {
            try definition.resolve(["count": .int(-1)], at: 2)
        }
    }

    @Test("allowed constrains every element of a string list")
    func allowedList() throws {
        let definition = makeDefinition(
            entity: "post",
            fields: [
                FieldDefinition(
                    name: "tags",
                    type: .stringList,
                    storage: .slot(.stringList, "ls_00"),
                    allowed: ["red", "green"]
                )
            ]
        )
        #expect(throws: SchemaError.invalidValue(.outsideDomain(field: "tags"))) {
            try definition.resolve(["tags": .strings(["red", "blue"])], at: 2)
        }
        let ok = try definition.resolve(["tags": .strings(["red", "green"])], at: 2)
        #expect(ok["tags"] == .strings(["red", "green"]))
    }

    @Test("Numeric bounds constrain every element of a number list")
    func boundedList() {
        let definition = makeDefinition(
            entity: "sample",
            fields: [
                FieldDefinition(name: "counts", type: .intList, storage: .slot(.intList, "li_00"), min: 0)
            ]
        )
        #expect(throws: SchemaError.invalidValue(.belowMinimum(field: "counts", minimum: 0))) {
            try definition.resolve(["counts": .ints([1, -1, 2])], at: 2)
        }
    }
}
