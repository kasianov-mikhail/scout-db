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

    /// The identities `lookUpShareParticipants` was asked to resolve, in call order.
    ///
    /// CloudKit does not let tests fabricate `CKShare.Participant` instances, so
    /// the double records the requests and resolves none of them.
    public var lookedUpParticipants: [CKUserIdentity.LookupInfo] {
        lock.withLock { lookups }
    }

    private var lookups: [CKUserIdentity.LookupInfo] = []

    public func lookUpShareParticipants(_ lookupInfos: [CKUserIdentity.LookupInfo]) async throws -> [CKShare.Participant] {
        lock.withLock { lookups.append(contentsOf: lookupInfos) }
        return []
    }

    public func acceptShare(metadata: CKShare.Metadata) async throws {}

    /// The share URLs `shareMetadata(for:)` was asked to resolve, in call order.
    ///
    /// CloudKit does not let tests fabricate `CKShare.Metadata` instances, so
    /// the double records the requests and answers `unknownItem` — inject an
    /// error through `metadataErrors` to exercise failure paths instead.
    public var requestedShareURLs: [URL] {
        lock.withLock { shareURLs }
    }

    /// Errors popped by `shareMetadata(for:)`, newest first.
    public var metadataErrors: [Error] = []

    private var shareURLs: [URL] = []

    public func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        lock.withLock { shareURLs.append(url) }
        if let error = metadataErrors.popLast() {
            throw error
        }
        throw CKError(.unknownItem)
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
