//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import ObjectiveC

/// The record metadata a `CloudDatabase` double stamps for itself.
///
/// CloudKit assigns a change tag and a modification date on the server, and
/// `CKRecord` exposes both read-only. A double has no server to assign them, so
/// it stores its own here and the library reads them where it would read
/// CloudKit's. Nothing in ScoutDB writes them — the double does, through the
/// accessors `ScoutDBTesting` puts on top of this.
///
package struct RecordOverrides: Sendable {
    package var modificationDate: Date?
    package var changeTag: String?
}

private nonisolated(unsafe) var overridesKey: UInt8 = 0

extension CKRecord {
    package var overrides: RecordOverrides {
        get { objc_getAssociatedObject(self, &overridesKey) as? RecordOverrides ?? RecordOverrides() }
        set { objc_setAssociatedObject(self, &overridesKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// A copy that keeps the overrides `copy()` leaves behind.
    package func duplicate() -> CKRecord {
        let copy = self.copy() as! CKRecord
        copy.overrides = overrides
        return copy
    }
}
