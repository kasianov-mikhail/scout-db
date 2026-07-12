//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import Foundation
import ScoutDB

/// In-memory execution of the NSPredicate trees the store builds — the stub
/// counterpart of the CloudKit server running the query for real.
///
/// A record missing a compared field never matches, mirroring the server; the
/// tri-state result lets `NOT (field IN ...)` stay false for missing fields too.
///
public enum PredicateEvaluator {
    public static func evaluate(_ predicate: NSPredicate, record: CKRecord) -> Bool? {
        if let compound = predicate as? NSCompoundPredicate {
            let results = (compound.subpredicates as? [NSPredicate] ?? []).map { evaluate($0, record: record) }
            switch compound.compoundPredicateType {
            case .and:
                return results.allSatisfy { $0 == true }
            case .or:
                return results.contains { $0 == true }
            case .not:
                return results.first.flatMap { $0.map { !$0 } } ?? false
            @unknown default:
                return false
            }
        }
        if let comparison = predicate as? NSComparisonPredicate {
            return evaluate(comparison, record: record)
        }
        return predicate == NSPredicate(value: true) ? true : false
    }

    private static func evaluate(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        if comparison.leftExpression.expressionType == .function {
            return evaluateDistance(comparison, record: record)
        }
        if comparison.leftExpression.expressionType == .evaluatedObject {
            return evaluateSearch(comparison, record: record)
        }
        guard comparison.leftExpression.expressionType == .keyPath else { return false }

        let key = comparison.leftExpression.keyPath
        let target = comparison.rightExpression.constantValue
        let value: Any? =
            switch key {
            case "modificationDate": record.recordModificationDate
            case "creatorUserRecordID": record.recordCreator
            default: record[key]
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
            guard let text = value as? String, let prefix = target as? String else { return false }
            return text.hasPrefix(prefix)
        case .in:
            guard let options = target as? [Any] else { return false }
            return options.contains { compare(value, $0) == .orderedSame }
        case .contains:
            guard let list = value as? [Any] else { return false }
            return list.contains { compare($0, target) == .orderedSame }
        default:
            return false
        }
    }

    private static func evaluateDistance(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        let arguments = comparison.leftExpression.arguments ?? []
        guard arguments.count == 2, arguments[0].expressionType == .keyPath else { return false }
        guard let point = record[arguments[0].keyPath] as? CLLocation else { return nil }
        guard let center = arguments[1].constantValue as? CLLocation else { return false }
        guard let radius = (comparison.rightExpression.constantValue as? NSNumber)?.doubleValue else { return false }
        return point.distance(from: center) < radius
    }

    // Token-based full-text match across every string field, the way the server
    // treats `self CONTAINS`: each needle token must appear somewhere on the record.
    private static func evaluateSearch(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        guard let needle = (comparison.rightExpression.constantValue as? String)?.lowercased() else { return false }
        var tokens: Set<Substring> = []
        for key in record.allKeys() {
            guard let text = record[key] as? String else { continue }
            tokens.formUnion(text.lowercased().split { !$0.isLetter && !$0.isNumber })
        }
        return needle.split { !$0.isLetter && !$0.isNumber }.allSatisfy(tokens.contains)
    }

    public static func compare(_ lhs: Any?, _ rhs: Any?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case (let lhs as String, let rhs as String):
            return order(lhs, rhs)
        case (let lhs as String, let rhs as CKRecord.Reference):
            // The creator's server value is a reference; the double stores the name.
            return order(lhs, rhs.recordID.recordName)
        case (let lhs as Date, let rhs as Date):
            return order(lhs, rhs)
        case (let lhs as Data, let rhs as Data):
            return lhs == rhs ? .orderedSame : .orderedDescending
        case (let lhs as NSNumber, let rhs as NSNumber):
            return lhs.compare(rhs)
        default:
            return .orderedDescending
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
