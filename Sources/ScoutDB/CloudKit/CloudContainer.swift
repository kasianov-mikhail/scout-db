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

    var privateDatabase: any CloudDatabase { get }
    var publicDatabase: any CloudDatabase { get }
    var sharedDatabase: any CloudDatabase { get }
}

extension CloudContainer {
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
                case .success(let participant): collector.participants.append(participant)
                case .failure(let error): collector.failure = error
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
            let token = Token(
                NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    Task {
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
