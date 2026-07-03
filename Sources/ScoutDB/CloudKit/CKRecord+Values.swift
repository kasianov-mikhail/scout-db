//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CoreLocation
import ObjectiveC

extension CKRecord {
    subscript<T: RecordValueConvertible>(scout key: String) -> T? {
        get { scoutValue(forKey: key).flatMap(T.init(recordValue:)) }
        set { self[key] = newValue?.recordValue.ckValue }
    }

    func scoutValue(forKey key: String) -> RecordValue? {
        self[key].flatMap(RecordValue.init(native:))
    }

    func setScoutValue(_ value: RecordValue?, forKey key: String) {
        self[key] = value?.ckValue
    }
}

extension RecordValue {
    init?(native value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .bytes(value)
        case let value as CLLocation:
            self = .location(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude)
        case let value as CKRecord.Reference:
            self = .reference(value.recordID.recordName)
        case let value as CKAsset:
            guard let url = value.fileURL else { return nil }
            self = .asset(url)
        case let value as [String]:
            self = .strings(value)
        case let value as [Date]:
            self = .dates(value)
        case let value as [Int64]:
            self = .ints(value)
        case let value as [Double]:
            self = .doubles(value)
        case let value as [CLLocation]:
            self = .locations(value.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
        case let value as [CKAsset]:
            self = .assets(value.compactMap(\.fileURL))
        case let value as NSNumber where CFNumberIsFloatType(value):
            self = .double(value.doubleValue)
        case let value as NSNumber:
            self = .int(value.int64Value)
        default:
            return nil
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

    var predicateValue: CVarArg {
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

// CloudKit sets the system fields server-side and exposes them read-only, so the
// store reads them through these accessors and tests inject values underneath.
private nonisolated(unsafe) var modificationDateKey: UInt8 = 0
private nonisolated(unsafe) var creatorKey: UInt8 = 0

extension CKRecord {
    /// The record's modification date, honoring a testing override.
    public var recordModificationDate: Date? {
        objc_getAssociatedObject(self, &modificationDateKey) as? Date ?? modificationDate
    }

    /// The record's creator identifier, honoring a testing override.
    public var recordCreator: String? {
        objc_getAssociatedObject(self, &creatorKey) as? String ?? creatorUserRecordID?.recordName
    }

    /// Injects a modification date underneath the read-only system field.
    public func overrideModificationDate(_ date: Date) {
        objc_setAssociatedObject(self, &modificationDateKey, date, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Injects a creator identifier underneath the read-only system field.
    public func overrideCreator(_ name: String) {
        objc_setAssociatedObject(self, &creatorKey, name, .OBJC_ASSOCIATION_RETAIN)
    }
}
