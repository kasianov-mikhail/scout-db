//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue {
    var canonical: String {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            "i\(value)"
        case .double(let value):
            "d\(value)"
        case .date(let value):
            "t\(value.millisecondsSince1970)"
        case .bytes(let value):
            "b\(value.base64EncodedString())"
        case .strings(let value):
            value.joined(separator: ",")
        case .ints(let value):
            "i[\(value.map { "\($0)" }.joined(separator: ","))]"
        case .doubles(let value):
            "d[\(value.map { "\($0)" }.joined(separator: ","))]"
        case .dates(let value):
            "t[\(value.map { String($0.millisecondsSince1970) }.joined(separator: ","))]"
        case .reference(let value):
            "r\(value)"
        }
    }

    var integer: Int64? {
        guard case .int(let value) = self else {
            return nil
        }
        return value
    }

    var scalar: Double? {
        switch self {
        case .int(let value):
            Double(value)
        case .double(let value):
            value
        default:
            nil
        }
    }

    var members: [RecordValue]? {
        switch self {
        case .strings(let values):
            values.map(RecordValue.string)
        case .ints(let values):
            values.map(RecordValue.int)
        case .doubles(let values):
            values.map(RecordValue.double)
        case .dates(let values):
            values.map(RecordValue.date)
        default:
            nil
        }
    }

    var isEmptyList: Bool {
        switch self {
        case .strings(let value):
            value.isEmpty
        case .ints(let value):
            value.isEmpty
        case .doubles(let value):
            value.isEmpty
        case .dates(let value):
            value.isEmpty
        default:
            false
        }
    }

    var strings: [String] {
        switch self {
        case .string(let value):
            [value]
        case .strings(let value):
            value
        default:
            []
        }
    }

    var scalars: [Double] {
        switch self {
        case .int(let value):
            [Double(value)]
        case .double(let value):
            [value]
        case .ints(let value):
            value.map(Double.init)
        case .doubles(let value):
            value
        default:
            []
        }
    }
}
