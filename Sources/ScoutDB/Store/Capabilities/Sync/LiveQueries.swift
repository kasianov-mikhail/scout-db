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
    // Announces a landed mutation so live queries over this database re-run.
    func noteChange(entity: String) {
        NotificationCenter.default.post(
            name: .scoutDBEntityDidChange, object: nil,
            userInfo: ["entity": entity, "database": ObjectIdentifier(database as AnyObject)])
    }

    /// One tick per landed local mutation of the entity, from this store's database.
    ///
    /// The observer registers before the stream is returned, so a mutation
    /// after `changeTicks` cannot slip by.
    ///
    public func changeTicks(entity: String) -> AsyncStream<Void> {
        // The observation token is immutable and only ever handed back to the
        // notification center; the box just carries it across the Sendable line.
        final class Token: @unchecked Sendable {
            let observer: any NSObjectProtocol
            init(_ observer: any NSObjectProtocol) { self.observer = observer }
        }
        let database = ObjectIdentifier(self.database as AnyObject)
        return AsyncStream { continuation in
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
    /// Only mutations through this process's stores tick the stream — remote
    /// edits arrive when a `SyncCoordinator` pass applies them.
    ///
    public func observe(entity: String, filters: [Filter] = [], sort: [Sort] = []) -> AsyncThrowingStream<[EntityRecord], any Error> {
        let ticks = changeTicks(entity: entity)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await read(entity: entity, filters: filters, sort: sort))
                    for await _ in ticks {
                        continuation.yield(try await read(entity: entity, filters: filters, sort: sort))
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

extension QueryBuilder {
    /// Re-runs the built query on every local mutation of the entity — filters,
    /// groups, sorts, and limits included.
    public func observe() -> AsyncThrowingStream<[EntityRecord], any Error> {
        let ticks = store.changeTicks(entity: entity)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await all())
                    for await _ in ticks {
                        continuation.yield(try await all())
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
