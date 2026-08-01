//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// An element type whose arrays map onto one of the typed list kinds.
public protocol RecordListElement: RecordValue.Convertible {
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

extension Array: RecordValue.Convertible where Element: RecordListElement {
    public init?(recordValue: RecordValue) {
        guard let members = recordValue.members else {
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
