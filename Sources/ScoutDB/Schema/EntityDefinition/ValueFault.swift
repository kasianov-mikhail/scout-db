//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The constraint a written value broke.
enum ValueFault: Equatable, Sendable {
    case outsideDomain(field: String)
    case patternMismatch(field: String)
    case belowMinimum(field: String, minimum: Double)
    case aboveMaximum(field: String, maximum: Double)
}

extension ValueFault: CustomStringConvertible {
    var description: String {
        switch self {
        case .outsideDomain(let field):
            "Field '\(field)' takes a value outside its allowed domain"
        case .patternMismatch(let field):
            "Field '\(field)' takes a value its pattern rejects"
        case .belowMinimum(let field, let minimum):
            "Field '\(field)' takes a value below its minimum of \(minimum)"
        case .aboveMaximum(let field, let maximum):
            "Field '\(field)' takes a value above its maximum of \(maximum)"
        }
    }
}
