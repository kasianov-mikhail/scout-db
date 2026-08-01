//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension RecordValue {
    public protocol Convertible {
        init?(recordValue: RecordValue)

        var recordValue: RecordValue { get }
    }
}

extension String: RecordValue.Convertible {
    public init?(recordValue: RecordValue) {
        guard case .string(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .string(self) }
}

extension Int: RecordValue.Convertible {
    public init?(recordValue: RecordValue) {
        guard case .int(let value) = recordValue else {
            return nil
        }
        self = Int(value)
    }

    public var recordValue: RecordValue { .int(Int64(self)) }
}

extension Int64: RecordValue.Convertible {
    public init?(recordValue: RecordValue) {
        guard case .int(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .int(self) }
}

extension Double: RecordValue.Convertible {
    public init?(recordValue: RecordValue) {
        guard case .double(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .double(self) }
}

extension Date: RecordValue.Convertible {
    public init?(recordValue: RecordValue) {
        guard case .date(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .date(self) }
}

extension Data: RecordValue.Convertible {
    public init?(recordValue: RecordValue) {
        guard case .bytes(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .bytes(self) }
}
