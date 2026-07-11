//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public enum FieldType: String, Codable, Equatable, Sendable {
    case string, text, int, double, timestamp, bytes, location, reference, asset
    case stringList, intList, doubleList, timestampList, locationList, assetList

    var pool: Pool {
        switch self {
        case .string: .string
        case .text: .text
        case .int: .int
        case .double: .double
        case .timestamp: .timestamp
        case .bytes: .bytes
        case .location: .location
        case .reference: .reference
        case .asset: .asset
        case .stringList: .stringList
        case .intList: .intList
        case .doubleList: .doubleList
        case .timestampList: .timestampList
        case .locationList: .locationList
        case .assetList: .assetList
        }
    }

    var isList: Bool {
        switch self {
        case .stringList, .intList, .doubleList, .timestampList, .locationList, .assetList: true
        default: false
        }
    }

    var emptyList: RecordValue? {
        switch self {
        case .stringList: .strings([])
        case .intList: .ints([])
        case .doubleList: .doubles([])
        case .timestampList: .dates([])
        case .locationList: .locations([])
        case .assetList: .assets([])
        default: nil
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
