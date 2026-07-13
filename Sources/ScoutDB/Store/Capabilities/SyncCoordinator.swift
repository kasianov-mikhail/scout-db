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
    private var inFlight: Task<ZoneDelta, any Error>?
    private var trailing: Task<ZoneDelta, any Error>?
    private var runner: Task<Void, Never>?

    public init(store: EntityStore, cache: OfflineCache? = nil, tokenURL: URL? = nil) {
        self.store = store
        self.cache = cache
        self.tokenURL = tokenURL
        if let tokenURL {
            token = try? Data(contentsOf: tokenURL)
        }
    }

    deinit {
        // The runner holds the coordinator weakly, so it would idle forever
        // after the last strong reference goes away — cancel it instead.
        runner?.cancel()
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
    /// Concurrent calls coalesce: callers arriving while a pass runs all share
    /// one trailing pass that starts when the running one settles, so a push
    /// storm costs at most two passes — the one in flight and one that picks up
    /// everything the storm announced. A flush that fails (still offline) is
    /// not fatal — the pull proceeds and the queue waits for the next pass.
    ///
    @discardableResult public func sync() async throws -> ZoneDelta {
        try await join().value
    }

    // The task this request rides on: the pass just started, or the single
    // trailing pass every arrival during a running pass shares.
    private func join() -> Task<ZoneDelta, any Error> {
        lock.withLock {
            if let current = inFlight {
                if let waiting = trailing { return waiting }
                let next = makePass(after: current)
                trailing = next
                return next
            }
            let task = makePass(after: nil)
            inFlight = task
            return task
        }
    }

    // One queued pass; when it settles, the trailing pass (if a burst created
    // one) is promoted to in-flight so later arrivals chain behind it.
    private func makePass(after previous: Task<ZoneDelta, any Error>?) -> Task<ZoneDelta, any Error> {
        Task {
            if let previous {
                _ = try? await previous.value
            }
            defer {
                lock.withLock {
                    inFlight = trailing
                    trailing = nil
                }
            }
            return try await pass()
        }
    }

    private func pass() async throws -> ZoneDelta {
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

    /// Whether a periodic runner started by `start` is active.
    public var isRunning: Bool {
        lock.withLock { runner != nil }
    }

    /// Keeps the zone synced continuously: one pass now, then one per `interval`,
    /// until `stop()`.
    ///
    /// Silent pushes are best-effort, so the heartbeat bounds staleness when they
    /// are dropped — and doubles as the retry for passes that fail offline; a
    /// failed pass waits for the next tick instead of surfacing. Deltas that
    /// carry changes are handed to `onDelta`. Live queries tick regardless, so
    /// observing stores refresh without it. Calling `start` on a running
    /// coordinator is a no-op; pair with `stop()`.
    ///
    public func start(every interval: Duration = .seconds(300), onDelta: (@Sendable (ZoneDelta) -> Void)? = nil) {
        lock.withLock {
            guard runner == nil else { return }
            runner = Task { [weak self] in
                while !Task.isCancelled {
                    if let delta = try? await self?.sync(), delta.records.count + delta.deleted.count > 0 {
                        onDelta?(delta)
                    }
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                }
            }
        }
    }

    /// Stops the periodic runner; an in-flight pass finishes, no new one starts.
    public func stop() {
        lock.withLock {
            runner?.cancel()
            runner = nil
        }
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
