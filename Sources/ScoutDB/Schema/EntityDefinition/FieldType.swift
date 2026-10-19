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
    case asset

    case stringList
    case intList
    case doubleList
    case timestampList
    case referenceList
    case bytesList

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
        case .asset:
            "a"
        case .stringList:
            "ls"
        case .intList:
            "li"
        case .doubleList:
            "ld"
        case .timestampList:
            "lt"
        case .referenceList:
            "lr"
        case .bytesList:
            "lb"
        }
    }

    var capacity: Int {
        switch self {
        case .string, .int, .double, .timestamp:
            32
        case .text, .bytes, .reference:
            16
        case .asset:
            4
        default:
            8
        }
    }

    var isSortable: Bool {
        switch self {
        case .string, .text, .int, .double, .timestamp:
            true
        default:
            false
        }
    }

    func slot(index: Int) -> String {
        String(slotPrefix: slotPrefix, index: index)
    }

    func slotIndex(slot: String) -> Int? {
        slot.slotIndex(prefix: slotPrefix)
    }

    var isList: Bool {
        switch self {
        case .stringList, .intList, .doubleList, .timestampList, .referenceList, .bytesList:
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
        case .referenceList:
            .references([])
        case .bytesList:
            .blobs([])
        default:
            nil
        }
    }

    func matches(value: RecordValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.text, .string), (.int, .int), (.double, .double),
            (.timestamp, .date), (.bytes, .bytes), (.reference, .reference), (.asset, .asset),
            (.stringList, .strings), (.intList, .ints), (.doubleList, .doubles), (.timestampList, .dates),
            (.referenceList, .references), (.bytesList, .blobs):
            true
        default:
            false
        }
    }
}
