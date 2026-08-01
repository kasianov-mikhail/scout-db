//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func count(entity: String, any branches: [[Filter]]) async throws -> Int? {
        try await fold(of: nil, by: nil, entity: entity, any: branches)?
            .values
            .reduce(0) { $0 + $1.count }
    }
}
