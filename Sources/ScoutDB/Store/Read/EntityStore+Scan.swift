//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    func boundedRecords(
        matching query: CKQuery, limit: Int, using definition: EntityDefinition,
        where included: (EntityRecord) -> Bool
    ) async throws -> [EntityRecord] {
        let coder = EntityCoder()
        var collected: [EntityRecord] = []
        var page = Self.cappedPage(limit == Int.max ? limit : limit + 1)
        var (batch, token) = try await database.records(matching: query, resultsLimit: page)
        while true {
            collected += try batch.map { try coder.decode($0.1.get(), using: definition) }.filter(included)
            guard collected.count < limit, let cursor = token else {
                break
            }
            page = page < Int.max / 2 ? Self.cappedPage(page * 2) : page
            (batch, token) = try await database.records(
                continuingMatchFrom: cursor,
                resultsLimit: page
            )
        }
        return collected
    }

    private static func cappedPage(_ rows: Int) -> Int {
        let maximum = CKQueryOperation.maximumResults
        return maximum > 0 ? Swift.min(rows, maximum) : rows
    }
}
