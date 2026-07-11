//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

public struct QueryPlan: Equatable, Sendable, CustomStringConvertible {
    public let server: [String]
    public let client: [String]
    public let sort: [String]

    public var description: String {
        let lines = server.map { "SERVER \($0)" } + client.map { "CLIENT \($0)" } + sort.map { "SORT \($0)" }
        return lines.joined(separator: "\n")
    }
}

// The structured form of a server-side predicate, turned into an NSPredicate at
// the single point the store talks to CloudKit.
struct ServerFilter: Equatable, Sendable {
    enum Operator: String, Sendable {
        case equals
        case notEquals
        case greaterThan
        case greaterThanOrEquals
        case lessThan
        case lessThanOrEquals
        case `in`
        case notIn
        case beginsWith
        case contains
        case near
        case search
    }

    let field: String
    let op: Operator
    let value: RecordValue
    var radius: Double?

    var predicate: NSPredicate {
        let value = value.predicateValue
        return switch op {
        case .equals: NSPredicate(format: "%K == %@", field, value)
        case .notEquals: NSPredicate(format: "%K != %@", field, value)
        case .greaterThan: NSPredicate(format: "%K > %@", field, value)
        case .greaterThanOrEquals: NSPredicate(format: "%K >= %@", field, value)
        case .lessThan: NSPredicate(format: "%K < %@", field, value)
        case .lessThanOrEquals: NSPredicate(format: "%K <= %@", field, value)
        case .in: NSPredicate(format: "%K IN %@", field, value)
        case .notIn: NSPredicate(format: "NOT (%K IN %@)", field, value)
        case .beginsWith: NSPredicate(format: "%K BEGINSWITH %@", field, value)
        case .contains: NSPredicate(format: "%K CONTAINS %@", field, value)
        case .near: NSPredicate(format: "distanceToLocation:fromLocation:(%K, %@) < %f", field, value, radius ?? 0)
        case .search: NSPredicate(format: "self contains %@", value)
        }
    }
}

struct ServerSort: Equatable, Sendable {
    let field: String
    let ascending: Bool
}

func ckQuery(_ recordType: String, filters: [ServerFilter], sort: [ServerSort] = []) -> CKQuery {
    let predicate: NSPredicate =
        filters.isEmpty
        ? NSPredicate(value: true)
        : NSCompoundPredicate(type: .and, subpredicates: filters.map(\.predicate))
    let query = CKQuery(recordType: recordType, predicate: predicate)
    if sort.count > 0 {
        query.sortDescriptors = sort.map { NSSortDescriptor(key: $0.field, ascending: $0.ascending) }
    }
    return query
}
