//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

package enum PredicateEvaluator {
    package static func evaluate(predicate: NSPredicate, record: CKRecord) -> Bool? {
        if let compound = predicate as? NSCompoundPredicate {
            let subpredicates = compound.subpredicates as? [NSPredicate] ?? []

            switch compound.compoundPredicateType {
            case .and:
                return combine(subpredicates: subpredicates, record: record, decisive: false)

            case .or:
                return combine(subpredicates: subpredicates, record: record, decisive: true)

            case .not:
                guard let subpredicate = subpredicates.first,
                    let result = evaluate(predicate: subpredicate, record: record)
                else {
                    return nil
                }
                return !result

            @unknown default:
                return nil
            }
        }

        if let comparison = predicate as? NSComparisonPredicate {
            return evaluate(comparison: comparison, record: record)
        }
        if predicate == NSPredicate(value: true) {
            return true
        }
        if predicate == NSPredicate(value: false) {
            return false
        }

        return nil
    }

    private static func combine(subpredicates: [NSPredicate], record: CKRecord, decisive: Bool) -> Bool? {
        var sawUnknown = false
        for subpredicate in subpredicates {
            guard let result = evaluate(predicate: subpredicate, record: record) else {
                sawUnknown = true
                continue
            }
            if result == decisive {
                return decisive
            }
        }
        return sawUnknown ? nil : !decisive
    }

    private static func evaluate(comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        if comparison.leftExpression.expressionType == .evaluatedObject {
            return evaluateSearch(comparison: comparison, record: record)
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
            default:
                record[key]
            }

        guard let value else { return nil }

        switch comparison.predicateOperatorType {
        case .equalTo:
            return compare(lhs: value, rhs: target) == .orderedSame
        case .notEqualTo:
            return compare(lhs: value, rhs: target) != .orderedSame
        case .greaterThan:
            return compare(lhs: value, rhs: target) == .orderedDescending
        case .greaterThanOrEqualTo:
            return compare(lhs: value, rhs: target) != .orderedAscending
        case .lessThan:
            return compare(lhs: value, rhs: target) == .orderedAscending
        case .lessThanOrEqualTo:
            return compare(lhs: value, rhs: target) != .orderedDescending

        case .beginsWith:
            guard let text = value as? String, let prefix = target as? String else {
                return nil
            }
            return text.hasPrefix(prefix)

        case .in:
            guard let options = target as? [Any] else {
                return nil
            }
            return options.contains { compare(lhs: value, rhs: $0) == .orderedSame }

        case .contains:
            if let list = value as? [Any] {
                return list.contains { compare(lhs: $0, rhs: target) == .orderedSame }
            }
            guard let text = value as? String, let needle = target as? String else {
                return nil
            }
            return text.contains(needle)

        default:
            return nil
        }
    }

    private static func evaluateSearch(comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
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

    package static func compare(lhs: Any?, rhs: Any?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case (let lhs as String, let rhs as String):
            return order(lhs: lhs, rhs: rhs)
        case (let lhs as NSNumber, let rhs as NSNumber):
            return lhs.compare(rhs)
        case (let lhs as Date, let rhs as Date):
            return order(lhs: lhs, rhs: rhs)
        case (let lhs as Data, let rhs as Data):
            return order(lhs: lhs, rhs: rhs)
        case (let lhs as [Any], let rhs as [Any]):
            return order(lhs: lhs, rhs: rhs)

        default:
            if let lhs = recordName(value: lhs), let rhs = recordName(value: rhs) {
                return order(lhs: lhs, rhs: rhs)
            }
            return order(lhs: rank(value: lhs), rhs: rank(value: rhs))
        }
    }

    private static func recordName(value: Any?) -> String? {
        switch value {
        case let value as CKRecord.Reference:
            value.recordID.recordName
        case let value as String:
            value
        default:
            nil
        }
    }

    private static func rank(value: Any?) -> Int {
        switch value {
        case is NSNumber:
            0
        case is String:
            1
        case is Date:
            2
        case is Data:
            3
        case is CKRecord.Reference:
            4
        case is [Any]:
            5
        default:
            6
        }
    }

    private static func order(lhs: Data, rhs: Data) -> ComparisonResult {
        guard let mismatch = zip(lhs, rhs).first(where: { $0 != $1 }) else {
            return order(lhs: lhs.count, rhs: rhs.count)
        }
        return order(lhs: mismatch.0, rhs: mismatch.1)
    }

    private static func order(lhs: [Any], rhs: [Any]) -> ComparisonResult {
        for (lhs, rhs) in zip(lhs, rhs) {
            let element = compare(lhs: lhs, rhs: rhs)

            guard element == .orderedSame else {
                return element
            }
        }
        return order(lhs: lhs.count, rhs: rhs.count)
    }

    private static func order<T: Comparable>(lhs: T, rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
