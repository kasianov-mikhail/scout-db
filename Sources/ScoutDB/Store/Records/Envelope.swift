//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The slots the store keeps for itself, ahead of the ones a field may take.
///
/// A record carries no column of its own: what a caller declares and what the
/// library stamps live in the same pools, so the entity a record belongs to is
/// a string slot like any other, and the server filters and sorts it the same
/// way.
///
enum Envelope {
    static let entity = "s_00"
    static let uuid = "s_01"
    static let version = "i_00"
}

extension FieldType {
    /// The slots of this pool the envelope claims, held back from the fields
    /// a declaration allocates.
    var reserved: Int {
        switch self {
        case .string:
            2
        case .int:
            1
        default:
            0
        }
    }
}
