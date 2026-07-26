//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension Notification.Name {
    /// Posted after a store mutation lands; carries the entity name and the
    /// database's identity so observers of other stores stay quiet.
    public static let scoutDBEntityDidChange = Notification.Name("ScoutDBEntityDidChange")
}

extension EntityStore {
    func noteChange(entity: String) {
        NotificationCenter.default.post(
            name: .scoutDBEntityDidChange, object: nil,
            userInfo: ["entity": entity, "database": ObjectIdentifier(database as AnyObject)])
    }

    /// One tick per landed local mutation of the entity, from this store's database.
    ///
    /// The observer registers before the stream is returned, so a mutation
    /// after `changeTicks` cannot slip by. Every tick is kept until it is
    /// consumed, so a slow consumer walks the whole burst rather than its tail.
    ///
    public func changeTicks(entity: String) -> AsyncStream<Void> {
        changeTicks(entity: entity, buffering: .unbounded)
    }

    func changeTicks(entity: String, buffering: AsyncStream<Void>.Continuation.BufferingPolicy) -> AsyncStream<Void> {
        final class Token: @unchecked Sendable {
            let observer: any NSObjectProtocol
            init(_ observer: any NSObjectProtocol) { self.observer = observer }
        }
        let database = ObjectIdentifier(self.database as AnyObject)
        return AsyncStream(bufferingPolicy: buffering) { continuation in
            let token = Token(
                NotificationCenter.default.addObserver(forName: .scoutDBEntityDidChange, object: nil, queue: nil) { notification in
                    guard notification.userInfo?["entity"] as? String == entity,
                        notification.userInfo?["database"] as? ObjectIdentifier == database
                    else { return }
                    continuation.yield(())
                })
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.observer) }
        }
    }

    /// Re-runs the query on every local mutation of the entity, yielding fresh
    /// results; the first element is the current result.
    ///
    /// Mutations coalesce: the ones landing while a pass runs share the single
    /// trailing pass that follows it, so a write loop costs the pass in flight
    /// and one that picks up everything the loop changed — not one full,
    /// paged pass per write. Only mutations through this process's stores tick
    /// the stream — remote edits arrive when a `SyncCoordinator` pass applies
    /// them.
    ///
    public func observe(entity: String, filters: [Filter] = [], sort: [Sort] = []) -> AsyncThrowingStream<[EntityRecord], any Error> {
        liveResults(ticks: changeTicks(entity: entity, buffering: .bufferingNewest(1))) {
            try await read(entity: entity, filters: filters, sort: sort)
        }
    }
}

extension QueryBuilder {
    /// Re-runs the built query on every local mutation of the entity — filters,
    /// groups, sorts, and limits included.
    ///
    /// Mutations landing while a pass runs coalesce into one trailing pass; see
    /// ``EntityStore/observe(entity:filters:sort:)``.
    ///
    public func observe() -> AsyncThrowingStream<[EntityRecord], any Error> {
        liveResults(ticks: store.changeTicks(entity: entity, buffering: .bufferingNewest(1))) {
            try await all()
        }
    }
}

/// Yields the current result, then one fresh result per tick, running at most
/// one pass at a time: ticks arriving during a pass collapse into the single
/// pass that follows it.
func liveResults(
    ticks: AsyncStream<Void>, pass: @escaping @Sendable () async throws -> [EntityRecord]
) -> AsyncThrowingStream<[EntityRecord], any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                continuation.yield(try await pass())
                for await _ in ticks {
                    continuation.yield(try await pass())
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
