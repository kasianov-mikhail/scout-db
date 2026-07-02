//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public protocol RecordWriter: Sendable {
    func write(record: Record) async throws
    func write(records: [Record]) async throws
}

extension RecordWriter {
    // Records are written in batches no larger than this; the backends cap a single
    // save/modify request at 400 records.
    static var maxBatchSize: Int { 400 }
}

public struct RecordConflictError: LocalizedError {
    public let serverRecord: Record
    public let errorDescription: String? = "The record was changed on the server"

    public init(serverRecord: Record) {
        self.serverRecord = serverRecord
    }
}
