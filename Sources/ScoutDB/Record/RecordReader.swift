//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public protocol RecordReader: Sendable {
    func read(matching query: RecordQuery, fields: [String]?) async throws -> RecordChunk
    func read(matching query: RecordQuery, fields: [String]?, limit: Int) async throws -> RecordChunk
}

extension RecordReader {
    func read(matching query: RecordQuery, fields: [String]?, limit: Int) async throws -> RecordChunk {
        try await read(matching: query, fields: fields)
    }

    func readMore(from cursor: RecordCursor, fields: [String]?) async throws -> RecordChunk {
        try await cursor.next(fields)
    }

    func readAll(matching query: RecordQuery, fields: [String]?) async throws -> [Record] {
        var chunk = try await read(matching: query, fields: fields)
        while let cursor = chunk.cursor {
            chunk += try await readMore(from: cursor, fields: fields)
        }
        return chunk.records
    }

    func readAll<T: RecordDecodable>(matching query: RecordQuery, fields: [String]? = nil) async throws -> [T] {
        try await readAll(matching: query, fields: fields).map(T.init)
    }
}

public struct RecordCursor: Sendable {
    public let next: @Sendable ([String]?) async throws -> RecordChunk

    public init(next: @escaping @Sendable ([String]?) async throws -> RecordChunk) {
        self.next = next
    }
}

public struct RecordChunk {
    public let records: [Record]
    public let cursor: RecordCursor?

    public init(records: [Record], cursor: RecordCursor?) {
        self.records = records
        self.cursor = cursor
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        RecordChunk(records: lhs.records + rhs.records, cursor: rhs.cursor)
    }
}
