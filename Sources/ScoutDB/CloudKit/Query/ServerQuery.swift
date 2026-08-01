//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct ServerFilter: Equatable, Sendable {
    let field: String
    let op: Operator
    let value: RecordValue

    var predicate: NSPredicate {
        let value = value.predicateValue
        return switch op {
        case .equals:
            NSPredicate(format: "%K == %@", field, value)
        case .notEquals:
            NSPredicate(format: "%K != %@", field, value)
        case .greaterThan:
            NSPredicate(format: "%K > %@", field, value)
        case .greaterThanOrEquals:
            NSPredicate(format: "%K >= %@", field, value)
        case .lessThan:
            NSPredicate(format: "%K < %@", field, value)
        case .lessThanOrEquals:
            NSPredicate(format: "%K <= %@", field, value)
        case .in:
            NSPredicate(format: "%K IN %@", field, value)
        case .notIn:
            NSPredicate(format: "NOT (%K IN %@)", field, value)
        case .beginsWith:
            NSPredicate(format: "%K BEGINSWITH %@", field, value)
        case .contains:
            NSPredicate(format: "%K CONTAINS %@", field, value)
        case .search:
            NSPredicate(format: "self contains %@", value)
        }
    }
}

struct ServerSort: Equatable, Sendable {
    let field: String
    let ascending: Bool
}

extension CKQuery {
    convenience init(recordType: String, filters: [ServerFilter], sort: [ServerSort] = []) {
        self.init(
            recordType: recordType,
            predicate: filters.isEmpty
                ? NSPredicate(value: true)
                : NSCompoundPredicate(type: .and, subpredicates: filters.map(\.predicate))
        )
        if sort.count > 0 {
            sortDescriptors = sort.map { NSSortDescriptor(key: $0.field, ascending: $0.ascending) }
        }
    }
}
