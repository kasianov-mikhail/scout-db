//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct EntityCoder {
    var keyProvider: (any EncryptionKeyProvider)?

    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()

    static let envelopeKeys = ["entity", "schema_version", "uuid", "deleted"]

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

    func resolve(_ values: [String: RecordValue], at version: Int, using definition: EntityDefinition) throws -> [String: RecordValue] {
        let fields = definition.fields(at: version)
        var resolved = values

        for field in fields where resolved[field.name] == nil {
            resolved[field.name] = field.defaultValue
        }
        for field in fields where field.type == .asset {
            switch resolved[field.name] {
            case .bytes(let data)?:
                resolved[field.name] = try Self.stage(data)
            case .asset(let url)?:
                try Self.validateAssetSize(at: url)
            default:
                break
            }
        }
        let derivations = fields.filter { $0.derived != nil }
        for _ in 0...derivations.count {
            var changed = false
            for field in derivations {
                guard let derived = field.derived else {
                    continue
                }
                let value = try derive(derived, from: resolved[derived.source], keyID: definition.keyID)
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
            if let pattern = field.pattern, let regex = Self.patterns.regex(for: pattern), !value.strings.allSatisfy({ $0.wholeMatch(of: regex) != nil }) {
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

    func rewrite(_ record: CKRecord, using definition: EntityDefinition, transform: (inout EntityRecord) throws -> Void) throws -> Rewrite {
        let (previous, payload) = try decodeWithPayload(record, using: definition)
        var next = previous
        try transform(&next)
        next.values = try resolve(next.values, at: next.schemaVersion, using: definition)
        return Rewrite(previous: previous, next: next, record: try encode(next, using: definition, into: record, basePayload: payload))
    }

    private func decodedPayload(of record: CKRecord?) -> [String: RecordValue]? {
        guard let data = record?["payload"] as? Data else {
            return nil
        }
        return try? jsonDecoder.decode([String: RecordValue].self, from: data)
    }

    func encode(_ entityRecord: EntityRecord, using definition: EntityDefinition, into base: CKRecord? = nil, basePayload: [String: RecordValue]? = nil)
        throws -> CKRecord
    {
        let fields = definition.fields(at: entityRecord.schemaVersion)
        let values = entityRecord.values

        let record =
            base ?? CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: entityRecord.uuid))
        record["entity"] = entityRecord.entity
        record["schema_version"] = Int64(entityRecord.schemaVersion)
        record["uuid"] = entityRecord.uuid
        record["deleted"] = Int64(entityRecord.deleted ? 1 : 0)

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
                payload[field.name] = field.encrypted == true ? try seal(value, keyID: definition.keyID) : value
            }
        }
        if keyProvider == nil, let existing = basePayload ?? decodedPayload(of: base) {
            for field in fields where field.encrypted == true && payload[field.name] == nil {
                payload[field.name] = existing[field.name]
            }
        }
        record["payload"] = payload.count > 0 ? try jsonEncoder.encode(payload) : nil
        return record
    }

    func decode(_ record: CKRecord, using definition: EntityDefinition) throws -> EntityRecord {
        try decodeWithPayload(record, using: definition).record
    }

    fileprivate func decodeWithPayload(_ record: CKRecord, using definition: EntityDefinition) throws -> (
        record: EntityRecord, payload: [String: RecordValue]
    ) {
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
                if field.encrypted == true {
                    values[field.name] = keyProvider == nil ? nil : try payload[field.name].map { try open($0, keyID: definition.keyID) }
                } else {
                    values[field.name] = payload[field.name]
                }
            }
        }

        let deleted = (record["deleted"] as? Int64 ?? 0) > 0
        return (EntityRecord(entity: definition.entity, uuid: uuid, schemaVersion: Int(version), values: values, deleted: deleted), payload)
    }

    static func trigrams(of text: String) -> [String] {
        guard text.count >= 3 else {
            return text.isEmpty ? [] : [text]
        }
        var seen: Set<String> = []
        var trigrams: [String] = []
        var start = text.startIndex
        while let end = text.index(start, offsetBy: 3, limitedBy: text.endIndex) {
            let trigram = String(text[start..<end])
            if seen.insert(trigram).inserted {
                trigrams.append(trigram)
            }
            start = text.index(after: start)
        }
        return trigrams
    }

    private func derive(_ derivation: Derivation, from source: RecordValue?, keyID: String?) throws -> RecordValue? {
        switch (derivation.transform, source) {
        case (.lowercase, .string(let value)?):
            .string(value.lowercased())
        case (.fold, .string(let value)?):
            .string(value.folded)
        case (.reversed, .string(let value)?):
            .string(String(value.reversed()))
        case (.ngrams, .string(let value)?):
            .strings(Self.trigrams(of: value.folded))
        case (.hmac, let value?):
            .string(try surrogate(for: value.canonical, keyID: keyID))
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

extension RecordValue {
    var canonical: String {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            "i\(value)"
        case .double(let value):
            "d\(value)"
        case .date(let value):
            "t\(value.millisecondsSince1970)"
        case .bytes(let value):
            "b\(value.base64EncodedString())"
        case .strings(let value):
            value.joined(separator: ",")
        case .ints(let value):
            "i[\(value.map { "\($0)" }.joined(separator: ","))]"
        case .doubles(let value):
            "d[\(value.map { "\($0)" }.joined(separator: ","))]"
        case .dates(let value):
            "t[\(value.map { String($0.millisecondsSince1970) }.joined(separator: ","))]"
        case .locations(let value):
            "g[\(value.map { "\($0.latitude);\($0.longitude)" }.joined(separator: ","))]"
        case .assets(let value):
            "a[\(value.map(\.absoluteString).joined(separator: ","))]"
        case .location(let latitude, let longitude):
            "g\(latitude),\(longitude)"
        case .reference(let value):
            "r\(value)"
        case .asset(let value):
            "a\(value.absoluteString)"
        }
    }

    var scalar: Double? {
        switch self {
        case .int(let value):
            Double(value)
        case .double(let value):
            value
        default:
            nil
        }
    }

    var members: [RecordValue]? {
        switch self {
        case .strings(let values):
            values.map(RecordValue.string)
        case .ints(let values):
            values.map(RecordValue.int)
        case .doubles(let values):
            values.map(RecordValue.double)
        case .dates(let values):
            values.map(RecordValue.date)
        default:
            nil
        }
    }

    fileprivate var isEmptyList: Bool {
        switch self {
        case .strings(let value):
            value.isEmpty
        case .ints(let value):
            value.isEmpty
        case .doubles(let value):
            value.isEmpty
        case .dates(let value):
            value.isEmpty
        case .locations(let value):
            value.isEmpty
        case .assets(let value):
            value.isEmpty
        default:
            false
        }
    }

    var strings: [String] {
        switch self {
        case .string(let value):
            [value]
        case .strings(let value):
            value
        default:
            []
        }
    }

    var scalars: [Double] {
        switch self {
        case .int(let value):
            [Double(value)]
        case .double(let value):
            [value]
        case .ints(let value):
            value.map(Double.init)
        case .doubles(let value):
            value
        default:
            []
        }
    }
}
