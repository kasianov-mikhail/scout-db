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
    let part: Int
    let week: Date

    private var components: [String] {
        var components = [entity, aggregate, group, String(week.millisecondsSince1970)]
        if let shard, shard > 0 {
            components.append("shard-\(shard)")
        }
        return components
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "vector-" + contentDigest(components: components))
    }

    var headIndex: VectorIndex {
        VectorIndex(entity: entity, aggregate: aggregate)
    }

    var weekIndex: VectorIndex {
        VectorIndex(entity: entity, aggregate: aggregate, week: week, part: part)
    }
}

extension VectorSlot {
    init?(entityRecord: EntityRecord, aggregate: AggregateDefinition, week: Date, shards: Int?) {
        let group: String

        if let histogram = aggregate.measure?.histogram {
            guard let value = entityRecord.values[histogram.field]?.scalar else {
                return nil
            }
            group = histogram.groupKey(value: value)
        } else {
            group = aggregate.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""
        }

        self.init(
            entity: entityRecord.entity,
            aggregate: aggregate.name,
            group: group,
            shard: shards.map(entityRecord.uuid.bucket),
            part: group.bucket(count: aggregate.partCount),
            week: week
        )
    }
}

extension [VectorSlot] {
    var indexPages: [VectorIndex: IndexPage] {
        var weeks: [VectorIndex: Set<Int64>] = [:]
        var groups: [VectorIndex: Set<String>] = [:]

        for slot in self {
            weeks[slot.headIndex, default: []].insert(slot.week.millisecondsSince1970)
            groups[slot.weekIndex, default: []].insert(slot.group)
        }

        var pages = weeks.mapValues { IndexPage(weeks: $0.sorted(), groups: []) }
        pages.merge(groups.mapValues { IndexPage(weeks: [], groups: $0.sorted()) }) { first, _ in first }

        return pages
    }
}

extension String {
    func bucket(count: Int) -> Int {
        guard count > 1 else {
            return 0
        }
        return Int(utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } % UInt64(count))
    }
}
