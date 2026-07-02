//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation

extension Record {
    init(ckRecord: CKRecord) {
        var fields = Dictionary(
            uniqueKeysWithValues: ckRecord.allKeys().compactMap { key in
                ckRecord[key].flatMap(RecordValue.init(native:)).map { (key, $0) }
            }
        )
        if let creator = ckRecord.creatorUserRecordID?.recordName {
            fields["___createdBy"] = .string(creator)
        }
        if let modified = ckRecord.modificationDate {
            fields["___modTime"] = .date(modified)
        }
        self.init(
            recordType: ckRecord.recordType,
            recordID: ckRecord.recordID.recordName,
            fields: fields,
            metadata: ckRecord.encodedSystemFields
        )
    }

    var ckRecord: CKRecord {
        let record =
            metadata.flatMap(CKRecord.decoded(systemFields:))
            ?? CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordID))
        for (key, value) in fields where !key.hasPrefix("___") {
            record[key] = value.ckValue
        }
        return record
    }
}

extension RecordValue {
    fileprivate init?(native value: Any) {
        if let location = value as? CLLocation {
            self = .location(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        } else if let reference = value as? CKRecord.Reference {
            self = .reference(reference.recordID.recordName)
        } else if let asset = value as? CKAsset {
            guard let url = asset.fileURL else { return nil }
            self = .asset(url)
        } else if let value = value as? [Date] {
            self = .dates(value)
        } else if let value = value as? [Int64] {
            self = .ints(value)
        } else if let value = value as? [Double] {
            self = .doubles(value)
        } else if let value = value as? [CLLocation] {
            self = .locations(value.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
        } else if let value = value as? [CKAsset] {
            self = .assets(value.compactMap(\.fileURL))
        } else {
            self.init(any: value)
        }
    }

    var ckValue: any CKRecordValueProtocol {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .date(let value): value
        case .bytes(let value): value
        case .strings(let value): value
        case .ints(let value): value
        case .doubles(let value): value
        case .dates(let value): value
        case .locations(let value): value.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        case .assets(let value): value.map { CKAsset(fileURL: $0) }
        case .location(let latitude, let longitude): CLLocation(latitude: latitude, longitude: longitude)
        case .reference(let value): CKRecord.Reference(recordID: CKRecord.ID(recordName: value), action: .none)
        case .asset(let value): CKAsset(fileURL: value)
        }
    }

    fileprivate var predicateValue: CVarArg {
        switch self {
        case .string(let value): value
        case .int(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        case .date(let value): value as NSDate
        case .bytes(let value): value as NSData
        case .strings(let value): value as NSArray
        case .ints(let value): value as NSArray
        case .doubles(let value): value as NSArray
        case .dates(let value): value as NSArray
        case .locations(let value): value.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) } as NSArray
        case .assets(let value): value.map { CKAsset(fileURL: $0) } as NSArray
        case .location(let latitude, let longitude): CLLocation(latitude: latitude, longitude: longitude)
        case .reference(let value): CKRecord.Reference(recordID: CKRecord.ID(recordName: value), action: .none)
        case .asset(let value): value as NSURL
        }
    }
}

extension CKRecord {
    fileprivate var encodedSystemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    fileprivate static func decoded(systemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }
}

extension CKQuery {
    convenience init(_ query: RecordQuery) {
        let predicate: NSPredicate =
            query.filters.isEmpty
            ? NSPredicate(value: true)
            : NSCompoundPredicate(type: .and, subpredicates: query.filters.map(\.predicate))

        self.init(recordType: query.recordType.recordType, predicate: predicate)

        if query.sort.count > 0 {
            sortDescriptors = query.sort.map { NSSortDescriptor(key: $0.field, ascending: $0.ascending) }
        }
    }
}

extension RecordQuery.Filter {
    fileprivate var predicate: NSPredicate {
        let value = value.predicateValue
        return switch op {
        case .equals: NSPredicate(format: "%K == %@", field, value)
        case .notEquals: NSPredicate(format: "%K != %@", field, value)
        case .greaterThan: NSPredicate(format: "%K > %@", field, value)
        case .greaterThanOrEquals: NSPredicate(format: "%K >= %@", field, value)
        case .lessThan: NSPredicate(format: "%K < %@", field, value)
        case .lessThanOrEquals: NSPredicate(format: "%K <= %@", field, value)
        case .in: NSPredicate(format: "%K IN %@", field, value)
        case .notIn: NSPredicate(format: "NOT (%K IN %@)", field, value)
        case .beginsWith: NSPredicate(format: "%K BEGINSWITH %@", field, value)
        case .contains: NSPredicate(format: "%K CONTAINS %@", field, value)
        case .near: NSPredicate(format: "distanceToLocation:fromLocation:(%K, %@) < %f", field, value, radius ?? 0)
        case .search: NSPredicate(format: "self contains %@", value)
        }
    }
}
