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

    /// The slots this pool declares in the record type.
    ///
    /// CloudKit caps a record type at 256 fields, and the pools split that
    /// ceiling in tiers: thirty-two apiece for the four types a schema leans
    /// on, sixteen for the remaining scalars and the payload, eight for the
    /// lists, and four for each of the location and asset pools no field type
    /// claims yet.
    ///
    var capacity: Int {
        switch self {
        case .string, .int, .double, .timestamp:
            32
        case .text, .bytes, .reference:
            16
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

    func slotIndex(_ slot: String) -> Int? {
        guard slot.hasPrefix("\(slotPrefix)_"), let index = Int(slot.dropFirst(slotPrefix.count + 1)), index >= 0 else {
            return nil
        }
        return index
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

    func matches(_ value: RecordValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.text, .string), (.int, .int), (.double, .double),
            (.timestamp, .date), (.bytes, .bytes), (.reference, .reference),
            (.stringList, .strings), (.intList, .ints), (.doubleList, .doubles), (.timestampList, .dates),
            (.referenceList, .references), (.bytesList, .blobs):
            true
        default:
            false
        }
    }
}
