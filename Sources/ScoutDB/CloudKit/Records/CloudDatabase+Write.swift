//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

/// The most records CloudKit accepts in one request.
let maxBatchSize = 400

extension CloudDatabase {
    func write(records: [CKRecord]) async throws {
        for chunk in records.chunked(into: maxBatchSize) {
            try await modifyRecords(saving: chunk, deleting: [])
        }
    }
}
