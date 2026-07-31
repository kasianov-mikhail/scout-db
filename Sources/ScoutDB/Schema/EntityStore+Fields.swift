//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func alwaysPresent(_ field: String, entity: String) async throws -> Bool {
        let definition = try await registry.definition(for: entity)

        guard let target = definition.field(named: field, at: definition.version) else {
            return false
        }

        return target.alwaysPresent
    }
}
