//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorIndex: Hashable {
    static let namespace = "__index"

    let entity: String
    let aggregate: String
    let week: Date?

    var recordID: CKRecord.ID {
        var components = [entity, aggregate]
        if let week {
            components.append(String(week.millisecondsSince1970))
        }
        return CKRecord.ID(recordName: "index-" + contentDigest(of: components))
    }
}

extension VectorIndex {
    struct Page: Codable, Equatable {
        let weeks: [Int64]
        let groups: [String]

        /// How many shards each week of this aggregate has grown to, keyed by
        /// the week's milliseconds, and kept on the head page alone.
        ///
        /// A count only ever rises, because a reader covers `0..<count` and a
        /// shard dropped out of that range takes the writes filed under it out
        /// of every later read. A week absent here has never been contended
        /// and is read at whatever the schema declares.
        ///
        let shards: [String: Int]

        enum CodingKeys: String, CodingKey {
            case weeks
            case groups
            case shards
        }

        init(weeks: [Int64], groups: [String], shards: [String: Int] = [:]) {
            self.weeks = weeks
            self.groups = groups
            self.shards = shards
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            weeks = try container.decode([Int64].self, forKey: .weeks)
            groups = try container.decode([String].self, forKey: .groups)
            shards = try container.decodeIfPresent([String: Int].self, forKey: .shards) ?? [:]
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(weeks, forKey: .weeks)
            try container.encode(groups, forKey: .groups)

            if !shards.isEmpty {
                try container.encode(shards, forKey: .shards)
            }
        }
    }

    static let pageKey = "b_00"
}

extension CKRecord {
    var indexPage: VectorIndex.Page? {
        get {
            guard let data = self[VectorIndex.pageKey] as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(VectorIndex.Page.self, from: data)
        }
        set {
            let encoded: Data? = newValue.flatMap { try? JSONEncoder().encode($0) }
            self[VectorIndex.pageKey] = encoded
        }
    }

    func indexPage(named id: CKRecord.ID) throws -> VectorIndex.Page {
        guard let page = indexPage else {
            throw SchemaError.malformedRecord(id.recordName)
        }
        return page
    }
}

extension VectorSlot {
    var index: (head: VectorIndex, week: VectorIndex) {
        (
            VectorIndex(entity: entity, aggregate: aggregate, week: nil),
            VectorIndex(entity: entity, aggregate: aggregate, week: week)
        )
    }
}
