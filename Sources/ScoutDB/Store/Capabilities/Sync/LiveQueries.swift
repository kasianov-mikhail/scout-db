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

/// The records a burst of mutations changed, gathered for the live pass that
/// follows it.
///
/// Ticks coalesce, so a buffer rather than the stream's own backlog: two writes
/// landing during one pass collapse into a single tick, and the second must not
/// drop the first one's records. A mutation that cannot name what it changed
/// clears the buffer to nil, which asks the next pass to read the query again.
///
final class ChangeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [EntityRecord] = []
    private var unknown = false

    func note(_ records: [EntityRecord]?) {
        lock.withLock {
            guard let records else { return unknown = true }
            pending += records
        }
    }

    func take() -> [EntityRecord]? {
        lock.withLock {
            defer {
                pending = []
                unknown = false
            }
            return unknown ? nil : pending
        }
    }
}

extension EntityStore {
    func noteChange(entity: String, changed: [EntityRecord]? = nil) {
        var userInfo: [String: Any] = ["entity": entity, "database": ObjectIdentifier(database as AnyObject)]
        if let changed {
            userInfo["changed"] = changed
        }
        NotificationCenter.default.post(name: .scoutDBEntityDidChange, object: nil, userInfo: userInfo)
    }

    /// The record as a live query sees it once its tombstone lands.
    static func tombstoned(_ record: EntityRecord) -> EntityRecord {
        var tombstone = record
        tombstone.deleted = true
        return tombstone
    }

    /// Folds the records a mutation changed into a live query's last result,
    /// or nil when the query's shape rules that out.
    ///
    /// A record is re-tested against every filter — the ones the server ran as
    /// well as the ones it could not — and joins, updates, or leaves the result
    /// accordingly. A `near` filter has no client-side matcher and a distance
    /// sort no client-side order, so either sends the pass back to the server.
    ///
    func splice(_ current: [EntityRecord], with changed: [EntityRecord], entity: String, filters: [Filter], sort: [Sort]) -> [EntityRecord]? {
        guard filters.allSatisfy({ $0.radius == nil }), sort.allSatisfy({ $0.origin == nil }) else { return nil }
        let matchers: [(EntityRecord) -> Bool]
        do {
            matchers = try filters.map { filter -> (EntityRecord) -> Bool in
                let base = try Self.matcher(for: filter)
                return filter.negated ? { !base($0) } : base
            }
        } catch {
            return nil
        }

        var order = current.map(\.uuid)
        var byID = Dictionary(current.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        for record in changed where record.entity == entity {
            if !record.deleted, matchers.allSatisfy({ $0(record) }) {
                if byID.updateValue(record, forKey: record.uuid) == nil {
                    order.append(record.uuid)
                }
            } else if byID.removeValue(forKey: record.uuid) != nil {
                order.removeAll { $0 == record.uuid }
            }
        }
        let merged = order.compactMap { byID[$0] }
        guard sort.count > 0 else { return merged }
        return merged.sorted { Self.ordered($0, $1, by: sort) }
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

    func changeTicks(entity: String, buffering: AsyncStream<Void>.Continuation.BufferingPolicy, into buffer: ChangeBuffer? = nil) -> AsyncStream<Void> {
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
                    buffer?.note(notification.userInfo?["changed"] as? [EntityRecord])
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
    /// the stream; an edit made on another device is picked up by the next pass
    /// the app runs, not by this one.
    ///
    /// A mutation that names the records it changed is folded into the last
    /// result rather than re-read, so the stream costs the query once and the
    /// changes after it. A mutation that cannot — a compaction, say — sends the
    /// next result back to the server.
    ///
    public func observe(entity: String, filters: [Filter] = [], sort: [Sort] = []) -> AsyncThrowingStream<[EntityRecord], any Error> {
        let buffer = ChangeBuffer()
        return liveResults(
            ticks: changeTicks(entity: entity, buffering: .bufferingNewest(1), into: buffer), buffer: buffer,
            splice: { current, changed in splice(current, with: changed, entity: entity, filters: filters, sort: sort) }
        ) {
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
        let buffer = ChangeBuffer()
        let store = store
        let entity = entity
        var splice: (@Sendable ([EntityRecord], [EntityRecord]) -> [EntityRecord]?)?
        if let shape = spliceable {
            splice = { current, changed in
                store.splice(current, with: changed, entity: entity, filters: shape.filters, sort: shape.sort)
            }
        }
        return liveResults(
            ticks: store.changeTicks(entity: entity, buffering: .bufferingNewest(1), into: buffer), buffer: buffer, splice: splice
        ) {
            try await records(limit: bound)
        }
    }
}

/// Yields the current result, then one fresh result per tick, running at most
/// one pass at a time: ticks arriving during a pass collapse into the single
/// pass that follows it.
///
/// A tick whose changes are known folds them into the last result through
/// `splice` instead of running the pass again; anything else — no buffer, a
/// change of unknown shape, a query `splice` declines — runs the pass.
///
func liveResults(
    ticks: AsyncStream<Void>, buffer: ChangeBuffer? = nil, splice: (@Sendable ([EntityRecord], [EntityRecord]) -> [EntityRecord]?)? = nil,
    pass: @escaping @Sendable () async throws -> [EntityRecord]
) -> AsyncThrowingStream<[EntityRecord], any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var current = try await pass()
                continuation.yield(current)
                for await _ in ticks {
                    let changed = buffer?.take()
                    if let splice, let changed, let merged = splice(current, changed) {
                        current = merged
                    } else {
                        current = try await pass()
                    }
                    continuation.yield(current)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
