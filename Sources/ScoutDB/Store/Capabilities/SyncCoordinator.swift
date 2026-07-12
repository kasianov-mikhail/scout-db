//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// Drives the sync loop the primitives leave to the app: push in, delta out.
///
/// One coordinator per zoned store. It keeps the zone change token (persisted
/// across launches when a `tokenURL` is given), replays the offline queue
/// before every pull, and hands back the decoded delta for the app to apply.
///
public final class SyncCoordinator: @unchecked Sendable {
    private let store: EntityStore
    private let cache: OfflineCache?
    private let tokenURL: URL?
    private let lock = NSLock()
    private var token: Data?

    public init(store: EntityStore, cache: OfflineCache? = nil, tokenURL: URL? = nil) {
        self.store = store
        self.cache = cache
        self.tokenURL = tokenURL
        if let tokenURL {
            token = try? Data(contentsOf: tokenURL)
        }
    }

    /// Handles a remote notification: a CloudKit push triggers one sync pass.
    ///
    /// Returns nil for payloads that are not CloudKit notifications, so the app
    /// can route foreign pushes elsewhere.
    ///
    @discardableResult public func handlePush(_ userInfo: [AnyHashable: Any]) async throws -> ZoneDelta? {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return nil }
        return try await sync()
    }

    /// One sync pass: replay the offline queue, pull the zone delta, advance
    /// the token.
    ///
    /// A flush that fails (still offline) is not fatal — the pull proceeds and
    /// the queue waits for the next pass.
    ///
    @discardableResult public func sync() async throws -> ZoneDelta {
        if let cache {
            _ = try? await cache.flush()
        }
        let delta = try await store.zoneChanges(since: lock.withLock { token })
        lock.withLock {
            token = delta.token ?? token
            if let tokenURL, let token {
                try? token.write(to: tokenURL, options: .atomic)
            }
        }
        // Applied remote changes tick this process's live queries too.
        for entity in Set(delta.records.map(\.entity)) {
            store.noteChange(entity: entity)
        }
        return delta
    }

    /// Forgets the token; the next sync replays the zone from the beginning.
    public func reset() {
        lock.withLock {
            token = nil
            if let tokenURL {
                try? FileManager.default.removeItem(at: tokenURL)
            }
        }
    }
}
