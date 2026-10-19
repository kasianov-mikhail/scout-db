//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

struct LocalQuery {
    private struct Scan: @unchecked Sendable {
        let query: CKQuery
        let remaining: [CKRecord.ID]
    }

    let records: [CKRecord]
    let desiredKeys: [String]?
    private let capacity: Int

    init(records: [CKRecord], desiredKeys: [String]?, resultsLimit: Int, pageLimit: Int?) {
        self.records = records
        self.desiredKeys = desiredKeys
        self.capacity = Swift.min(resultsLimit > 0 ? resultsLimit : Int.max, pageLimit ?? Int.max)
    }

    func page(query: CKQuery) -> QueryPage {
        let matched =
            records
            .filter {
                $0.recordType == query.recordType && PredicateEvaluator.evaluate(query.predicate, record: $0) == true
            }
            .sorted(by: query.sortDescriptors ?? [])

        let page = matched.prefix(capacity).map { $0.duplicate(keeping: desiredKeys) }
        let end = page.count

        let cursor: QueryCursor? =
            end < matched.count
            ? .local(Scan(query: query, remaining: matched.dropFirst(end).map(\.recordID)))
            : nil

        return (page.map { ($0.recordID, .success($0)) }, cursor)
    }

    func resume(cursor: QueryCursor) -> QueryPage? {
        guard case .local(let token) = cursor, let scan = token as? Scan else {
            return nil
        }

        let remaining = scan.remaining
        let byID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })

        var served: [(CKRecord.ID, Result<CKRecord, any Error>)] = []
        var index = 0

        while index < remaining.count, served.count < capacity {
            if let record = byID[remaining[index]] {
                let copy = record.duplicate(keeping: desiredKeys)
                served.append((copy.recordID, .success(copy)))
            }
            index += 1
        }

        let rest = remaining.dropFirst(index)
        let next: QueryCursor? = rest.isEmpty ? nil : .local(Scan(query: scan.query, remaining: Array(rest)))

        return (served, next)
    }
}

extension CKRecord {
    fileprivate func duplicate(keeping keys: [String]?) -> CKRecord {
        let copy = duplicate()
        guard let keys else {
            return copy
        }
        for key in copy.allKeys() where !keys.contains(key) {
            copy[key] = nil
        }
        return copy
    }
}

extension [CKRecord] {
    func sorted(by descriptors: [NSSortDescriptor]) -> [CKRecord] {
        guard !descriptors.isEmpty else { return self }
        return sorted(using: descriptors.compactMap(ColumnOrder.init))
    }
}

private struct ColumnOrder: SortComparator {
    let key: String
    var order: SortOrder

    init?(_ descriptor: NSSortDescriptor) {
        guard let key = descriptor.key else {
            return nil
        }
        self.key = key
        self.order = descriptor.ascending ? .forward : .reverse
    }

    func compare(_ lhs: CKRecord, _ rhs: CKRecord) -> ComparisonResult {
        switch order {
        case .forward:
            PredicateEvaluator.compare(lhs[key], rhs[key])
        case .reverse:
            PredicateEvaluator.compare(rhs[key], lhs[key])
        }
    }
}
