//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

extension RecordValue {
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
