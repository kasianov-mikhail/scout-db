//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

extension QueryBuilder {
    /// Returns one keyset page ordered by the builder's sort clause.
    ///
    /// Requires exactly one `sort(_:_:)` clause on a slot-backed scalar field;
    /// disjunctions are honored.
    ///
    /// ```swift
    /// let first = try await store.query("purchase").sort("amount").page(size: 50)
    /// let next = try await store.query("purchase").sort("amount").page(size: 50, after: first.cursor)
    /// ```
    ///
    public func page(size: Int, after cursor: FieldCursor? = nil) async throws -> FieldPage {
        guard sorts.count == 1, let sort = sorts.first else {
            throw SchemaError.unsupportedQuery(.singleSortRequired)
        }

        let definition = try await store.registry.definition(for: entity)

        guard let target = definition.fieldsByName(at: definition.version)[sort.field] else {
            throw SchemaError.unknownField(sort.field)
        }
        guard [.string, .int, .double, .timestamp].contains(target.type) else {
            throw SchemaError.unsupportedQuery(.unpageableField(sort.field))
        }
        guard case .slot = target.storage else {
            throw SchemaError.unsupportedQuery(.unpageableField(sort.field))
        }

        return try await PageOperation(
            database: store.database,
            entity: entity,
            field: sort.field,
            descending: !sort.ascending,
            limit: size,
            cursor: cursor,
            definition: definition
        )
        .page(any: alternatives)
    }
}

public struct FieldPage: Equatable, Sendable {
    public let records: [EntityRecord]
    public let cursor: FieldCursor?
}

public struct FieldCursor: Codable, Equatable, Sendable {
    public let value: RecordValue
    public let uuid: String

    public init(value: RecordValue, uuid: String) {
        self.value = value
        self.uuid = uuid
    }
}
