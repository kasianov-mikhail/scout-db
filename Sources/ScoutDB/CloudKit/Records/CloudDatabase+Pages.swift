//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CloudDatabase {
    func pages(plan: ScanPlan, body: ([CKRecord]) async throws -> Void) async throws {
        var page = try await records(
            matching: plan.query,
            desiredKeys: plan.desiredKeys,
            resultsLimit: CKQueryOperation.maximumResults
        )

        while true {
            try await body(try page.matchResults.map { try $0.1.get() })
            guard let token = page.queryCursor else {
                return
            }
            page = try await records(
                continuingMatchFrom: token,
                desiredKeys: plan.desiredKeys,
                resultsLimit: CKQueryOperation.maximumResults
            )
        }
    }
}
