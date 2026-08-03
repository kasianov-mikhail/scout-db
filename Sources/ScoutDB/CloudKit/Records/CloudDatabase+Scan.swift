//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CloudDatabase {
    func scan(matching plan: ScanPlan, limit: Int, using definition: EntityDefinition) async throws -> [EntityRecord] {
        let ceiling = CKQueryOperation.maximumResults > 0 ? CKQueryOperation.maximumResults : Int.max
        let decoder = EntityDecoder(definition: definition)

        var collected: [EntityRecord] = []
        var page = min(limit == Int.max ? limit : limit + 1, ceiling)
        var (batch, token) = try await records(matching: plan.query, resultsLimit: page)

        while true {
            collected += try batch.map { try decoder.decode($0.1.get()) }.filter(plan.includes)

            guard collected.count < limit, let cursor = token else {
                break
            }

            page = page < Int.max / 2 ? min(page * 2, ceiling) : page

            (batch, token) = try await records(
                continuingMatchFrom: cursor,
                resultsLimit: page
            )
        }

        return collected
    }
}
