//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// Thrown when a write loses a compare-and-swap race; carries the winning record.
public struct RecordConflictError: LocalizedError {
    public let serverRecord: CKRecord

    public init(serverRecord: CKRecord) {
        self.serverRecord = serverRecord
    }

    /// The conflict behind a failed conditional save, whether the database
    /// reported it as this error or as CloudKit's own `serverRecordChanged`.
    ///
    /// Nil for anything else — a permission, quota or validation failure is
    /// not a lost race and must not be retried as one.
    ///
    public init?(_ error: any Error) {
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

    public let errorDescription: String? = "The record was changed on the server"
}
