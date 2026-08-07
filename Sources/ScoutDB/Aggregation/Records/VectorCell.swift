//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

protocol VectorCell: SignedNumeric, Comparable, Sendable {
    static func cell(of record: CKRecord, at key: String) -> Self?

    func store(in record: CKRecord, at key: String)

    var scalar: Double { get }
}

extension Double: VectorCell {
    static func cell(of record: CKRecord, at key: String) -> Double? {
        record[key] as? Double
    }

    var scalar: Double {
        self
    }

    func store(in record: CKRecord, at key: String) {
        record[key] = self
    }
}

extension Int64: VectorCell {
    static func cell(of record: CKRecord, at key: String) -> Int64? {
        record[key] as? Int64
    }

    var scalar: Double {
        Double(self)
    }

    func store(in record: CKRecord, at key: String) {
        record[key] = self
    }
}
