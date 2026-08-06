//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting

@testable import ScoutDB

extension InMemoryDatabase {
    func vector(
        _ entity: String, _ aggregate: String, group: String = "", week: Date, shard: Int? = nil
    ) -> CKRecord? {
        let slot = VectorSlot<DoubleVector>(
            entity: entity,
            aggregate: aggregate,
            group: group,
            shard: shard,
            week: week
        )
        return records.first { $0.recordID == slot.recordID }
    }

    func shards(
        _ entity: String, _ aggregate: String, group: String = "", week: Date, over count: Int
    ) -> [CKRecord] {
        (0..<count).compactMap { vector(entity, aggregate, group: group, week: week, shard: $0) }
    }

    var vectors: [CKRecord] {
        records.filter { $0.recordType == DoubleVector.recordType }
    }
}
