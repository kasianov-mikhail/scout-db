//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func gridRecords(entity: String, view: String, group: String?, values: Bool = false, squares: Bool = false) async throws -> [CKRecord] {
        var filters = [
            ServerFilter(field: "entity", op: .equals, value: .string(entity)),
            ServerFilter(field: "view", op: .equals, value: .string(view)),
        ]

        if let group {
            filters.append(ServerFilter(field: "group_key", op: .equals, value: .string(group)))
        }

        var keys = ["group_key", CKRecord.countCell]

        if values {
            keys.append(CKRecord.valueCell)
        }
        if squares {
            keys.append(CKRecord.squareCell)
        }

        return try await database.allRecords(
            matching: CKQuery(recordType: GridSlot.recordType, filters: filters),
            desiredKeys: keys
        )
    }
}
