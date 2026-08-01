//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

enum LocalQuery {
    /// What a scan has left to serve: the already-matched, already-ordered ids
    /// still to come, so a continuation never re-evaluates the query.
    private struct Scan: @unchecked Sendable {
        let query: CKQuery
        let remaining: [CKRecord.ID]
    }

    static func page(
        _ records: [CKRecord], matching query: CKQuery, resultsLimit: Int, pageLimit: Int? = nil
    ) -> QueryPage {
        let matched =
            records
            .filter {
                $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true
            }
            .sorted(by: query.sortDescriptors ?? [])

        let capacity = Swift.min(
            resultsLimit > 0 ? resultsLimit : Int.max,
            pageLimit ?? Int.max
        )

        let page = matched.prefix(capacity).map { $0.duplicate() }
        let end = page.count

        let cursor: QueryCursor? =
            end < matched.count
            ? .local(Scan(query: query, remaining: matched.dropFirst(end).map(\.recordID)))
            : nil

        return (page.map { ($0.recordID, .success($0)) }, cursor)
    }

    static func resume(
        _ records: [CKRecord], from cursor: QueryCursor, resultsLimit: Int, pageLimit: Int? = nil
    ) -> QueryPage? {
        guard case .local(let token) = cursor, let scan = token as? Scan else {
            return nil
        }

        let remaining = scan.remaining
        let capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
        let byID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })

        var served: [(CKRecord.ID, Result<CKRecord, any Error>)] = []
        var index = 0

        while index < remaining.count, served.count < capacity {
            if let record = byID[remaining[index]] {
                let copy = record.duplicate()
                served.append((copy.recordID, .success(copy)))
            }
            index += 1
        }

        let rest = remaining.dropFirst(index)
        let next: QueryCursor? = rest.isEmpty ? nil : .local(Scan(query: scan.query, remaining: Array(rest)))

        return (served, next)
    }
}

extension [CKRecord] {
    func sorted(by descriptors: [NSSortDescriptor]) -> [CKRecord] {
        guard descriptors.count > 0 else {
            return self
        }

        return sorted { lhs, rhs in
            for descriptor in descriptors {
                guard let key = descriptor.key else {
                    continue
                }

                let order = PredicateEvaluator.compare(lhs[key], rhs[key])

                guard order != .orderedSame else {
                    continue
                }
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return false
        }
    }
}
