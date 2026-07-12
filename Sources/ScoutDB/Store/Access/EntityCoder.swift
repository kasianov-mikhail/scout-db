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
    var zoneID: CKRecordZone.ID?

    // One coder pair per store operation instead of one per record — payload
    // encoding and decoding run once for every record in a batch.
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()

    /// The envelope keys `encode` writes on every record; projections always fetch them.
    static let envelopeKeys = ["entity", "schema_version", "uuid", "deleted"]

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // The canonical calendar-period truncation. Derived date fields and grid slot
    // keys both build on it, so the two always line up.
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
        // Derivations can chain — one derived field's source may itself be a derived
        // field declared later. Iterate to a fixpoint instead of relying on declaration
        // order; a DAG settles within one pass per link, and the bound caps a bad cycle.
        let derivations = fields.filter { $0.derived != nil }
        for _ in 0...derivations.count {
            var changed = false
            for field in derivations {
                guard let derived = field.derived else { continue }
                let value = try derive(derived, from: resolved[derived.source], keyID: definition.keyID)
                if value != resolved[field.name] {
                    resolved[field.name] = value
                    changed = true
                }
            }
            if !changed { break }
        }
        for field in fields {
            guard let value = resolved[field.name] else {
                if field.required == true { throw SchemaError.missingField(field.name) }
                continue
            }
            guard field.type.matches(value) else { throw SchemaError.typeMismatch(field.name) }
            if let allowed = field.allowed, !value.strings.allSatisfy(allowed.contains) {
                throw SchemaError.invalidValue(field.name)
            }
            if let pattern = field.pattern, let regex = try? Regex(pattern), !value.strings.allSatisfy({ $0.wholeMatch(of: regex) != nil }) {
                throw SchemaError.invalidValue(field.name)
            }
            for scalar in value.scalars {
                if let minimum = field.minimum, scalar < minimum { throw SchemaError.invalidValue(field.name) }
                if let maximum = field.maximum, scalar > maximum { throw SchemaError.invalidValue(field.name) }
            }
        }
        for name in resolved.keys where !fields.contains(where: { $0.name == name }) {
            throw SchemaError.unknownField(name)
        }
        return resolved
    }

    func naturalUUID(for values: [String: RecordValue], using definition: EntityDefinition) throws -> String? {
        guard let unique = definition.unique else { return nil }
        let key = try unique.map { name in
            guard let value = values[name] else { throw SchemaError.missingField(name) }
            return "\(name)=\(value.canonical)"
        }
        return contentDigest(of: key)
    }

    // One rewritten record: the decoded state before the transform, the state
    // after, and the CKRecord encoded back into the source.
    struct Rewrite {
        let previous: EntityRecord
        let next: EntityRecord
        let record: CKRecord
    }

    // The one read-modify-write pipeline: decode the stored record, apply the
    // transform, resolve, and encode back into the source CKRecord. Encoding into
    // the source is what carries the untouched ciphertext of encrypted fields
    // across a keyless rewrite, so every rewrite path — update, updateAll,
    // backfill — must come through here instead of encoding a fresh record.
    func rewrite(_ record: CKRecord, using definition: EntityDefinition, transform: (inout EntityRecord) throws -> Void) throws -> Rewrite {
        let previous = try decode(record, using: definition)
        var next = previous
        try transform(&next)
        next.values = try resolve(next.values, at: next.schemaVersion, using: definition)
        return Rewrite(previous: previous, next: next, record: try encode(next, using: definition, into: record))
    }

    // The record's values must already be resolved (defaults filled, derivations
    // applied, constraints validated) — callers run `resolve` once and encode the
    // result, so the derivation fixpoint never runs twice per write.
    func encode(_ entityRecord: EntityRecord, using definition: EntityDefinition, into base: CKRecord? = nil) throws -> CKRecord {
        let fields = definition.fields(at: entityRecord.schemaVersion)
        let values = entityRecord.values

        let record =
            base ?? CKRecord(recordType: Entity.recordType, recordID: CKRecord.ID(recordName: entityRecord.uuid, zoneID: zoneID ?? .default))
        record["entity"] = entityRecord.entity
        record["schema_version"] = Int64(entityRecord.schemaVersion)
        record["uuid"] = entityRecord.uuid
        record["deleted"] = Int64(entityRecord.deleted ? 1 : 0)
        if let ttl = definition.ttl, let dateField = definition.envelopeDate, case .date(let date)? = values[dateField] {
            record["expires"] = date.addingTimeInterval(ttl)
        }

        // Walk the declared fields, not the present values: a field the transform
        // cleared must nil out its slot on the base record, or the old value would
        // survive the rewrite as a stale read.
        var payload: [String: RecordValue] = [:]
        for field in fields {
            guard let value = values[field.name] else {
                if case .slot(_, let slot) = field.storage { record[slot] = nil }
                continue
            }
            switch field.storage {
            case .slot(_, let slot):
                record.setScoutValue(value, forKey: slot)
            case .payload:
                payload[field.name] = field.encrypted == true ? try seal(value, keyID: definition.keyID) : value
            }
        }
        // A keyless read leaves encrypted fields absent (decode cannot open them without a
        // key), so a read-modify-write would otherwise drop their ciphertext. Carry the
        // untouched ciphertext over verbatim from the base record's payload.
        if let base, let data = base["payload"] as? Data, let existing = try? jsonDecoder.decode([String: RecordValue].self, from: data) {
            for field in fields where field.encrypted == true && payload[field.name] == nil {
                payload[field.name] = existing[field.name]
            }
        }
        // The payload blob is rebuilt from scratch, so an emptied one must clear the
        // key rather than leave the base record's old blob behind.
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
                // CloudKit erases the element type of an empty array, so an empty typed
                // list bridges back as `.strings([])`. Restore the field's declared kind.
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
        return EntityRecord(entity: definition.entity, uuid: uuid, schemaVersion: Int(version), values: values, deleted: deleted)
    }

    static func trigrams(of text: String) -> [String] {
        guard text.count >= 3 else { return text.isEmpty ? [] : [text] }
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
            return .string(value.lowercased())
        case (.fold, .string(let value)?):
            return .string(value.folded)
        case (.reversed, .string(let value)?):
            return .string(String(value.reversed()))
        case (.ngrams, .string(let value)?):
            return .strings(Self.trigrams(of: value.folded))
        case (.hmac, let value?):
            return .string(try surrogate(for: value.canonical, keyID: keyID))
        case (.hour, .date(let value)?):
            return .date(Self.periodStart(of: .hour, for: value))
        case (.day, .date(let value)?):
            return .date(Self.periodStart(of: .day, for: value))
        case (.week, .date(let value)?):
            return .date(Self.periodStart(of: .weekOfYear, for: value))
        case (.month, .date(let value)?):
            return .date(Self.periodStart(of: .month, for: value))
        default:
            return nil
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
        case .string(let value): return value
        case .int(let value): return "i\(value)"
        case .double(let value): return "d\(value)"
        case .date(let value): return "t\(value.millisecondsSince1970)"
        case .bytes(let value): return "b\(value.base64EncodedString())"
        case .strings(let value): return value.joined(separator: ",")
        case .ints(let value): return "i[\(value.map { "\($0)" }.joined(separator: ","))]"
        case .doubles(let value): return "d[\(value.map { "\($0)" }.joined(separator: ","))]"
        case .dates(let value): return "t[\(value.map { String($0.millisecondsSince1970) }.joined(separator: ","))]"
        case .locations(let value): return "g[\(value.map { "\($0.latitude);\($0.longitude)" }.joined(separator: ","))]"
        case .assets(let value): return "a[\(value.map(\.absoluteString).joined(separator: ","))]"
        case .location(let latitude, let longitude): return "g\(latitude),\(longitude)"
        case .reference(let value): return "r\(value)"
        case .asset(let value): return "a\(value.absoluteString)"
        }
    }

    var scalar: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var isEmptyList: Bool {
        switch self {
        case .strings(let value): value.isEmpty
        case .ints(let value): value.isEmpty
        case .doubles(let value): value.isEmpty
        case .dates(let value): value.isEmpty
        case .locations(let value): value.isEmpty
        case .assets(let value): value.isEmpty
        default: false
        }
    }

    // The string members an `allowed` domain constrains: the scalar for a string, every
    // element for a string list, and none (a vacuous pass) for any other kind.
    var strings: [String] {
        switch self {
        case .string(let value): [value]
        case .strings(let value): value
        default: []
        }
    }

    // The numeric members a `minimum`/`maximum` bound constrains: the scalar for an int or
    // double, every element for an int or double list, and none for any other kind.
    var scalars: [Double] {
        switch self {
        case .int(let value): [Double(value)]
        case .double(let value): [value]
        case .ints(let value): value.map(Double.init)
        case .doubles(let value): value
        default: []
        }
    }
}
