//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

/// Derives `EntityRepresentable` from a struct's stored properties.
///
/// ```swift
/// @Entity("purchase")
/// struct Purchase {
///     var productId: String?   // maps to "product_id"
///     var quantity: Int64?
///     @Field("amount") var price: Double?
///     @Transient var badge: String?
/// }
/// ```
///
/// Every stored property must be optional — a record is free to miss any
/// field — and maps to its snake_cased name unless `@Field` names the schema
/// field explicitly; `@Transient` keeps a property out entirely. Without an
/// argument the entity name is the snake_cased type name. The macro is the
/// Swift-first counterpart of `scoutdb-codegen`, which generates the same
/// conformance from a published schema.
///
@attached(extension, conformances: EntityRepresentable, names: named(entityName), named(fieldName(for:)), named(init(record:)), named(recordValues))
public macro Entity(_ name: String? = nil) = #externalMacro(module: "ScoutDBMacros", type: "EntityMacro")

/// Names the schema field behind a stored property in an `@Entity` struct
/// when the snake_cased property name is not it.
@attached(peer)
public macro Field(_ name: String) = #externalMacro(module: "ScoutDBMacros", type: "FieldMacro")

/// Keeps a stored property out of an `@Entity` struct's derived conformance.
@attached(peer)
public macro Transient() = #externalMacro(module: "ScoutDBMacros", type: "TransientMacro")
