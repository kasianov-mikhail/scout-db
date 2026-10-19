//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CKRecord.Reference {
    convenience init(uuid: String) {
        self.init(recordID: CKRecord.ID(recordName: uuid), action: .none)
    }
}
