//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// Continuation token for a paginated query.
///
/// `CKQueryOperation.Cursor` has no public initializer, so a protocol that
/// traffics in it directly forces every test double into single-page reads.
/// Real CloudKit pages carry the opaque cursor; a double mints `local`,
/// carrying whatever token continues its own scan. ScoutDB hands either one
/// back to the database that minted it and never reads inside.
///
public enum QueryCursor: @unchecked Sendable {
    case cloudKit(CKQueryOperation.Cursor)
    case local(any Sendable)
}

/// One page of a query: the matched records in order, and the cursor that
/// continues the read when more remain.
///
public typealias QueryPage = (
    matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
    queryCursor: QueryCursor?
)
