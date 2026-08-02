//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public enum FieldType: String, Codable, Equatable, CaseIterable, Sendable {
    case string
    case text
    case int
    case double
    case timestamp
    case bytes
    case reference

    case stringList
    case intList
    case doubleList
    case timestampList

    var slotPrefix: String {
        switch self {
        case .string:
            "s"
        case .text:
            "x"
        case .int:
            "i"
        case .double:
            "d"
        case .timestamp:
            "t"
        case .bytes:
            "b"
        case .reference:
            "r"
        case .stringList:
            "ls"
        case .intList:
            "li"
        case .doubleList:
            "ld"
        case .timestampList:
            "lt"
        }
    }

    var capacity: Int {
        16
    }

    var isSortable: Bool {
        switch self {
        case .string, .text, .int, .double, .timestamp:
            true
        default:
            false
        }
    }

    func slotIndex(_ slot: String) -> Int? {
        guard slot.hasPrefix("\(slotPrefix)_"), let index = Int(slot.dropFirst(slotPrefix.count + 1)), index >= 0 else {
            return nil
        }
        return index
    }

    static func type(forSlot slot: String) -> FieldType? {
        guard let separator = slot.firstIndex(of: "_") else {
            return nil
        }
        let prefix = String(slot[..<separator])
        return allCases.first { $0.slotPrefix == prefix }
    }

    var isList: Bool {
        switch self {
        case .stringList, .intList, .doubleList, .timestampList:
            true
        default:
            false
        }
    }

    var emptyList: RecordValue? {
        switch self {
        case .stringList:
            .strings([])
        case .intList:
            .ints([])
        case .doubleList:
            .doubles([])
        case .timestampList:
            .dates([])
        default:
            nil
        }
    }

    func matches(_ value: RecordValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.text, .string), (.int, .int), (.double, .double),
            (.timestamp, .date), (.bytes, .bytes), (.reference, .reference),
            (.stringList, .strings), (.intList, .ints), (.doubleList, .doubles), (.timestampList, .dates):
            true
        default:
            false
        }
    }
}
