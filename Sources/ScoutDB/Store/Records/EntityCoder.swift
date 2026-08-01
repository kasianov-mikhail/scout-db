//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct EntityCoder {
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    private static let patterns = PatternCache()

    func resolve(_ values: [String: RecordValue], at version: Int, using definition: EntityDefinition) throws
        -> [String: RecordValue]
    {
        let fields = definition.fields(at: version)
        var resolved = values

        for field in fields where resolved[field.name] == nil {
            resolved[field.name] = field.defaultValue
        }
        for field in fields {
            guard let value = resolved[field.name] else {
                if field.required == true {
                    throw SchemaError.missingField(field.name)
                }
                continue
            }
            guard field.type.matches(value) else {
                throw SchemaError.typeMismatch(field.name)
            }
            if let allowed = field.allowed, !value.strings.allSatisfy(allowed.contains) {
                throw SchemaError.invalidValue(field.name)
            }
            if let pattern = field.pattern, let regex = Self.patterns.regex(for: pattern),
                !value.strings.allSatisfy({ $0.wholeMatch(of: regex) != nil })
            {
                throw SchemaError.invalidValue(field.name)
            }
            for scalar in value.scalars {
                if let min = field.min, scalar < min {
                    throw SchemaError.invalidValue(field.name)
                }
                if let max = field.max, scalar > max {
                    throw SchemaError.invalidValue(field.name)
                }
            }
        }
        let known = definition.fieldsByName(at: version)
        for name in resolved.keys where known[name] == nil {
            throw SchemaError.unknownField(name)
        }
        return resolved
    }

    func naturalUUID(for values: [String: RecordValue], using definition: EntityDefinition) throws -> String? {
        guard let unique = definition.unique else {
            return nil
        }
        let key = try unique.map { name in
            guard let value = values[name] else {
                throw SchemaError.missingField(name)
            }
            return "\(name)=\(value.canonical)"
        }
        return contentDigest(of: key)
    }

    func rewrite(_ record: CKRecord, using definition: EntityDefinition, transform: (inout EntityRecord) throws -> Void)
        throws -> CKRecord
    {
        var next = try decode(record, using: definition)
        try transform(&next)
        next.values = try resolve(next.values, at: next.schemaVersion, using: definition)
        return try encode(next, using: definition, into: record)
    }

    func encode(_ entityRecord: EntityRecord, using definition: EntityDefinition, into base: CKRecord? = nil) throws
        -> CKRecord
    {
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

    func decode(_ record: CKRecord, using definition: EntityDefinition) throws -> EntityRecord {
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

        return EntityRecord(entity: definition.entity, uuid: uuid, schemaVersion: Int(version), values: values)
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

private final class PatternCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: Regex<AnyRegexOutput>?] = [:]

    func regex(for pattern: String) -> Regex<AnyRegexOutput>? {
        lock.withLock {
            if let known = compiled[pattern] {
                return known
            }
            let regex = try? Regex(pattern)
            compiled[pattern] = regex
            return regex
        }
    }
}
