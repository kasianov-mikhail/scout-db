//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    public enum Match: Equatable, Sendable {
        case equals, notEquals
        case greaterThan, greaterThanOrEquals, lessThan, lessThanOrEquals
        case `in`, notIn, beginsWith, contains, search
        case isNull, isNotNull

        var serverOperator: ServerFilter.Operator? {
            switch self {
            case .equals:
                .equals
            case .notEquals:
                .notEquals
            case .greaterThan:
                .greaterThan
            case .greaterThanOrEquals:
                .greaterThanOrEquals
            case .lessThan:
                .lessThan
            case .lessThanOrEquals:
                .lessThanOrEquals
            case .in:
                .in
            case .notIn:
                .notIn
            case .beginsWith:
                .beginsWith
            case .contains:
                .contains
            case .search:
                .search
            case .isNull, .isNotNull:
                nil
            }
        }

        var complement: Match? {
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
}
