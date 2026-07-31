//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public protocol RecordValueConvertible {
    init?(recordValue: RecordValue)

    var recordValue: RecordValue { get }
}

extension String: RecordValueConvertible {
    public init?(recordValue: RecordValue) {
        guard case .string(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .string(self) }
}

extension Int: RecordValueConvertible {
    public init?(recordValue: RecordValue) {
        guard case .int(let value) = recordValue else {
            return nil
        }
        self = Int(value)
    }

    public var recordValue: RecordValue { .int(Int64(self)) }
}

extension Int64: RecordValueConvertible {
    public init?(recordValue: RecordValue) {
        guard case .int(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .int(self) }
}

extension Double: RecordValueConvertible {
    public init?(recordValue: RecordValue) {
        guard case .double(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .double(self) }
}

extension Date: RecordValueConvertible {
    public init?(recordValue: RecordValue) {
        guard case .date(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .date(self) }
}

extension Data: RecordValueConvertible {
    public init?(recordValue: RecordValue) {
        guard case .bytes(let value) = recordValue else {
            return nil
        }
        self = value
    }

    public var recordValue: RecordValue { .bytes(self) }
}

/// An element type whose arrays map onto one of the typed list kinds.
public protocol RecordListElement: RecordValueConvertible {
    static func list(_ elements: [Self]) -> RecordValue
}

extension String: RecordListElement {
    public static func list(_ elements: [String]) -> RecordValue { .strings(elements) }
}

extension Int64: RecordListElement {
    public static func list(_ elements: [Int64]) -> RecordValue { .ints(elements) }
}

extension Int: RecordListElement {
    public static func list(_ elements: [Int]) -> RecordValue { .ints(elements.map(Int64.init)) }
}

extension Double: RecordListElement {
    public static func list(_ elements: [Double]) -> RecordValue { .doubles(elements) }
}

extension Date: RecordListElement {
    public static func list(_ elements: [Date]) -> RecordValue { .dates(elements) }
}

extension RecordValue {
    var listMembers: [RecordValue]? {
        switch self {
        case .strings(let members):
            members.map { .string($0) }
        case .ints(let members):
            members.map { .int($0) }
        case .doubles(let members):
            members.map { .double($0) }
        case .dates(let members):
            members.map { .date($0) }
        default:
            nil
        }
    }
}

extension Array: RecordValueConvertible where Element: RecordListElement {
    public init?(recordValue: RecordValue) {
        guard let members = recordValue.listMembers else {
            return nil
        }
        var elements: [Element] = []
        for member in members {
            guard let element = Element(recordValue: member) else {
                return nil
            }
            elements.append(element)
        }
        self = elements
    }

    public var recordValue: RecordValue { Element.list(self) }
}
