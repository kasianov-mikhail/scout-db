//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityDefinition {
    func isInteger(_ aggregate: AggregateDefinition) -> Bool {
        guard let field = aggregate.measure?.field else {
            return true
        }
        return (try? self.field(field, at: version))?.type == .int
    }
}
