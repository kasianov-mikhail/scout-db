//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CryptoKit
import Foundation

struct EntityCoder {
    var keyProvider: (any EncryptionKeyProvider)?

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

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
        for field in fields {
            guard let derived = field.derived else { continue }
            resolved[field.name] = try derive(derived, from: resolved[derived.source], keyID: definition.keyID)
        }
        for field in fields {
            guard let value = resolved[field.name] else {
                if field.required == true { throw SchemaError.missingField(field.name) }
                continue
            }
            guard field.type.matches(value) else { throw SchemaError.typeMismatch(field.name) }
            if let allowed = field.allowed, case .string(let raw) = value, !allowed.contains(raw) {
                throw SchemaError.invalidValue(field.name)
            }
            if let scalar = value.scalar {
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
        let digest = SHA256.hash(data: Data(key.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func encode(_ entityRecord: EntityRecord, using definition: EntityDefinition, into base: CKRecord? = nil) throws -> CKRecord {
        let fields = definition.fields(at: entityRecord.schemaVersion)
        let values = try resolve(entityRecord.values, at: entityRecord.schemaVersion, using: definition)

        let record = base ?? CKRecord(recordType: Item.recordType, recordID: CKRecord.ID(recordName: entityRecord.uuid))
        record["entity"] = entityRecord.entity
        record["schema_version"] = Int64(entityRecord.schemaVersion)
        record["uuid"] = entityRecord.uuid
        record["deleted"] = Int64(entityRecord.deleted ? 1 : 0)
        if let ttl = definition.ttl, let dateField = definition.envelopeDate, case .date(let date)? = values[dateField] {
            record["expires"] = date.addingTimeInterval(ttl)
        }

        var payload: [String: RecordValue] = [:]
        for (name, value) in values {
            guard let field = fields.first(where: { $0.name == name }) else { continue }
            switch field.storage {
            case .slot(_, let slot):
                record.setScoutValue(value, forKey: slot)
            case .payload:
                payload[name] = field.encrypted == true ? try seal(value, keyID: definition.keyID) : value
            }
        }
        if payload.count > 0 {
            record["payload"] = try JSONEncoder().encode(payload)
        }
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
            payload = try JSONDecoder().decode([String: RecordValue].self, from: data)
        }

        var values: [String: RecordValue] = [:]
        for field in definition.fields(at: Int(version)) {
            switch field.storage {
            case .slot(_, let slot):
                values[field.name] = record.scoutValue(forKey: slot)
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
            return .date(Self.calendar.dateInterval(of: .hour, for: value)?.start ?? value)
        case (.day, .date(let value)?):
            return .date(Self.calendar.startOfDay(for: value))
        case (.week, .date(let value)?):
            return .date(Self.calendar.dateInterval(of: .weekOfYear, for: value)?.start ?? value)
        case (.month, .date(let value)?):
            return .date(Self.calendar.dateInterval(of: .month, for: value)?.start ?? value)
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
}
