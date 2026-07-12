//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// The lease on a record: who holds it and until when.
    public struct Lease: Equatable, Sendable {
        public let owner: String
        public let until: Date
    }

    /// Claims the record for `duration` on behalf of `owner`.
    ///
    /// A live lease held by someone else throws `leaseHeld`; an expired lease —
    /// or the owner's own — is taken over, so renewing is just leasing again.
    /// The claim saves under CAS, so two racers cannot both win. Leases are
    /// advisory: they gate cooperating callers ("one editor at a time"), not the
    /// store's own writes. Returns the granted lease.
    ///
    @discardableResult public func lease(entity: String, uuid: String, owner: String, for duration: TimeInterval, maxRetry: Int = 3) async throws -> Lease {
        var attempt = 0
        var stored = try await items(entity: entity, uuids: [uuid]).first
        while true {
            guard let record = stored else {
                throw SchemaError.notFound(uuid)
            }
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
                stored = conflict.serverRecord
            }
        }
    }

    /// Releases the owner's lease; someone else's lease stays put.
    public func release(entity: String, uuid: String, owner: String) async throws {
        guard let record = try await items(entity: entity, uuids: [uuid]).first else {
            throw SchemaError.notFound(uuid)
        }
        guard record["lease_owner"] as? String == owner else { return }
        record["lease_owner"] = nil
        record["lease_until"] = nil
        try await database.write(record: record)
    }

    /// The record's live lease, or nil when it is free or the lease expired.
    public func leaseHolder(entity: String, uuid: String) async throws -> Lease? {
        guard let record = try await items(entity: entity, uuids: [uuid]).first else {
            throw SchemaError.notFound(uuid)
        }
        guard let owner = record["lease_owner"] as? String, let until = record["lease_until"] as? Date, until > Date() else {
            return nil
        }
        return Lease(owner: owner, until: until)
    }
}
