//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

extension EntityStore {
    /// The lease on a record: who holds it and until when.
    public struct Lease: Equatable, Sendable {
        public let owner: String
        public let until: Date
    }

    @discardableResult public func lease(entity: String, uuid: String, owner: String, for duration: TimeInterval, maxRetry: Int = 3) async throws -> Lease {
        var attempt = 0
        var record = try await liveItem(entity: entity, uuid: uuid)
        while true {
            if let holder = record["lease_owner"] as? String, holder != owner, let until = record["lease_until"] as? Date, until > Date() {
                throw SchemaError.leaseHeld(owner: holder, until: until)
            }
            let lease = Lease(owner: owner, until: Date().addingTimeInterval(duration))
            record["lease_owner"] = lease.owner
            record["lease_until"] = lease.until
            do {
                try await database.write(record: record)
                return lease
            } catch let conflict as RecordConflictError {
                attempt += 1
                guard attempt < maxRetry else { throw conflict }
                record = conflict.serverRecord
            }
        }
    }

    /// Releases the owner's lease; someone else's lease stays put.
    public func release(entity: String, uuid: String, owner: String) async throws {
        let record = try await liveItem(entity: entity, uuid: uuid)
        guard record["lease_owner"] as? String == owner else { return }
        record["lease_owner"] = nil
        record["lease_until"] = nil
        try await database.write(record: record)
    }

    /// The record's live lease, or nil when it is free or the lease expired.
    public func leaseHolder(entity: String, uuid: String) async throws -> Lease? {
        let record = try await liveItem(entity: entity, uuid: uuid)
        guard let owner = record["lease_owner"] as? String, let until = record["lease_until"] as? Date, until > Date() else {
            return nil
        }
        return Lease(owner: owner, until: until)
    }

    private func liveItem(entity: String, uuid: String) async throws -> CKRecord {
        guard let record = try await items(entity: entity, uuids: [uuid]).first(where: { !Self.isTombstone($0) }) else {
            throw SchemaError.notFound(uuid)
        }
        return record
    }
}
