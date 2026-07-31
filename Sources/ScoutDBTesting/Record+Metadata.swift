//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

extension CKRecord {
    /// The date the record was last written, or the one the double stamped.
    public var recordModificationDate: Date? {
        overrides.modificationDate ?? modificationDate
    }

    /// The tag a conditional save compares against, or the one the double
    /// stamped.
    public var recordVersionTag: String? {
        overrides.changeTag ?? recordChangeTag
    }

    /// Stamps the modification date a query on `modificationDate` reads.
    public func overrideModificationDate(_ date: Date) {
        overrides.modificationDate = date
    }

    /// Stamps the version a conditional save compares against, standing in for
    /// the tag the server bumps on every write.
    public func overrideChangeTag(_ tag: String) {
        overrides.changeTag = tag
    }
}
