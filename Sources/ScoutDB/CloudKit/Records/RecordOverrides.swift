//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import ObjectiveC

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

    package func duplicate() -> CKRecord {
        let copy = self.copy() as! CKRecord
        copy.overrides = overrides
        return copy
    }
}
