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

    // Mirrors the slot counts declared in the frozen Schema file. CloudKit caps a
    // record type at 256 fields total — the 6 system fields count too. Budget:
    // 6 system + 5 envelope + 240 slots (15 x 16) + 1 payload = 252, leaving 4 free.
    public var capacity: Int { 16 }

    // The `pool_NN` slot naming is a wire-format invariant: these two are the only
    // spelling of it — the allocator formats through `slotName`, the schema codecs
    // parse through `slotIndex`/`pool(forSlot:)`.
    func slotName(_ index: Int) -> String {
        "\(rawValue)_\(String(format: "%02d", index))"
    }

    /// The slot's index within this pool, or nil when the name is not of this pool.
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
