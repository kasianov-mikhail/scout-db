//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import Foundation

package enum PredicateEvaluator {
    package static func evaluate(_ predicate: NSPredicate, record: CKRecord) -> Bool? {
        if let compound = predicate as? NSCompoundPredicate {
            let subpredicates = compound.subpredicates as? [NSPredicate] ?? []

            switch compound.compoundPredicateType {
            case .and:
                var sawUnknown = false
                for subpredicate in subpredicates {
                    switch evaluate(subpredicate, record: record) {
                    case .some(false):
                        return false
                    case .none:
                        sawUnknown = true
                    case .some(true):
                        break
                    }
                }
                return sawUnknown ? nil : true

            case .or:
                var sawUnknown = false
                for subpredicate in subpredicates {
                    switch evaluate(subpredicate, record: record) {
                    case .some(true):
                        return true
                    case .none:
                        sawUnknown = true
                    case .some(false):
                        break
                    }
                }
                return sawUnknown ? nil : false

            case .not:
                return subpredicates.first.flatMap { evaluate($0, record: record).map { !$0 } }

            @unknown default:
                return nil
            }
        }

        if let comparison = predicate as? NSComparisonPredicate {
            return evaluate(comparison, record: record)
        }
        if predicate == NSPredicate(value: true) {
            return true
        }
        if predicate == NSPredicate(value: false) {
            return false
        }

        return nil
    }

    private static func evaluate(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        if comparison.leftExpression.expressionType == .evaluatedObject {
            return evaluateSearch(comparison, record: record)
        }

        guard comparison.leftExpression.expressionType == .keyPath else {
            return nil
        }
        guard comparison.rightExpression.expressionType == .constantValue else {
            return nil
        }

        let key = comparison.leftExpression.keyPath
        let target = comparison.rightExpression.constantValue

        let value: Any? =
            switch key {
            case "modificationDate":
                record.recordModificationDate
            case "creatorUserRecordID":
                record.recordCreator
            default:
                record[key]
            }

        guard let value else { return nil }

        switch comparison.predicateOperatorType {
        case .equalTo:
            return compare(value, target) == .orderedSame
        case .notEqualTo:
            return compare(value, target) != .orderedSame
        case .greaterThan:
            return compare(value, target) == .orderedDescending
        case .greaterThanOrEqualTo:
            return compare(value, target) != .orderedAscending
        case .lessThan:
            return compare(value, target) == .orderedAscending
        case .lessThanOrEqualTo:
            return compare(value, target) != .orderedDescending

        case .beginsWith:
            guard let text = value as? String, let prefix = target as? String else {
                return nil
            }
            return text.hasPrefix(prefix)

        case .in:
            guard let options = target as? [Any] else {
                return nil
            }
            return options.contains { compare(value, $0) == .orderedSame }

        case .contains:
            if let list = value as? [Any] {
                return list.contains { compare($0, target) == .orderedSame }
            }
            guard let text = value as? String, let needle = target as? String else {
                return nil
            }
            return text.contains(needle)

        default:
            return nil
        }
    }

    private static func evaluateSearch(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        guard comparison.rightExpression.expressionType == .constantValue else {
            return nil
        }
        guard let needle = (comparison.rightExpression.constantValue as? String)?.lowercased() else {
            return nil
        }

        var required = Set(needle.split { !$0.isLetter && !$0.isNumber })

        guard !required.isEmpty else {
            return true
        }

        for key in record.allKeys() {
            guard let text = record[key] as? String else {
                continue
            }

            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                required.remove(token)
                if required.isEmpty {
                    return true
                }
            }
        }

        return false
    }

    package static func compare(_ lhs: Any?, _ rhs: Any?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case (let lhs as String, let rhs as String):
            return order(lhs, rhs)
        case (let lhs as NSNumber, let rhs as NSNumber):
            return lhs.compare(rhs)
        case (let lhs as Date, let rhs as Date):
            return order(lhs, rhs)
        case (let lhs as Data, let rhs as Data):
            return order(lhs, rhs)
        case (let lhs as CLLocation, let rhs as CLLocation):
            return order(lhs, rhs)
        case (let lhs as [Any], let rhs as [Any]):
            return order(lhs, rhs)

        default:
            if let lhs = recordName(of: lhs), let rhs = recordName(of: rhs) {
                return order(lhs, rhs)
            }
            return order(rank(of: lhs), rank(of: rhs))
        }
    }

    private static func recordName(of value: Any?) -> String? {
        switch value {
        case let value as CKRecord.Reference:
            value.recordID.recordName
        case let value as String:
            value
        default:
            nil
        }
    }

    private static func rank(of value: Any?) -> Int {
        switch value {
        case is NSNumber:
            0
        case is String:
            1
        case is Date:
            2
        case is Data:
            3
        case is CLLocation:
            4
        case is CKRecord.Reference:
            5
        case is [Any]:
            6
        default:
            7
        }
    }

    private static func order(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        guard let mismatch = zip(lhs, rhs).first(where: { $0 != $1 }) else {
            return order(lhs.count, rhs.count)
        }
        return order(mismatch.0, mismatch.1)
    }

    private static func order(_ lhs: CLLocation, _ rhs: CLLocation) -> ComparisonResult {
        let latitude = order(lhs.coordinate.latitude, rhs.coordinate.latitude)
        return latitude == .orderedSame ? order(lhs.coordinate.longitude, rhs.coordinate.longitude) : latitude
    }

    private static func order(_ lhs: [Any], _ rhs: [Any]) -> ComparisonResult {
        for (lhs, rhs) in zip(lhs, rhs) {
            let element = compare(lhs, rhs)

            guard element == .orderedSame else {
                return element
            }
        }
        return order(lhs.count, rhs.count)
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
