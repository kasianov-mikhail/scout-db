//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct GeoPoint: Equatable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum RecordValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case date(Date)
    case bytes(Data)
    case location(latitude: Double, longitude: Double)
    case reference(String)
    case asset(URL)
    case strings([String])
    case ints([Int64])
    case doubles([Double])
    case dates([Date])
    case locations([GeoPoint])
    case assets([URL])
}

extension RecordValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case string, int, double, date, bytes, location, reference, asset
        case strings, ints, doubles, dates, locations, assets
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
        } else if let value = try container.decodeIfPresent([GeoPoint].self, forKey: .locations) {
            self = .locations(value)
        } else if let value = try container.decodeIfPresent([URL].self, forKey: .assets) {
            self = .assets(value)
        } else if let value = try container.decodeIfPresent([Double].self, forKey: .location), value.count == 2 {
            self = .location(latitude: value[0], longitude: value[1])
        } else if let value = try container.decodeIfPresent(String.self, forKey: .reference) {
            self = .reference(value)
        } else if let value = try container.decodeIfPresent(URL.self, forKey: .asset) {
            self = .asset(value)
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
        case .locations(let value):
            try container.encode(value, forKey: .locations)
        case .assets(let value):
            try container.encode(value, forKey: .assets)
        case .location(let latitude, let longitude):
            try container.encode([latitude, longitude], forKey: .location)
        case .reference(let value):
            try container.encode(value, forKey: .reference)
        case .asset(let value):
            try container.encode(value, forKey: .asset)
        }
    }
}

extension RecordValue {
    init?(any value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .bytes(value)
        case let value as [String]:
            self = .strings(value)
        case let value as NSNumber where CFNumberIsFloatType(value):
            self = .double(value.doubleValue)
        case let value as NSNumber:
            self = .int(value.int64Value)
        default:
            return nil
        }
    }
}
