//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CloudDatabase {
    func allRecords(matching query: CKQuery) async throws -> [CKRecord] {
        var collected: [CKRecord] = []
        try await forEachPage(matching: query) {
            collected += $0
        }
        return collected
    }

    func forEachPage(matching query: CKQuery, _ body: ([CKRecord]) async throws -> Void) async throws {
        var (results, cursor) = try await records(
            matching: query,
            resultsLimit: CKQueryOperation.maximumResults
        )

        while true {
            try await body(try results.map { try $0.1.get() })
            guard let token = cursor else {
                return
            }
            let page = try await records(
                continuingMatchFrom: token,
                resultsLimit: CKQueryOperation.maximumResults
            )
            results = page.matchResults
            cursor = page.queryCursor
        }
    }
}
