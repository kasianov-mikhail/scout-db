//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// A seam shaped exactly like the CKDatabase calls the store makes — not a
/// backend abstraction. `CKDatabase` conforms by forwarding; tests inject an
/// in-memory implementation (see the `ScoutDBTesting` product) that evaluates
/// the same `CKQuery`.
///
/// Hand it the container's public database. That is the only scope ScoutDB
/// supports: the shipped `Schema`, its grants, and the default zone every
/// query and fetch names all describe the public one.
///
public protocol CloudDatabase: Sendable {
    /// The first page of records matching `query`, and the cursor that
    /// continues the read when more remain.
    ///
    /// Every page carries whole records. `resultsLimit` caps the page, but the
    /// server may return fewer and still hand back a cursor, so a short page
    /// means a page, never the end.
    ///
    /// A record type the schema has not published yet reads as an empty page
    /// rather than an error, and a query only matches on fields CloudKit has
    /// indexed as queryable. The index trails the write: a record saved a
    /// moment ago can be missing here while ``fetchRecord(id:)`` already
    /// returns it.
    ///
    /// Per-record failures ride inside the page — each match carries a
    /// `Result`, and one unreadable record leaves the rest of the page intact.
    ///
    func records(matching query: CKQuery, resultsLimit: Int) async throws -> QueryPage

    /// The next page of the query the cursor came from.
    ///
    /// The cursor stands in for the whole query, so this call repeats neither
    /// the predicate nor the sort — only `resultsLimit`, worth passing exactly
    /// as the first page did. A cursor belongs to the database that minted it:
    /// handing `CKDatabase` a `local` one, or a double a `cloudKit` one, throws
    /// `CKError.invalidArguments`.
    ///
    func records(continuingMatchFrom cursor: QueryCursor, resultsLimit: Int) async throws -> QueryPage

    /// Saves and deletes in one atomic request: either every change lands or
    /// none of them does.
    ///
    /// Last writer wins here — the saves overwrite whatever the server holds
    /// without consulting change tags. That is what a write derived from
    /// authoritative state wants, and what a merge-and-retry loop must not
    /// reach for; ``saveIfUnchanged(_:)`` is the call that notices a lost
    /// race. CloudKit bounds how much a single request may carry, so long
    /// lists are chunked before they get here.
    ///
    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws

    /// Conditionally saves a batch, reporting each record on its own: one
    /// result per input record, in the order given.
    ///
    /// Unlike ``modifyRecords(saving:deleting:)`` this request is not atomic.
    /// The records that won their race are stored while the rest come back as
    /// failures, which is the point when a batch is a set of independent
    /// compare-and-swaps rather than one indivisible change.
    ///
    /// A lost race arrives either as ``RecordConflictError`` or as CloudKit's
    /// own `serverRecordChanged`; ``RecordConflictError/init(_:)`` reads both
    /// and returns nil for the failures — permission, quota, validation — that
    /// must not be retried as conflicts.
    ///
    func saveIfUnchanged(_ records: [CKRecord]) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)]

    /// The record stored under that ID, or nil when nothing is.
    ///
    /// A fetch by ID reads past the query index, so it sees a write a query
    /// would still miss. Absence is an answer rather than an error: a deleted
    /// or never-written ID gives nil, and only a genuine failure — no account,
    /// no permission, no network — throws.
    ///
    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord?

    /// The records for those IDs, in the order asked, with the missing ones
    /// left out — so the result can be shorter than `ids`.
    ///
    /// A requirement only so a conformance that fetches a batch in one request
    /// can supply its own; the default implementation walks the IDs a fetch at
    /// a time.
    ///
    func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord]
}
