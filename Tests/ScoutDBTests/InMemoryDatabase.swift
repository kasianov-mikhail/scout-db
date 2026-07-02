//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

final class InMemoryDatabase: RecordReader, RecordWriter, @unchecked Sendable {
    var records: [Record] = []
    var errors: [Error] = []
    var writeErrors: [Error] = []

    func write(record: Record) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        } else {
            upsert(record)
        }
    }

    func write(records: [Record]) async throws {
        if let error = writeErrors.popLast() ?? errors.popLast() {
            throw error
        } else {
            records.forEach(upsert)
        }
    }

    private func upsert(_ record: Record) {
        records.removeAll { $0.recordType == record.recordType && $0.recordID == record.recordID }
        records.append(record)
    }

    func read(matching query: RecordQuery, fields: [String]?) async throws -> RecordChunk {
        if let error = errors.popLast() {
            throw error
        }
        return RecordChunk(
            records: records.filter { $0.matches(query) }.sorted(by: query.sort).map { project($0, fields: fields) },
            cursor: nil
        )
    }

    private func project(_ record: Record, fields: [String]?) -> Record {
        guard let fields else { return record }
        var projected = record
        projected.fields = record.fields.filter { fields.contains($0.key) || $0.key.hasPrefix("___") }
        return projected
    }
}
