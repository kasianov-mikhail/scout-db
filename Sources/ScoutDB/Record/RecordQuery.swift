//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct RecordQuery: Sendable {
    public let recordType: any RecordDecodable.Type

    public var filters: [Filter] = []
    public var sort: [Sort] = []

    public init(recordType: any RecordDecodable.Type, filters: [Filter] = [], sort: [Sort] = []) {
        self.recordType = recordType
        self.filters = filters
        self.sort = sort
    }

    public struct Filter: Codable, Equatable, Sendable {
        public enum Operator: String, Codable, Sendable {
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

        public let field: String
        public let op: Operator
        public let value: RecordValue
        public var radius: Double?

        public init(field: String, op: Operator, value: RecordValue, radius: Double? = nil) {
            self.field = field
            self.op = op
            self.value = value
            self.radius = radius
        }
    }

    public struct Sort: Codable, Equatable, Sendable {
        public let field: String
        public let ascending: Bool

        public init(field: String, ascending: Bool = true) {
            self.field = field
            self.ascending = ascending
        }
    }
}

public protocol RecordDecodable: Sendable, Equatable {
    static var recordType: String { get }
    static var sampleRecords: [Record] { get }
    static var desiredKeys: [String] { get }

    init(record: Record) throws
}
