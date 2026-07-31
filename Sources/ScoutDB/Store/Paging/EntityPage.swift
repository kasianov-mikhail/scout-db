//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

public struct EntityPage: Equatable, Sendable {
    public let records: [EntityRecord]
    public let cursor: EntityCursor?
}

extension EntityPage: RandomAccessCollection {
    public var startIndex: Int { records.startIndex }
    public var endIndex: Int { records.endIndex }

    public subscript(position: Int) -> EntityRecord {
        records[position]
    }
}
