//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct IndexPage: Codable, Equatable {
    static let key = "b_00"

    let weeks: [Int64]
    let groups: [String]
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

extension CKRecord {
    var indexPage: IndexPage? {
        get {
            guard let data = self[IndexPage.key] as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(IndexPage.self, from: data)
        }
        set {
            let encoded: Data? = newValue.flatMap { try? JSONEncoder().encode($0) }
            self[IndexPage.key] = encoded
        }
    }

    func indexPage(named id: CKRecord.ID) throws -> IndexPage {
        guard let page = indexPage else {
            throw SchemaError.malformedRecord(id.recordName)
        }
        return page
    }
}
