//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    func grid(entity: String, view: String, group: String?) async throws -> [CKRecord] {
        try await database.allRecords(matching: .grid(entity: entity, view: view, group: group))
    }
}
