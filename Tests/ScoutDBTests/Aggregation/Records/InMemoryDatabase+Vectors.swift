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
    func vector<Holder: Vector>(
        of holder: Holder.Type, _ entity: String, _ aggregate: String, group: String = "", week: Date,
        shard: Int? = nil
    ) -> CKRecord? {
        let slot = VectorSlot<Holder>(
            entity: entity,
            aggregate: aggregate,
            group: group,
            shard: shard,
            week: week
        )
        return records.first { $0.recordID == slot.recordID }
    }

    func shards<Holder: Vector>(
        of holder: Holder.Type, _ entity: String, _ aggregate: String, group: String = "", week: Date, over count: Int
    ) -> [CKRecord] {
        (0..<count).compactMap { vector(of: holder, entity, aggregate, group: group, week: week, shard: $0) }
    }

    var vectors: [CKRecord] {
        records.filter { [IntVector.recordType, DoubleVector.recordType].contains($0.recordType) }
    }

    var integers: [CKRecord] {
        records.filter { $0.recordType == IntVector.recordType }
    }

    var doubles: [CKRecord] {
        records.filter { $0.recordType == DoubleVector.recordType }
    }
}
