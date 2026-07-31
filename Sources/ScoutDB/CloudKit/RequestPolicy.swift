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
        try await withRateLimitRetry {
            await RequestGate.shared.enter()
            do {
                let value = try await withRequestTimeout(requestTimeout) {
                    try await self.configuredWith(configuration: .scoutDB, body: body)
                }
                await RequestGate.shared.leave()
                return value
            } catch {
                await RequestGate.shared.leave()
                throw error
            }
        }
    }
}

extension CKOperation.Configuration {
    fileprivate static var scoutDB: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }
}
