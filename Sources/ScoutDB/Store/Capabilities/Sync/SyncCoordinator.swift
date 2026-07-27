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
    private let projections: [SyncProjection]?
    private let batchSize: Int?
    private let onProgress: (@Sendable (Int) -> Void)?
    private let onError: (@Sendable (any Error) -> Void)?
    private let lock = NSLock()
    private var token: Data?
    private var inFlight: Task<ZoneDelta, any Error>?
    private var trailing: Task<ZoneDelta, any Error>?
    private var runner: Task<Void, Never>?
    private var generation = 0

    /// With `projecting`, every pass pulls only the projected fields — see
    /// `EntityStore.zoneChanges(since:projecting:)` for the trade-offs.
    ///
    /// With a `batchSize`, every pass walks the feed in batches instead of one
    /// silent pull: the token advances and live queries tick per batch — a
    /// killed initial sync resumes mid-feed — and `onProgress` reports the
    /// running change count after each batch. The feed's total is unknowable
    /// up front, so progress is a count, not a fraction.
    ///
    /// `onError` receives the failures nobody else sees: a flush that
    /// conflicted during a pass (`OfflineFlushError` — the pass itself
    /// proceeds), and a periodic pass that failed between `start()` ticks.
    /// Errors of a `sync()` you awaited yourself still throw to you directly.
    ///
    public init(
        store: EntityStore, cache: OfflineCache? = nil, tokenURL: URL? = nil, projecting projections: [SyncProjection]? = nil,
        batchSize: Int? = nil, onProgress: (@Sendable (Int) -> Void)? = nil, onError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.store = store
        self.cache = cache
        self.tokenURL = tokenURL
        self.projections = projections
        self.batchSize = batchSize
        self.onProgress = onProgress
        self.onError = onError
        if let tokenURL {
            token = try? Data(contentsOf: tokenURL)
        }
    }

    deinit {
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
            do {
                _ = try await cache.flush()
            } catch {
                onError?(error)
            }
        }
        let (since, generation) = lock.withLock { (token, self.generation) }
        if let batchSize {
            return try await batchedPass(since: since, batchSize: batchSize, generation: generation)
        }
        let delta: ZoneDelta
        if let projections {
            delta = try await store.zoneChanges(since: since, projecting: projections)
        } else {
            delta = try await store.zoneChanges(since: since)
        }
        apply(delta, generation: generation)
        return delta
    }

    private func batchedPass(since: Data?, batchSize: Int, generation: Int) async throws -> ZoneDelta {
        var records: [EntityRecord] = []
        var deleted: [String] = []
        var last = since
        for try await batch in store.zoneChanges(since: since, batchSize: batchSize, projecting: projections) {
            apply(batch, generation: generation)
            records += batch.records
            deleted += batch.deleted
            last = batch.token ?? last
            onProgress?(records.count + deleted.count)
        }
        return ZoneDelta(records: records, deleted: deleted, token: last)
    }

    private func apply(_ delta: ZoneDelta, generation: Int) {
        let persist: Data? = lock.withLock {
            guard generation == self.generation else { return nil }
            token = delta.token ?? token
            return token
        }
        if let tokenURL, let persist {
            try? persist.write(to: tokenURL, options: .atomic)
        }
        let byEntity = Dictionary(grouping: delta.records, by: \.entity)
        for (entity, records) in byEntity {
            // A projected pass carries partial records, which a live query
            // cannot fold into a result of whole ones.
            store.noteChange(entity: entity, changed: projections == nil ? records : nil)
        }
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
    /// failed pass waits for the next tick and reports to `onError` instead of
    /// surfacing. Deltas that carry changes are handed to `onDelta`. Live
    /// queries tick regardless, so observing stores refresh without it.
    /// Calling `start` on a running coordinator is a no-op; pair with `stop()`.
    ///
    public func start(every interval: Duration = .seconds(300), onDelta: (@Sendable (ZoneDelta) -> Void)? = nil) {
        lock.withLock {
            guard runner == nil else { return }
            runner = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        if let delta = try await self?.sync(), delta.records.count + delta.deleted.count > 0 {
                            onDelta?(delta)
                        }
                    } catch {
                        self?.onError?(error)
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
            generation += 1
            if let tokenURL {
                try? FileManager.default.removeItem(at: tokenURL)
            }
        }
    }
}
