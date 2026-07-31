//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

/// One keyset page ordered by an arbitrary field.
public struct FieldPage: Equatable, Sendable {
    public let records: [EntityRecord]
    public let cursor: FieldCursor?
}

extension FieldPage: RandomAccessCollection {
    public var startIndex: Int { records.startIndex }
    public var endIndex: Int { records.endIndex }

    public subscript(position: Int) -> EntityRecord {
        records[position]
    }
}
