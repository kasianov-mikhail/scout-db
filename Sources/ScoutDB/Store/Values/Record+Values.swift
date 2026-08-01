//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import ObjectiveC

extension CKRecord {
    func scoutValue(forKey key: String) -> RecordValue? {
        self[key].flatMap(RecordValue.init(native:))
    }

    func setScoutValue(_ value: RecordValue?, forKey key: String) {
        self[key] = value?.nativeValue
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

    var predicateValue: CVarArg {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            NSNumber(value: value)
        case .double(let value):
            NSNumber(value: value)
        case .date(let value):
            value as NSDate
        case .bytes(let value):
            value as NSData
        case .strings(let value):
            value as NSArray
        case .ints(let value):
            value as NSArray
        case .doubles(let value):
            value as NSArray
        case .dates(let value):
            value as NSArray
        case .reference(let value):
            CKRecord.Reference(recordID: CKRecord.ID(recordName: value), action: .none)
        }
    }
}

/// The record metadata a `CloudDatabase` double stamps for itself.
///
/// CloudKit assigns a change tag and a modification date on the server, and
/// `CKRecord` exposes both read-only. A double has no server to assign them, so
/// it stores its own here and the library reads them where it would read
/// CloudKit's. Nothing in ScoutDB writes them — the double does, through the
/// accessors `ScoutDBTesting` puts on top of this.
///
package struct RecordOverrides: Sendable {
    package var modificationDate: Date?
    package var changeTag: String?
}

private nonisolated(unsafe) var overridesKey: UInt8 = 0

extension CKRecord {
    package var overrides: RecordOverrides {
        get { objc_getAssociatedObject(self, &overridesKey) as? RecordOverrides ?? RecordOverrides() }
        set { objc_setAssociatedObject(self, &overridesKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// A copy that keeps the overrides `copy()` leaves behind.
    package func duplicate() -> CKRecord {
        let copy = self.copy() as! CKRecord
        copy.overrides = overrides
        return copy
    }
}
