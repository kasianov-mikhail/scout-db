//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import Foundation

/// Server-shaped query execution against a local record set.
///
/// Filter, sort, page, project. The in-memory test double and the offline
/// cache both answer queries through it, so the two stay behaviorally
/// identical.
///
package enum LocalQuery {
    /// One page of matches from `offset`, mirroring the server's paging.
    ///
    /// At most `resultsLimit` records per response (`maximumResults`, i.e. 0,
    /// means "as many as fit under `pageLimit`") and a cursor whenever matches
    /// remain beyond the page.
    ///
    package static func page(
        _ records: [CKRecord], matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, offset: Int,
        resultsLimit: Int, pageLimit: Int? = nil
    ) -> (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?) {
        let matched =
            records
            .filter { $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true }
            .sorted(by: query.sortDescriptors ?? [])
        let capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
        let page = matched.dropFirst(offset).prefix(capacity).map { project($0, keys: desiredKeys) }
        let end = offset + page.count
        let cursor: QueryCursor? =
            end < matched.count ? .materialized(query: query, remaining: matched.dropFirst(end).map(\.recordID)) : nil
        return (page.map { ($0.recordID, .success($0)) }, cursor)
    }

    /// Serves the next page of a local scan, or nil for a CloudKit cursor.
    ///
    /// A `materialized` cursor is answered from its carried id order — no
    /// re-filtering and no re-sorting; an id whose record left the store is
    /// skipped, and an updated record is served in its current state. A legacy
    /// `offset` cursor re-evaluates the query the way the first page did.
    ///
    package static func resume(
        _ records: [CKRecord], from cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int, pageLimit: Int? = nil
    ) -> (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?)? {
        switch cursor {
        case .cloudKit:
            return nil
        case .offset(let query, let offset):
            return page(records, matching: query, desiredKeys: desiredKeys, offset: offset, resultsLimit: resultsLimit, pageLimit: pageLimit)
        case .materialized(let query, let remaining):
            let capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
            let byID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
            var served: [(CKRecord.ID, Result<CKRecord, any Error>)] = []
            var index = 0
            while index < remaining.count, served.count < capacity {
                if let record = byID[remaining[index]] {
                    let projected = project(record, keys: desiredKeys)
                    served.append((projected.recordID, .success(projected)))
                }
                index += 1
            }
            let rest = remaining.dropFirst(index)
            let cursor: QueryCursor? = rest.isEmpty ? nil : .materialized(query: query, remaining: Array(rest))
            return (served, cursor)
        }
    }

    /// A response copy of a stored record, trimmed to `keys` when given.
    ///
    /// The server returns a fresh record per fetch, so mutating a query
    /// result never silently edits the store. The envelope overrides live
    /// outside the record's own coding and are carried over by hand.
    ///
    package static func project(_ record: CKRecord, keys: [CKRecord.FieldKey]?) -> CKRecord {
        let projected: CKRecord
        if let keys {
            projected = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() where keys.contains(key) {
                projected[key] = record[key]
            }
        } else {
            projected = record.copy() as! CKRecord
        }
        if let tag = record.recordVersionTag {
            projected.overrideChangeTag(tag)
        }
        if let date = record.recordModificationDate {
            projected.overrideModificationDate(date)
        }
        if let creator = record.recordCreator {
            projected.overrideCreator(creator)
        }
        return projected
    }
}

extension [CKRecord] {
    package func sorted(by descriptors: [NSSortDescriptor]) -> [CKRecord] {
        guard descriptors.count > 0 else { return self }
        return sorted { lhs, rhs in
            for descriptor in descriptors {
                guard let key = descriptor.key else { continue }
                let order: ComparisonResult
                if let location = descriptor as? CKLocationSortDescriptor {
                    let near = (lhs[key] as? CLLocation)?.distance(from: location.relativeLocation) ?? .greatestFiniteMagnitude
                    let far = (rhs[key] as? CLLocation)?.distance(from: location.relativeLocation) ?? .greatestFiniteMagnitude
                    order = PredicateEvaluator.compare(near as NSNumber, far as NSNumber)
                } else {
                    order = PredicateEvaluator.compare(lhs[key], rhs[key])
                }
                guard order != .orderedSame else { continue }
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return false
        }
    }
}
