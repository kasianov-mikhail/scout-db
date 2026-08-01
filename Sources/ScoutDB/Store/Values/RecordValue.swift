//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A value as a record carries it, one case per `FieldType`.
///
/// Reading and writing usually goes through `EntityRecord`'s typed subscript,
/// which converts to and from the Swift types; match on the cases only when
/// the field's type is not known ahead of time.
///
public enum RecordValue: Hashable, Sendable {
    /// Text, behind both the `string` and the `text` field types.
    case string(String)

    /// A whole number, always widened to 64 bits.
    case int(Int64)

    /// A floating-point number.
    case double(Double)

    /// A point in time, kept to the millisecond.
    case date(Date)

    /// An opaque blob, stored inline with the record.
    case bytes(Data)

    /// The uuid of another record, stored as a CloudKit reference.
    case reference(String)

    /// A list of strings.
    case strings([String])

    /// A list of whole numbers.
    case ints([Int64])

    /// A list of floating-point numbers.
    case doubles([Double])

    /// A list of points in time.
    case dates([Date])
}

extension RecordValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case string, int, double, date, bytes, reference
        case strings, ints, doubles, dates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let value = try container.decodeIfPresent(String.self, forKey: .string) {
            self = .string(value)
        } else if let value = try container.decodeIfPresent(Int64.self, forKey: .int) {
            self = .int(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .double) {
            self = .double(value)
        } else if let value = try container.decodeIfPresent(Int64.self, forKey: .date) {
            self = .date(Date(millisecondsSince1970: value))
        } else if let value = try container.decodeIfPresent(Data.self, forKey: .bytes) {
            self = .bytes(value)
        } else if let value = try container.decodeIfPresent([String].self, forKey: .strings) {
            self = .strings(value)
        } else if let value = try container.decodeIfPresent([Int64].self, forKey: .ints) {
            self = .ints(value)
        } else if let value = try container.decodeIfPresent([Double].self, forKey: .doubles) {
            self = .doubles(value)
        } else if let value = try container.decodeIfPresent([Int64].self, forKey: .dates) {
            self = .dates(value.map(Date.init(millisecondsSince1970:)))
        } else if let value = try container.decodeIfPresent(String.self, forKey: .reference) {
            self = .reference(value)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown field value type"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .string(let value):
            try container.encode(value, forKey: .string)
        case .int(let value):
            try container.encode(value, forKey: .int)
        case .double(let value):
            try container.encode(value, forKey: .double)
        case .date(let value):
            try container.encode(value.millisecondsSince1970, forKey: .date)
        case .bytes(let value):
            try container.encode(value, forKey: .bytes)
        case .strings(let value):
            try container.encode(value, forKey: .strings)
        case .ints(let value):
            try container.encode(value, forKey: .ints)
        case .doubles(let value):
            try container.encode(value, forKey: .doubles)
        case .dates(let value):
            try container.encode(value.map(\.millisecondsSince1970), forKey: .dates)
        case .reference(let value):
            try container.encode(value, forKey: .reference)
        }
    }
}
