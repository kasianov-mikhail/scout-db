//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func gridRecords(
        entity: String, view: String, group: String? = nil, from: Date? = nil, to: Date? = nil, counts: Range<Int>, values: Range<Int>? = nil
    ) async throws -> [CKRecord] {
        var filters = [
            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
            ServerFilter(field: "view", op: .equals, value: .string(view)),
        ]

        if let group {
            filters.append(ServerFilter(field: "group_key", op: .equals, value: .string(group)))
        }
        if let from {
            filters.append(ServerFilter(field: "date", op: .greaterThanOrEquals, value: .date(from)))
        }
        if let to {
            filters.append(ServerFilter(field: "date", op: .lessThan, value: .date(to)))
        }

        let declared = values?.filter { $0 % CKRecord.squareOffset < CKRecord.valueCellCount } ?? []
        let keys = ["date", "group_key"] + counts.map(CKRecord.countCell) + declared.map(CKRecord.valueCell)

        return try await database.allRecords(
            matching: CKQuery(recordType: GridSlot.recordType, filters: filters),
            desiredKeys: keys
        )
    }
}
