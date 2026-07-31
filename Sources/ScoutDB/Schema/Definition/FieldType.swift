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
    case location
    case reference
    case asset

    case stringList
    case intList
    case doubleList
    case timestampList
    case locationList
    case assetList

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
        case .location:
            "g"
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
        case .locationList:
            "lg"
        case .assetList:
            "la"
        }
    }

    var capacity: Int { 16 }

    var isQueryable: Bool {
        switch self {
        case .asset, .assetList:
            false
        default:
            true
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

    func slotName(_ index: Int) -> String {
        "\(slotPrefix)_\(String(format: "%02d", index))"
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
        case .stringList, .intList, .doubleList, .timestampList, .locationList, .assetList:
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
        case .locationList:
            .locations([])
        case .assetList:
            .assets([])
        default:
            nil
        }
    }

    var canonicalParser: ((String) -> RecordValue?)? {
        switch self {
        case .string, .text:
            { .string($0) }
        case .int:
            { $0.hasPrefix("i") ? Int64($0.dropFirst()).map(RecordValue.int) : nil }
        case .double:
            { $0.hasPrefix("d") ? Double($0.dropFirst()).map(RecordValue.double) : nil }
        case .timestamp:
            { canonical in
                guard canonical.hasPrefix("t"), let milliseconds = Int64(canonical.dropFirst()) else {
                    return nil
                }
                return .date(Date(millisecondsSince1970: milliseconds))
            }
        case .reference:
            { $0.hasPrefix("r") ? .reference(String($0.dropFirst())) : nil }
        default:
            nil
        }
    }

    func matches(_ value: RecordValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.text, .string), (.int, .int), (.double, .double),
            (.timestamp, .date), (.bytes, .bytes), (.location, .location), (.reference, .reference), (.asset, .asset),
            (.stringList, .strings), (.intList, .ints), (.doubleList, .doubles), (.timestampList, .dates),
            (.locationList, .locations), (.assetList, .assets):
            true
        default:
            false
        }
    }
}
