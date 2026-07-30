//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import Foundation

package enum LocalQuery {
    package static func page(
        _ records: [CKRecord], matching query: CKQuery, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int, pageLimit: Int? = nil
    ) -> (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?) {
        let matched =
            records
            .filter { $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true }
            .sorted(by: query.sortDescriptors ?? [])
        let capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
        let page = matched.prefix(capacity).map { project($0, keys: desiredKeys) }
        let end = page.count
        let cursor: QueryCursor? =
            end < matched.count ? .materialized(query: query, remaining: matched.dropFirst(end).map(\.recordID)) : nil
        return (page.map { ($0.recordID, .success($0)) }, cursor)
    }

    package static func resume(
        _ records: [CKRecord], from cursor: QueryCursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int, pageLimit: Int? = nil
    ) -> (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: QueryCursor?)? {
        switch cursor {
        case .cloudKit:
            return nil
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

    package static func project(_ record: CKRecord, keys: [CKRecord.FieldKey]?) -> CKRecord {
        guard let keys else {
            return record.duplicate()
        }
        let projected = CKRecord(recordType: record.recordType, recordID: record.recordID)
        for key in record.allKeys() where keys.contains(key) {
            projected[key] = record[key]
        }
        record.carryOverrides(to: projected)
        return projected
    }
}

extension [CKRecord] {
    package func sorted(by descriptors: [NSSortDescriptor]) -> [CKRecord] {
        guard descriptors.count > 0 else {
            return self
        }
        return sorted { lhs, rhs in
            for descriptor in descriptors {
                guard let key = descriptor.key else {
                    continue
                }
                let order: ComparisonResult
                if let location = descriptor as? CKLocationSortDescriptor {
                    let near = (lhs[key] as? CLLocation)?.distance(from: location.relativeLocation) ?? .greatestFiniteMagnitude
                    let far = (rhs[key] as? CLLocation)?.distance(from: location.relativeLocation) ?? .greatestFiniteMagnitude
                    order = PredicateEvaluator.compare(near as NSNumber, far as NSNumber)
                } else {
                    order = PredicateEvaluator.compare(lhs[key], rhs[key])
                }
                guard order != .orderedSame else {
                    continue
                }
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return false
        }
    }
}
