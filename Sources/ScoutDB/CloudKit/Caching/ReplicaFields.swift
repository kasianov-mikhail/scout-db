//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// The fields one entity contributes to a partial replica.
public struct ReplicaProjection: Sendable {
    public let entity: String
    public let fields: [String]

    public init(entity: String, fields: [String]) {
        self.entity = entity
        self.fields = fields
    }
}

extension EntityStore {
    /// The field-key whitelist a partial `ReplicaCache` needs for the given
    /// projections.
    ///
    /// Resolves each projection's fields to their storage keys and keeps the
    /// record envelope in — without it no store query is answerable locally.
    ///
    public func replicaFields(projecting projections: [ReplicaProjection]) async throws -> [CKRecord.FieldKey] {
        var keys = EntityCoder.envelopeKeys
        for projection in projections {
            let definition = try await registry.definition(for: projection.entity)
            keys += try desiredKeys(projection.fields, using: definition).filter { !keys.contains($0) }
        }
        return keys
    }
}
