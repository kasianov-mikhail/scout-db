//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

let requestTimeout: Duration = .seconds(30)

extension CKDatabase {
    @discardableResult func throttled<R>(body: @Sendable @escaping (CKDatabase) async throws -> R) async throws -> R {
        try await withRequestTimeout(requestTimeout) {
            try await withRateLimitRetry {
                try await self.configuredWith(configuration: .scoutDB, body: body)
            }
        }
    }
}

extension CKOperation.Configuration {
    static var scoutDB: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }
}
