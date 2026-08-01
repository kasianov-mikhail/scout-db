//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDBTesting

struct PerfScenario: Sendable {
    let feature: String
    let name: String
    let sql: Int
    let writes: Bool
    let iterations: Int?
    let setUp: (@Sendable (PerfWorld) async throws -> Void)?
    let body: @Sendable (PerfWorld, Int) async throws -> Void

    init(
        _ feature: String, _ name: String, sql: Int, writes: Bool = true, iterations: Int? = nil,
        setUp: (@Sendable (PerfWorld) async throws -> Void)? = nil, body: @escaping @Sendable (PerfWorld, Int) async throws -> Void
    ) {
        self.feature = feature
        self.name = name
        self.sql = sql
        self.writes = writes
        self.iterations = iterations
        self.setUp = setUp
        self.body = body
    }

    func repeats(on size: DatasetSize) -> Int {
        iterations ?? size.iterations
    }
}

struct PerfResult: Sendable {
    let feature: String
    let scenario: String
    let size: DatasetSize
    let iterations: Int
    let sql: Int
    let requests: RequestTally
    let failure: String?

    var perOperation: Double {
        iterations > 0 ? Double(requests.total) / Double(iterations) : 0
    }

    var overhead: Double? {
        sql > 0 ? perOperation / Double(sql) : nil
    }
}
