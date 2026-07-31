//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension EntityStore {
    func decode(_ records: [CKRecord], using definition: EntityDefinition) throws -> [EntityRecord] {
        let coder = EntityCoder(keyProvider: keyProvider)
        return try records.compactMap { try decode($0, with: coder, using: definition) }
    }

    func decode(_ record: CKRecord, with coder: EntityCoder, using definition: EntityDefinition) throws -> EntityRecord? {
        guard trusted(record) else {
            return nil
        }
        return try coder.decode(record, using: definition)
    }

    private func trusted(_ record: CKRecord) -> Bool {
        guard let trustedWriters else {
            return true
        }
        guard let creator = record.creatorName else {
            return false
        }
        return trustedWriters.contains(creator)
    }
}
