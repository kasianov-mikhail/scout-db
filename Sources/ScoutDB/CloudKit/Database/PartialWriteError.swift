//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// A batch write that failed for some of its records, unwrapped per record.
///
/// CloudKit rolls back an atomic batch when any record fails and marks the
/// innocent rest with `batchRequestFailed` — the raw `partialFailure` buries
/// the actual cause in `userInfo`. This error keeps only the failures that
/// caused the rollback, keyed by record.
///
public struct PartialWriteError: LocalizedError {
    public let reasons: [CKRecord.ID: any Error]

    init?(_ error: CKError) {
        guard error.code == .partialFailure, let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: any Error] else {
            return nil
        }

        let causes = partial.filter { ($0.value as? CKError)?.code != .batchRequestFailed }

        guard causes.count > 0 else {
            return nil
        }
        reasons = causes
    }

    public var errorDescription: String? {
        "\(reasons.count) record(s) failed the batch write"
    }
}
