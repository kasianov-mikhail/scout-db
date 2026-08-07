//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorSlot: Hashable {
    static let recordType = "Vector"

    static let cellKeys: [String] = (0..<Date.hoursPerWeek).map { String(format: "c_%03d", $0) }

    let entity: String
    let aggregate: String
    let group: String
    let shard: Int?
    let week: Date

    private var components: [String] {
        var components = [entity, aggregate, group, String(week.millisecondsSince1970)]
        if let shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        return components
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "vector-" + contentDigest(of: components))
    }

    var index: (head: VectorIndex, week: VectorIndex) {
        (
            VectorIndex(entity: entity, aggregate: aggregate, week: nil),
            VectorIndex(entity: entity, aggregate: aggregate, week: week)
        )
    }
}

extension VectorSlot {
    init?(for entityRecord: EntityRecord, aggregate: AggregateDefinition, week: Date, shards: Int?) {
        let group: String

        if let histogram = aggregate.measure?.histogram {
            guard let value = entityRecord.values[histogram.field]?.scalar else {
                return nil
            }
            group = histogram.groupKey(of: value)
        } else {
            group = aggregate.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""
        }

        self.init(
            entity: entityRecord.entity,
            aggregate: aggregate.name,
            group: group,
            shard: shards.map { count in
                Int(entityRecord.uuid.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } % UInt64(count))
            },
            week: week
        )
    }
}
