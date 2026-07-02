//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CoreLocation
import Foundation

@testable import ScoutDB

/// In-memory evaluation of a neutral ``RecordQuery`` against a ``Record`` —
/// the stub counterpart of a backend running the query for real. Mirrors the
/// `AND`-of-comparisons shape Scout builds; a record missing a filtered field
/// never matches, as a backend's comparison would skip it.
///
extension Record {
    func matches(_ query: RecordQuery) -> Bool {
        recordType == query.recordType.recordType && query.filters.allSatisfy(matches)
    }

    private func matches(_ filter: RecordQuery.Filter) -> Bool {
        guard let value = fields[filter.field] else { return false }

        switch filter.op {
        case .equals:
            return value == filter.value
        case .notEquals:
            return value != filter.value
        case .in:
            guard case .strings(let options) = filter.value, case .string(let actual) = value else { return false }
            return options.contains(actual)
        case .notIn:
            guard case .strings(let options) = filter.value, case .string(let actual) = value else { return false }
            return !options.contains(actual)
        case .beginsWith:
            guard case .string(let prefix) = filter.value, case .string(let actual) = value else { return false }
            return actual.hasPrefix(prefix)
        case .contains:
            switch (value, filter.value) {
            case (.strings(let list), .string(let element)): return list.contains(element)
            case (.ints(let list), .int(let element)): return list.contains(element)
            case (.doubles(let list), .double(let element)): return list.contains(element)
            case (.dates(let list), .date(let element)): return list.contains(element)
            default: return false
            }
        case .near:
            guard case .location(let lat, let lon) = value, case .location(let centerLat, let centerLon) = filter.value, let radius = filter.radius else {
                return false
            }
            let point = CLLocation(latitude: lat, longitude: lon)
            let center = CLLocation(latitude: centerLat, longitude: centerLon)
            return point.distance(from: center) < radius
        case .search:
            guard case .string(let text) = value, case .string(let needle) = filter.value else { return false }
            let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
            return tokens.contains(Substring(needle.lowercased()))
        case .greaterThan, .greaterThanOrEquals, .lessThan, .lessThanOrEquals:
            guard let lhs = value.comparable, let rhs = filter.value.comparable else { return false }
            switch filter.op {
            case .greaterThan: return lhs > rhs
            case .greaterThanOrEquals: return lhs >= rhs
            case .lessThan: return lhs < rhs
            case .lessThanOrEquals: return lhs <= rhs
            default: return false
            }
        }
    }
}

extension RecordValue {
    /// A scalar projection used to order values for range comparisons.
    fileprivate var comparable: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        case .date(let value): value.timeIntervalSince1970
        default: nil
        }
    }
}

extension [Record] {
    /// In-memory counterpart of a backend applying the query's sort descriptors.
    ///
    /// With no sort the insertion order is preserved, matching the stub's history.
    ///
    func sorted(by sorts: [RecordQuery.Sort]) -> [Record] {
        guard sorts.count > 0 else { return self }
        return sorted { lhs, rhs in
            for sort in sorts {
                let order = RecordValue.compare(lhs.fields[sort.field], rhs.fields[sort.field])
                guard order != .orderedSame else { continue }
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return false
        }
    }
}

extension RecordValue {
    fileprivate static func compare(_ lhs: RecordValue?, _ rhs: RecordValue?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case (.string(let lhs)?, .string(let rhs)?):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        default:
            guard let lhs = lhs?.comparable, let rhs = rhs?.comparable else { return .orderedSame }
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }
}
