//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

package struct RecordConflictError: LocalizedError {
    package let serverRecord: CKRecord

    package init(serverRecord: CKRecord) {
        self.serverRecord = serverRecord
    }

    package init?(_ error: any Error) {
        if let conflict = error as? RecordConflictError {
            self = conflict
            return
        }
        guard let error = error as? CKError, error.code == .serverRecordChanged else {
            return nil
        }
        guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
            return nil
        }
        self.init(serverRecord: server)
    }

    package let errorDescription: String? = "The record was changed on the server"
}
