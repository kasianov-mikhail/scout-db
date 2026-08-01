//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct EntityCoder {
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()

    static let envelopeKeys = ["entity", "schema_version", "uuid"]

    private static let patterns = PatternCache()

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    static func periodStart(of component: Calendar.Component, for date: Date) -> Date {
        calendar.dateInterval(of: component, for: date)?.start ?? date
    }

    func resolve(_ values: [String: RecordValue], at version: Int, using definition: EntityDefinition) throws
        -> [String: RecordValue]
    {
        let fields = definition.fields(at: version)
        var resolved = values

        for field in fields where resolved[field.name] == nil {
            resolved[field.name] = field.defaultValue
        }
        let derivations = fields.filter { $0.derived != nil }
        for _ in 0...derivations.count {
            var changed = false
            for field in derivations {
                guard let derived = field.derived else {
                    continue
                }
                let value = derive(derived, from: resolved[derived.source])
                if value != resolved[field.name] {
                    resolved[field.name] = value
                    changed = true
                }
            }
            if !changed {
                break
            }
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

    struct Rewrite {
        let previous: EntityRecord
        let next: EntityRecord
        let record: CKRecord
    }

    func rewrite(_ record: CKRecord, using definition: EntityDefinition, transform: (inout EntityRecord) throws -> Void)
        throws -> Rewrite
    {
        let previous = try decode(record, using: definition)
        var next = previous
        try transform(&next)
        next.values = try resolve(next.values, at: next.schemaVersion, using: definition)
        return Rewrite(previous: previous, next: next, record: try encode(next, using: definition, into: record))
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
                record.setScoutValue(value, forKey: slot)
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
                var value = record.scoutValue(forKey: slot)
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

    private func derive(_ derivation: Derivation, from source: RecordValue?) -> RecordValue? {
        switch (derivation.transform, source) {
        case (.lowercase, .string(let value)?):
            .string(value.lowercased())
        case (.fold, .string(let value)?):
            .string(value.folded)
        case (.hour, .date(let value)?):
            .date(Self.periodStart(of: .hour, for: value))
        case (.day, .date(let value)?):
            .date(Self.periodStart(of: .day, for: value))
        case (.week, .date(let value)?):
            .date(Self.periodStart(of: .weekOfYear, for: value))
        case (.month, .date(let value)?):
            .date(Self.periodStart(of: .month, for: value))
        default:
            nil
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

extension String {
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
