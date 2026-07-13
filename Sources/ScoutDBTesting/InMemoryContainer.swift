//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

/// The container double: three in-memory databases and a settable account.
public final class InMemoryContainer: CloudContainer, @unchecked Sendable {
    public let privateDatabase: any CloudDatabase
    public let publicDatabase: any CloudDatabase
    public let sharedDatabase: any CloudDatabase

    private let lock = NSLock()
    private var status: CKAccountStatus
    private var observers: [UUID: AsyncStream<CKAccountStatus>.Continuation] = [:]

    public init(status: CKAccountStatus = .available) {
        self.status = status
        privateDatabase = InMemoryDatabase()
        publicDatabase = InMemoryDatabase()
        sharedDatabase = InMemoryDatabase()
    }

    public func accountStatus() async throws -> CKAccountStatus {
        lock.withLock { status }
    }

    /// Simulates a sign-in, sign-out, or account switch: every updates stream
    /// sees the new status.
    public func setAccountStatus(_ status: CKAccountStatus) {
        let continuations = lock.withLock {
            self.status = status
            return Array(observers.values)
        }
        for continuation in continuations {
            continuation.yield(status)
        }
    }

    public func accountStatusUpdates() -> AsyncStream<CKAccountStatus> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { observers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.observers.removeValue(forKey: id) }
            }
        }
    }
}
