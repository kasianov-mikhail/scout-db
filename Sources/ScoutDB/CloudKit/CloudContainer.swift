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
