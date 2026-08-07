//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension SchemaBuilder {
    struct Declaration {
        let name: String
        let type: FieldType
        let constraints: [FieldConstraint]

        var wantsSlot: Bool {
            !constraints.contains { if case .payload = $0 { true } else { false } }
        }
    }

    /// Declares a field of the entity.
    ///
    /// The field takes the next free slot for its type, which is what lets the
    /// server filter and sort on it. Sixteen slots exist per type, less the two
    /// the record's envelope keeps — one string and one integer — so fifteen of
    /// each are yours. A `.payload` field spends none of them, at the cost of
    /// every filter over it running on the client after decoding. Declaration
    /// order fixes the slots, so keeping it stable across versions is what
    /// keeps older records readable.
    ///
    /// ```swift
    /// try await store.schema("purchase")
    ///     .field("product_id", .string, .required)
    ///     .field("quantity", .int, .min(1), .max(20))
    ///     .field("comment", .string, .payload)
    ///     .create()
    /// ```
    ///
    public func field(_ name: String, _ type: FieldType, _ constraints: FieldConstraint...) -> Self {
        var builder = self
        builder.declarations.append(Declaration(name: name, type: type, constraints: constraints))
        return builder
    }
}
