//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

// The single seam between the store and CloudKit, kept internal on purpose:
// the public API takes a CKDatabase, tests inject an in-memory implementation.
protocol Database: Sendable {
    func read(matching query: RecordQuery, fields: [String]?) async throws -> RecordChunk
    func write(record: Record) async throws
    func write(records: [Record]) async throws
}

extension Database {
    static var maxBatchSize: Int { 400 }

    func readAll(matching query: RecordQuery, fields: [String]? = nil) async throws -> [Record] {
        var chunk = try await read(matching: query, fields: fields)
        while let cursor = chunk.cursor {
            chunk = chunk + (try await cursor.next(fields))
        }
        return chunk.records
    }

    func readAll<T: RecordDecodable>(matching query: RecordQuery, fields: [String]? = nil) async throws -> [T] {
        try await readAll(matching: query, fields: fields).map(T.init)
    }
}

struct Record: Sendable {
    let recordType: String
    let recordID: String

    var fields: [String: RecordValue] = [:]
    var metadata: Data?

    subscript<T: RecordValueConvertible>(key: String) -> T? {
        get { fields[key].flatMap(T.init(recordValue:)) }
        set { fields[key] = newValue?.recordValue }
    }
}

struct RecordQuery: Sendable {
    let recordType: any RecordDecodable.Type

    var filters: [Filter] = []
    var sort: [Sort] = []

    struct Filter: Codable, Equatable, Sendable {
        enum Operator: String, Codable, Sendable {
            case equals
            case notEquals
            case greaterThan
            case greaterThanOrEquals
            case lessThan
            case lessThanOrEquals
            case `in`
            case notIn
            case beginsWith
            case contains
            case near
            case search
        }

        let field: String
        let op: Operator
        let value: RecordValue
        var radius: Double?
    }

    struct Sort: Codable, Equatable, Sendable {
        let field: String
        let ascending: Bool
    }
}

protocol RecordDecodable: Sendable, Equatable {
    static var recordType: String { get }
    static var desiredKeys: [String] { get }

    init(record: Record) throws
}

struct RecordCursor: Sendable {
    let next: @Sendable ([String]?) async throws -> RecordChunk
}

struct RecordChunk {
    let records: [Record]
    let cursor: RecordCursor?

    static func + (lhs: Self, rhs: Self) -> Self {
        RecordChunk(records: lhs.records + rhs.records, cursor: rhs.cursor)
    }
}

/// Thrown when a write loses a compare-and-swap race; carries the winning record.
public struct RecordConflictError: LocalizedError {
    let serverRecord: Record

    public let errorDescription: String? = "The record was changed on the server"
}
