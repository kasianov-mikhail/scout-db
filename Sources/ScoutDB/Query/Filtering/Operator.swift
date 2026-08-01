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

    var complement: Operator? {
        switch self {
        case .equals:
            .notEquals
        case .notEquals:
            .equals
        case .in:
            .notIn
        case .notIn:
            .in
        case .greaterThan:
            .lessThanOrEquals
        case .greaterThanOrEquals:
            .lessThan
        case .lessThan:
            .greaterThanOrEquals
        case .lessThanOrEquals:
            .greaterThan
        default:
            nil
        }
    }
}
