//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// What a decoded conflict policy decided about one conflicted queued write.
public enum EntityConflictResolution {
    /// Save this record instead — typically a custom merge of the two sides.
    case save(EntityRecord)
    /// Keep the server copy; the queued write is dropped as landed.
    case keepServer
    /// Give up: surface the conflict in `OfflineFlushError`.
    case surface
}

extension EntityStore {
    /// Wraps a field-level conflict policy as the raw resolver an
    /// `OfflineCache` takes.
    ///
    /// The raw `ConflictResolver` hands out CKRecords keyed by storage slots;
    /// this one decodes both sides (and the merge-base `ancestor`, when the
    /// cache still holds one) through the store's schema, so the policy reads
    /// and writes real field names:
    ///
    /// ```swift
    /// cache.setConflictResolver(store.conflictResolver { queued, server, _ in
    ///     var merged = server
    ///     merged["quantity"] = max(queued["quantity"] ?? 0, server["quantity"] ?? 0) as Int64
    ///     return .save(merged)
    /// })
    /// ```
    ///
    /// A returned `.save` is encoded back into the server copy through the
    /// rewrite path, so encrypted payloads and fields the policy left alone
    /// carry over. Records that fail to decode — retired entities, foreign
    /// record types — surface as conflicts, never a blind overwrite.
    ///
    public func conflictResolver(
        _ resolve: @escaping @Sendable (_ queued: EntityRecord, _ server: EntityRecord, _ ancestor: EntityRecord?) -> EntityConflictResolution
    ) -> any ConflictResolver {
        DecodedConflictResolver(store: self, policy: resolve)
    }
}

private struct DecodedConflictResolver: ConflictResolver {
    let store: EntityStore
    let policy: @Sendable (EntityRecord, EntityRecord, EntityRecord?) -> EntityConflictResolution

    func resolve(queued: CKRecord, server: CKRecord, ancestor: CKRecord?) async -> ConflictResolution {
        guard queued.recordType == Entity.recordType, let entity = queued["entity"] as? String,
            let definition = try? await store.registry.definition(for: entity)
        else { return .surface }
        let coder = EntityCoder(keyProvider: store.keyProvider)
        guard let decodedQueued = try? coder.decode(queued, using: definition),
            let decodedServer = try? coder.decode(server, using: definition)
        else { return .surface }
        let decodedAncestor = ancestor.flatMap { try? coder.decode($0, using: definition) }

        switch policy(decodedQueued, decodedServer, decodedAncestor) {
        case .keepServer:
            return .keepServer
        case .surface:
            return .surface
        case .save(let resolved):
            let base = server.duplicate()
            guard
                let rewrite = try? coder.rewrite(
                    base, using: definition,
                    transform: { record in
                        record.values = resolved.values
                        record.deleted = resolved.deleted
                    })
            else { return .surface }
            return .save(rewrite.record)
        }
    }
}
