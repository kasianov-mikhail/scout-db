//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension CloudDatabase {
    fileprivate static var maxBatchSize: Int { 400 }

    func write(record: CKRecord) async throws {
        do {
            _ = try await save(record)
        } catch {
            guard let conflict = RecordConflictError(error) else {
                throw error
            }
            throw conflict
        }
    }

    func write(records: [CKRecord]) async throws {
        for chunk in records.chunked(into: Self.maxBatchSize) {
            try await modifyRecords(saving: chunk, deleting: [])
        }
    }

    func writeIfUnchanged(records: [CKRecord]) async throws -> [CKRecord] {
        var conflicts: [CKRecord] = []
        for chunk in records.chunked(into: Self.maxBatchSize) {
            for (_, result) in try await saveIfUnchanged(chunk) {
                guard case .failure(let error) = result else {
                    continue
                }
                guard let conflict = RecordConflictError(error) else {
                    throw error
                }
                conflicts.append(conflict.serverRecord)
            }
        }
        return conflicts
    }
}
