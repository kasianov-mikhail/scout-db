//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct EntityCoder {
    let definition: EntityDefinition

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    func encode(_ entityRecord: EntityRecord, into base: CKRecord? = nil) throws -> CKRecord {
        let fields = definition.fields(at: entityRecord.schemaVersion)
        let values = entityRecord.values

        let record =
            base ?? CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: entityRecord.uuid))
        record["entity"] = entityRecord.entity
        record["schema_version"] = Int64(entityRecord.schemaVersion)
        record["uuid"] = entityRecord.uuid

        var payload: [String: RecordValue] = [:]
        for field in fields {
            guard let value = values[field.name] else {
                if case .slot(_, let slot) = field.storage {
                    record[slot] = nil
                }
                continue
            }
            switch field.storage {
            case .slot(_, let slot):
                record[slot] = value.nativeValue
            case .payload:
                payload[field.name] = value
            }
        }
        record["payload"] = payload.count > 0 ? try jsonEncoder.encode(payload) : nil
        return record
    }

    func decode(_ record: CKRecord) throws -> EntityRecord {
        guard let version = record["schema_version"] as? Int64, let uuid = record["uuid"] as? String else {
            throw SchemaError.staleSchema(entity: definition.entity, version: 0)
        }
        guard version <= definition.version else {
            throw SchemaError.staleSchema(entity: definition.entity, version: Int(version))
        }

        var payload: [String: RecordValue] = [:]
        if let data = record["payload"] as? Data {
            payload = try jsonDecoder.decode([String: RecordValue].self, from: data)
        }

        var values: [String: RecordValue] = [:]
        for field in definition.fields(at: Int(version)) {
            switch field.storage {
            case .slot(_, let slot):
                var value = record[slot].flatMap(RecordValue.init(native:))
                if let decoded = value, field.type.isList, decoded.isEmptyList {
                    value = field.type.emptyList
                }
                values[field.name] = value
            case .payload:
                values[field.name] = payload[field.name]
            }
        }

        return EntityRecord(
            entity: definition.entity,
            uuid: uuid,
            schemaVersion: Int(version),
            values: values
        )
    }
}

extension RecordValue {
    fileprivate init?(native value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .bytes(value)
        case let value as CKRecord.Reference:
            self = .reference(value.recordID.recordName)
        case let value as [String]:
            self = .strings(value)
        case let value as [Date]:
            self = .dates(value)
        case let value as [NSNumber]:
            if value.contains(where: { CFNumberIsFloatType($0) }) {
                self = .doubles(value.map(\.doubleValue))
            } else {
                self = .ints(value.map(\.int64Value))
            }
        case let value as NSNumber where CFNumberIsFloatType(value):
            self = .double(value.doubleValue)
        case let value as NSNumber:
            self = .int(value.int64Value)
        default:
            return nil
        }
    }

    fileprivate var nativeValue: any CKRecordValueProtocol {
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
            CKRecord.Reference(recordID: CKRecord.ID(recordName: value), action: .none)
        }
    }
}
