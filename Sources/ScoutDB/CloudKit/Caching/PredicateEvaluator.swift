//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import Foundation

/// In-memory execution of the NSPredicate trees the store builds — the stub
/// counterpart of the CloudKit server running the query for real.
///
/// A record missing a compared field never matches, mirroring the server; the
/// tri-state result lets `NOT (field IN ...)` stay false for missing fields too.
/// A predicate shape this evaluator cannot express is unknown rather than false,
/// so a caller that must not guess can route the query to the server instead —
/// see `supports(_:)`.
///
public enum PredicateEvaluator {
    private nonisolated(unsafe) static let truePredicate = NSPredicate(value: true)
    private nonisolated(unsafe) static let falsePredicate = NSPredicate(value: false)

    public static func evaluate(_ predicate: NSPredicate, record: CKRecord) -> Bool? {
        if let compound = predicate as? NSCompoundPredicate {
            let subpredicates = compound.subpredicates as? [NSPredicate] ?? []
            switch compound.compoundPredicateType {
            case .and:
                var sawUnknown = false
                for subpredicate in subpredicates {
                    switch evaluate(subpredicate, record: record) {
                    case .some(false): return false
                    case .none: sawUnknown = true
                    case .some(true): break
                    }
                }
                return sawUnknown ? nil : true
            case .or:
                var sawUnknown = false
                for subpredicate in subpredicates {
                    switch evaluate(subpredicate, record: record) {
                    case .some(true): return true
                    case .none: sawUnknown = true
                    case .some(false): break
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
        if predicate == Self.truePredicate { return true }
        if predicate == Self.falsePredicate { return false }
        return nil
    }

    /// Whether every node of `predicate` is one this evaluator can express.
    ///
    /// `evaluate(_:record:)` answers nil both for a field a record happens to
    /// lack and for a shape it cannot read, and a caller serving a query from a
    /// local mirror has to tell those apart: the first is a legitimate
    /// non-match, the second means the mirror cannot answer at all.
    ///
    package static func supports(_ predicate: NSPredicate) -> Bool {
        if let compound = predicate as? NSCompoundPredicate {
            guard let subpredicates = compound.subpredicates as? [NSPredicate] else { return false }
            switch compound.compoundPredicateType {
            case .and, .or:
                return subpredicates.allSatisfy(supports)
            case .not:
                return subpredicates.count == 1 && supports(subpredicates[0])
            @unknown default:
                return false
            }
        }
        if let comparison = predicate as? NSComparisonPredicate {
            switch comparison.leftExpression.expressionType {
            case .function:
                let arguments = comparison.leftExpression.arguments ?? []
                guard comparison.leftExpression.function == "distanceToLocation:fromLocation:" else { return false }
                guard arguments.count == 2, arguments[0].expressionType == .keyPath else { return false }
                guard arguments[1].expressionType == .constantValue, comparison.rightExpression.expressionType == .constantValue else { return false }
                guard arguments[1].constantValue is CLLocation, comparison.rightExpression.constantValue is NSNumber else { return false }
                return comparison.predicateOperatorType == .lessThan
            case .evaluatedObject:
                guard comparison.rightExpression.expressionType == .constantValue else { return false }
                return comparison.predicateOperatorType == .contains && comparison.rightExpression.constantValue is String
            case .keyPath:
                guard comparison.rightExpression.expressionType == .constantValue else { return false }
                switch comparison.predicateOperatorType {
                case .equalTo, .notEqualTo, .greaterThan, .greaterThanOrEqualTo, .lessThan, .lessThanOrEqualTo, .beginsWith, .contains:
                    return true
                case .in:
                    return comparison.rightExpression.constantValue is [Any]
                default:
                    return false
                }
            default:
                return false
            }
        }
        return predicate == Self.truePredicate || predicate == Self.falsePredicate
    }

    private static func evaluate(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        if comparison.leftExpression.expressionType == .function {
            return evaluateDistance(comparison, record: record)
        }
        if comparison.leftExpression.expressionType == .evaluatedObject {
            return evaluateSearch(comparison, record: record)
        }
        guard comparison.leftExpression.expressionType == .keyPath else { return nil }
        guard comparison.rightExpression.expressionType == .constantValue else { return nil }

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
            guard let text = value as? String, let prefix = target as? String else { return nil }
            return text.hasPrefix(prefix)
        case .in:
            guard let options = target as? [Any] else { return nil }
            return options.contains { compare(value, $0) == .orderedSame }
        case .contains:
            if let list = value as? [Any] {
                return list.contains { compare($0, target) == .orderedSame }
            }
            guard let text = value as? String, let needle = target as? String else { return nil }
            return text.contains(needle)
        default:
            return nil
        }
    }

    private static func evaluateDistance(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        let arguments = comparison.leftExpression.arguments ?? []
        guard arguments.count == 2, arguments[0].expressionType == .keyPath else { return nil }
        guard arguments[1].expressionType == .constantValue, comparison.rightExpression.expressionType == .constantValue else { return nil }
        guard let center = arguments[1].constantValue as? CLLocation else { return nil }
        guard let radius = (comparison.rightExpression.constantValue as? NSNumber)?.doubleValue else { return nil }
        guard let point = record[arguments[0].keyPath] as? CLLocation else { return nil }
        return point.distance(from: center) < radius
    }

    private static func evaluateSearch(_ comparison: NSComparisonPredicate, record: CKRecord) -> Bool? {
        guard comparison.rightExpression.expressionType == .constantValue else { return nil }
        guard let needle = (comparison.rightExpression.constantValue as? String)?.lowercased() else { return nil }
        var required = Set(needle.split { !$0.isLetter && !$0.isNumber })
        guard !required.isEmpty else { return true }
        for key in record.allKeys() {
            guard let text = record[key] as? String else { continue }
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                required.remove(token)
                if required.isEmpty { return true }
            }
        }
        return false
    }

    /// Orders two CloudKit field values the way a server-side query would.
    ///
    /// Every type a `CKRecord` can hold is ordered, including the reference,
    /// location, asset and list types a filter reaches through a slot; a
    /// reference and a bare record name compare as the same value, since the
    /// store spells a relation either way. Values of unlike types order by
    /// type and never compare equal, so the result stays a strict weak
    /// ordering — `sorted(by:)` relies on that.
    ///
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
            if let lhs = assetPath(of: lhs), let rhs = assetPath(of: rhs) {
                return order(lhs, rhs)
            }
            return order(rank(of: lhs), rank(of: rhs))
        }
    }

    private static func recordName(of value: Any?) -> String? {
        switch value {
        case let value as CKRecord.Reference: value.recordID.recordName
        case let value as String: value
        default: nil
        }
    }

    private static func assetPath(of value: Any?) -> String? {
        switch value {
        case let value as CKAsset: value.fileURL?.absoluteString
        case let value as URL: value.absoluteString
        default: nil
        }
    }

    private static func rank(of value: Any?) -> Int {
        switch value {
        case is NSNumber: 0
        case is String: 1
        case is Date: 2
        case is Data: 3
        case is CLLocation: 4
        case is CKRecord.Reference: 5
        case is CKAsset: 6
        case is URL: 7
        case is [Any]: 8
        default: 9
        }
    }

    private static func order(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        guard let mismatch = zip(lhs, rhs).first(where: { $0 != $1 }) else { return order(lhs.count, rhs.count) }
        return order(mismatch.0, mismatch.1)
    }

    private static func order(_ lhs: CLLocation, _ rhs: CLLocation) -> ComparisonResult {
        let latitude = order(lhs.coordinate.latitude, rhs.coordinate.latitude)
        return latitude == .orderedSame ? order(lhs.coordinate.longitude, rhs.coordinate.longitude) : latitude
    }

    private static func order(_ lhs: [Any], _ rhs: [Any]) -> ComparisonResult {
        for (lhs, rhs) in zip(lhs, rhs) {
            let element = compare(lhs, rhs)
            guard element == .orderedSame else { return element }
        }
        return order(lhs.count, rhs.count)
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
