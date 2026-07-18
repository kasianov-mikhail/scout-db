//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// The container seam above the database one: account state plus the three
/// databases, so app code and tests can share the same entry point.
///
/// Every CloudKit call fails opaquely when no iCloud account is signed in —
/// check `accountStatus()` (or `requireAccount()`) before the first store
/// operation, and watch `accountStatusUpdates()` to react when the user signs
/// in, out, or switches accounts mid-flight.
///
public protocol CloudContainer: Sendable {
    /// The current iCloud account state.
    func accountStatus() async throws -> CKAccountStatus

    /// Emits the fresh status after every account change.
    func accountStatusUpdates() -> AsyncStream<CKAccountStatus>

    /// Resolves user identities (emails, phone numbers) into share participants.
    func lookUpShareParticipants(_ lookupInfos: [CKUserIdentity.LookupInfo]) async throws -> [CKShare.Participant]

    /// Accepts a share invitation on behalf of the current user.
    ///
    /// The metadata arrives through the system acceptance flow — the
    /// `userDidAcceptCloudKitShareWith` scene callback or
    /// `CKFetchShareMetadataOperation` on a share URL.
    ///
    func acceptShare(metadata: CKShare.Metadata) async throws

    /// The metadata behind a share URL — the share, its owner, and whether
    /// the current user already participates.
    ///
    /// The missing link when an invitation arrives outside the system flow —
    /// a pasted link, a QR code: fetch the metadata here, then
    /// `acceptShare(metadata:)`, or take both steps with `acceptShare(at:)`.
    ///
    func shareMetadata(for url: URL) async throws -> CKShare.Metadata

    var privateDatabase: any CloudDatabase { get }
    var publicDatabase: any CloudDatabase { get }
    var sharedDatabase: any CloudDatabase { get }
}

extension CloudContainer {
    /// Accepts a share straight from its URL: fetches the metadata, accepts it.
    ///
    /// Returns the metadata so the app can route to what it just joined —
    /// build a store over the shared database scoped to
    /// `metadata.share.recordID.zoneID`.
    ///
    @discardableResult public func acceptShare(at url: URL) async throws -> CKShare.Metadata {
        let metadata = try await shareMetadata(for: url)
        try await acceptShare(metadata: metadata)
        return metadata
    }

    /// Passes only with a usable account; throws `AccountUnavailableError`
    /// carrying the actual status otherwise.
    public func requireAccount() async throws {
        let status = try await accountStatus()
        guard status == .available else {
            throw AccountUnavailableError(status: status)
        }
    }
}

/// The iCloud account cannot back a store right now — signed out, restricted,
/// or still resolving.
public struct AccountUnavailableError: LocalizedError {
    public let status: CKAccountStatus

    public init(status: CKAccountStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        "iCloud account unavailable (status \(status.rawValue))"
    }
}

// The conformance bodies must not spell a call matching a requirement's own
// signature — within this module it would resolve back to the conformance
// itself (see the CloudDatabase conformance for the full story). CKContainer's
// own `accountStatus()` *is* the requirement, so it satisfies it directly.
extension CKContainer: CloudContainer {
    public var privateDatabase: any CloudDatabase {
        privateCloudDatabase
    }

    public var publicDatabase: any CloudDatabase {
        publicCloudDatabase
    }

    public var sharedDatabase: any CloudDatabase {
        sharedCloudDatabase
    }

    public func lookUpShareParticipants(_ lookupInfos: [CKUserIdentity.LookupInfo]) async throws -> [CKShare.Participant] {
        guard lookupInfos.count > 0 else { return [] }
        // The operation reports through callbacks on its own queue, one at a
        // time; the box only bridges that serial stream into the continuation.
        final class Collector: @unchecked Sendable {
            var participants: [CKShare.Participant] = []
            var failure: (any Error)?
        }
        let collector = Collector()
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: lookupInfos)
            operation.perShareParticipantResultBlock = { _, result in
                switch result {
                case .success(let participant):
                    collector.participants.append(participant)
                case .failure(let error):
                    // Keep the first failure, not whichever callback fires last, so
                    // the thrown error is deterministic when several lookups fail.
                    if collector.failure == nil { collector.failure = error }
                }
            }
            operation.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success where collector.failure == nil:
                    continuation.resume(returning: collector.participants)
                case .success:
                    continuation.resume(throwing: collector.failure!)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.add(operation)
        }
    }

    public func acceptShare(metadata: CKShare.Metadata) async throws {
        _ = try await accept(metadata)
    }

    public func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            // One URL in, so the per-share callback alone decides the outcome;
            // the completion block would only repeat it.
            final class Box: @unchecked Sendable {
                var result: Result<CKShare.Metadata, any Error>?
            }
            let box = Box()
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            operation.perShareMetadataResultBlock = { _, result in
                box.result = result
            }
            operation.fetchShareMetadataResultBlock = { result in
                switch (box.result, result) {
                case (.some(let outcome), _):
                    continuation.resume(with: outcome)
                case (nil, .failure(let error)):
                    continuation.resume(throwing: error)
                case (nil, .success):
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
            self.add(operation)
        }
    }

    public func accountStatusUpdates() -> AsyncStream<CKAccountStatus> {
        AsyncStream { continuation in
            // The observer token is not Sendable; the box carries it into the
            // termination handler unchanged.
            final class Token: @unchecked Sendable {
                let value: NSObjectProtocol

                init(_ value: NSObjectProtocol) {
                    self.value = value
                }
            }
            // Each notification triggers an async accountStatus() read. Spawning an
            // independent Task per notification lets a later change's status resolve
            // and yield before an earlier one's, so observers can settle on a stale
            // status. Chain the reads so each completes and yields before the next
            // begins, preserving notification order.
            final class Serial: @unchecked Sendable {
                private let lock = NSLock()
                private var tail = Task<Void, Never> {}

                func enqueue(_ work: @escaping @Sendable () async -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    let previous = tail
                    tail = Task {
                        await previous.value
                        await work()
                    }
                }
            }
            let serial = Serial()
            let token = Token(
                NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    serial.enqueue {
                        if let status = try? await self.accountStatus() {
                            continuation.yield(status)
                        }
                    }
                })
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.value)
            }
        }
    }
}
