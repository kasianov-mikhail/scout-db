//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public enum Pool: String, Codable, CaseIterable, Sendable {
    case string = "s"
    case text = "x"
    case int = "i"
    case double = "d"
    case timestamp = "t"
    case bytes = "b"
    case location = "g"
    case reference = "r"
    case asset = "a"
    case stringList = "ls"
    case intList = "li"
    case doubleList = "ld"
    case timestampList = "lt"
    case locationList = "lg"
    case assetList = "la"

    public var capacity: Int { 16 }

    var isQueryable: Bool {
        switch self {
        case .asset, .assetList: false
        default: true
        }
    }

    var isSortable: Bool {
        switch self {
        case .string, .text, .int, .double, .timestamp: true
        default: false
        }
    }

    func slotName(_ index: Int) -> String {
        "\(rawValue)_\(String(format: "%02d", index))"
    }

    func slotIndex(_ slot: String) -> Int? {
        guard slot.hasPrefix("\(rawValue)_"), let index = Int(slot.dropFirst(rawValue.count + 1)), index >= 0 else { return nil }
        return index
    }

    static func pool(forSlot slot: String) -> Pool? {
        guard let separator = slot.firstIndex(of: "_") else { return nil }
        return Pool(rawValue: String(slot[..<separator]))
    }
}

enum Entity {
    static let recordType = "Entity"
}
