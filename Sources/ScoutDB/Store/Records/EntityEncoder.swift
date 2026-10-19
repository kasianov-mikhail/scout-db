//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CryptoKit
import Foundation

struct EntityEncoder {
    let definition: EntityDefinition

    private let jsonEncoder = JSONEncoder()

    func encode(_ entityRecord: EntityRecord) throws -> CKRecord {
        let fields = definition.fields(at: entityRecord.schemaVersion)
        let values = entityRecord.values

        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: entityRecord.uuid))

        record[Envelope.entity] = entityRecord.entity
        record[Envelope.uuid] = entityRecord.uuid
        record[Envelope.version] = Int64(entityRecord.schemaVersion)

        for field in fields {
            guard let value = values[field.name] else {
                record[field.storage.slot] = nil
                continue
            }

            switch field.storage {
            case .slot(_, let slot):
                record[slot] = try value.nativeValue
            case .payload(let slot):
                record[slot] = try jsonEncoder.encode(value)
            }
        }

        return record
    }
}

extension RecordValue {
    fileprivate var nativeValue: any CKRecordValueProtocol {
        get throws {
            switch self {
            case .string(let value):
                value
            case .int(let value):
                value
            case .double(let value):
                value
            case .date(let value):
                value
            case .bytes(let value):
                value
            case .strings(let value):
                value
            case .ints(let value):
                value
            case .doubles(let value):
                value
            case .dates(let value):
                value
            case .reference(let value):
                CKRecord.Reference(uuid: value)
            case .references(let value):
                value.map(CKRecord.Reference.init(uuid:))
            case .blobs(let value):
                value
            case .asset(let value):
                CKAsset(fileURL: try AssetFile(data: value).url)
            }
        }
    }
}

private struct AssetFile {
    let url: URL

    init(data: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutDBAssets", isDirectory: true)
        let name = SHA256.hash(data: data).hexString
        url = directory.appendingPathComponent(name)

        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
