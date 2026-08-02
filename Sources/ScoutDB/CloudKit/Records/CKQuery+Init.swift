//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension CKQuery {
    struct Filter: Equatable, Sendable {
        let field: String
        let op: Operator
        let value: RecordValue

        fileprivate var predicate: NSPredicate {
            let value = value.predicateValue
            let arguments: [Any] = op == .search ? [value] : [field, value]
            return NSPredicate(format: op.formatString, argumentArray: arguments)
        }
    }

    struct Sort: Equatable, Sendable {
        let field: String
        let order: SortOrder
    }

    convenience init(recordType: String, filters: [Filter], sort: [Sort] = []) {
        self.init(
            recordType: recordType,
            predicate: filters.isEmpty
                ? NSPredicate(value: true)
                : NSCompoundPredicate(type: .and, subpredicates: filters.map(\.predicate))
        )
        if sort.count > 0 {
            sortDescriptors = sort.map { NSSortDescriptor(key: $0.field, ascending: $0.order == .forward) }
        }
    }
}
