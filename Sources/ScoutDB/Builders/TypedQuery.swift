//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// A typed façade over one entity — the shape `scoutdb-codegen` generates.
public protocol EntityRepresentable {
    static var entityName: String { get }
    /// The schema field behind a stored property's key path, nil for key paths
    /// outside the schema.
    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String?

    init(record: EntityRecord)
    var recordValues: [String: RecordValue] { get }
}

/// One key-path predicate, built with the operator sugar: `\Purchase.quantity > 2`.
public struct TypedFilter<T: EntityRepresentable> {
    let keyPath: PartialKeyPath<T>
    let op: EntityStore.Match
    let value: RecordValue

    func filter() throws -> EntityStore.Filter {
        guard let field = T.fieldName(for: keyPath) else {
            throw SchemaError.unknownField(String(describing: keyPath))
        }
        return EntityStore.Filter(field: field, op: op, value: value)
    }
}

public func == <T, V: RecordValueConvertible>(keyPath: KeyPath<T, V?>, value: V) -> TypedFilter<T> {
    TypedFilter(keyPath: keyPath, op: .equals, value: value.recordValue)
}

public func != <T, V: RecordValueConvertible>(keyPath: KeyPath<T, V?>, value: V) -> TypedFilter<T> {
    TypedFilter(keyPath: keyPath, op: .notEquals, value: value.recordValue)
}

public func > <T, V: RecordValueConvertible>(keyPath: KeyPath<T, V?>, value: V) -> TypedFilter<T> {
    TypedFilter(keyPath: keyPath, op: .greaterThan, value: value.recordValue)
}

public func >= <T, V: RecordValueConvertible>(keyPath: KeyPath<T, V?>, value: V) -> TypedFilter<T> {
    TypedFilter(keyPath: keyPath, op: .greaterThanOrEquals, value: value.recordValue)
}

public func < <T, V: RecordValueConvertible>(keyPath: KeyPath<T, V?>, value: V) -> TypedFilter<T> {
    TypedFilter(keyPath: keyPath, op: .lessThan, value: value.recordValue)
}

public func <= <T, V: RecordValueConvertible>(keyPath: KeyPath<T, V?>, value: V) -> TypedFilter<T> {
    TypedFilter(keyPath: keyPath, op: .lessThanOrEquals, value: value.recordValue)
}

/// A chainable typed query; every terminal returns the entity struct, not records.
public struct TypedQueryBuilder<T: EntityRepresentable> {
    private var builder: QueryBuilder

    init(builder: QueryBuilder) {
        self.builder = builder
    }

    /// Adds a key-path filter: `.filter(\.quantity > 2)`.
    public func filter(_ predicate: TypedFilter<T>) throws -> Self {
        TypedQueryBuilder(builder: builder.filter(try predicate.filter()))
    }

    /// Excludes the records matching the key-path predicate.
    public func exclude(_ predicate: TypedFilter<T>) throws -> Self {
        TypedQueryBuilder(builder: builder.exclude(try predicate.filter()))
    }

    /// Adds a sort clause by key path.
    public func sort(_ keyPath: PartialKeyPath<T>, _ direction: QueryBuilder.Direction = .ascending) throws -> Self {
        guard let field = T.fieldName(for: keyPath) else {
            throw SchemaError.unknownField(String(describing: keyPath))
        }
        return TypedQueryBuilder(builder: builder.sort(field, direction))
    }

    /// Caps the number of returned values.
    public func limit(_ count: Int) -> Self {
        TypedQueryBuilder(builder: builder.limit(count))
    }

    /// Keeps only the records a given user created — the public-database
    /// pattern, scoped server-side.
    public func createdBy(_ user: String) -> Self {
        TypedQueryBuilder(builder: builder.createdBy(user))
    }

    /// Runs the query and decodes every matching record into the entity struct.
    public func all() async throws -> [T] {
        try await builder.all().map(T.init(record:))
    }

    /// Runs the query and decodes the first matching record.
    public func first() async throws -> T? {
        try await builder.first().map(T.init(record:))
    }

    /// The number of matching records.
    public func count() async throws -> Int {
        try await builder.count()
    }

    /// Returns one keyset page in envelope-date order.
    ///
    /// Like the untyped `paginate`, it cannot honor sort clauses and throws
    /// when one was added.
    ///
    public func paginate(size: Int, after cursor: EntityCursor? = nil) async throws -> TypedPage<T> {
        let page = try await builder.paginate(size: size, after: cursor)
        return TypedPage(items: page.records.map(T.init(record:)), cursor: page.cursor)
    }

    /// Returns one keyset page ordered by the builder's single sort clause.
    public func page(size: Int, after cursor: FieldCursor? = nil) async throws -> TypedFieldPage<T> {
        let page = try await builder.page(size: size, after: cursor)
        return TypedFieldPage(items: page.records.map(T.init(record:)), cursor: page.cursor)
    }
}

// The streaming terminals hand decoded values across task boundaries, which
// only a Sendable entity struct can do; the structs codegen emits qualify.
extension TypedQueryBuilder where T: Sendable {
    /// Streams every matching value page by page.
    public func stream(pageSize: Int = 100) -> AsyncThrowingStream<T, any Error> {
        let base = builder.stream(pageSize: pageSize)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await record in base {
                        continuation.yield(T(record: record))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Re-runs the query on every local mutation of the entity, yielding fresh
    /// decoded results; the first element is the current result.
    public func observe() -> AsyncThrowingStream<[T], any Error> {
        let base = builder.observe()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await records in base {
                        continuation.yield(records.map(T.init(record:)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One keyset page of decoded values in envelope-date order.
public struct TypedPage<T: EntityRepresentable> {
    public let items: [T]
    public let cursor: EntityCursor?
}

/// One keyset page of decoded values in field order.
public struct TypedFieldPage<T: EntityRepresentable> {
    public let items: [T]
    public let cursor: FieldCursor?
}

extension EntityStore {
    /// Opens a typed query on an entity's generated struct.
    public func query<T: EntityRepresentable>(_ type: T.Type) -> TypedQueryBuilder<T> {
        TypedQueryBuilder(builder: query(T.entityName))
    }
}
