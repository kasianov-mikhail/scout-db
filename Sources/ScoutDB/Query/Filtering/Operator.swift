//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The comparison a filter asks of a field, on the server and on the client alike:
/// every case maps to a CloudKit predicate the store can also decide locally.
public enum Operator: CaseIterable, Sendable {
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
    case search
}

extension Operator {
    var formatString: String {
        switch self {
        case .equals:
            "%K == %@"
        case .notEquals:
            "%K != %@"
        case .greaterThan:
            "%K > %@"
        case .greaterThanOrEquals:
            "%K >= %@"
        case .lessThan:
            "%K < %@"
        case .lessThanOrEquals:
            "%K <= %@"
        case .in:
            "%K IN %@"
        case .notIn:
            "NOT (%K IN %@)"
        case .beginsWith:
            "%K BEGINSWITH %@"
        case .contains:
            "%K CONTAINS %@"
        case .search:
            "self contains %@"
        }
    }
}
