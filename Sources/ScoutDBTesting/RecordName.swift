//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension CKRecord.ID {
    /// Whether CloudKit would take a record under this name.
    ///
    /// The server answers a name outside its alphabet with `invalidArguments`
    /// and the message `invalid id string`, and it keeps names opening with an
    /// underscore for its own records. A double that stores whatever it is
    /// handed passes a suite that the server would refuse, so it holds the same
    /// names back.
    ///
    /// An empty name and one past 255 characters are refused by `CKRecord.ID`
    /// itself, so what is left to check is the alphabet and the underscore.
    ///
    public var isLegalRecordName: Bool {
        guard !recordName.hasPrefix("_") else {
            return false
        }
        return recordName.allSatisfy { character in
            guard character.isASCII else {
                return false
            }
            return character.isLetter || character.isNumber || character == "-" || character == "_"
                || character == "."
        }
    }
}
