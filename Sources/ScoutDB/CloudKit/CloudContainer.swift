//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

/// The container seam above the database one: account state plus the public
/// database, so app code and tests can share the same entry point.
///
/// ScoutDB stores in the public database only — the schema, the grants it
/// ships, and the security model all assume a world-readable, shared corpus,
/// so the container hands out that database and no other.
///
/// Every CloudKit call fails opaquely when no iCloud account is signed in —
/// check ``accountStatus()`` (or ``requireAccount()``) before the first store
/// operation.
///
/// `CKContainer` conforms by forwarding, and the `ScoutDBTesting` product
/// ships `InMemoryContainer` for the same shape without a network. Both hand
/// out a ``CloudDatabase``, so the wiring below is the same either way.
///
/// ```swift
/// let container = CKContainer(identifier: "iCloud.com.example.app")
/// try await container.requireAccount()
///
/// let registry = SchemaRegistry(database: container.publicDatabase)
/// let store = EntityStore(database: container.publicDatabase, registry: registry)
/// ```
///
public protocol CloudContainer: Sendable {
    /// The current iCloud account state.
    ///
    /// A round trip to the iCloud daemon rather than a cached flag: it can
    /// block, and it throws when the daemon itself is unreachable. Only
    /// `.available` backs a store — under `.noAccount`, `.restricted`,
    /// `.couldNotDetermine` or `.temporarilyUnavailable` every read and write
    /// fails, and only the first is worth a sign-in prompt.
    ///
    /// The answer has a shelf life. Signing out or switching accounts
    /// mid-session posts `CKAccountChangedNotification`, after which the next
    /// call answers differently and records written from here on carry a
    /// different creator.
    ///
    func accountStatus() async throws -> CKAccountStatus

    /// The database every store runs against.
    ///
    /// Pass it to `SchemaRegistry` and `EntityStore`, which take a
    /// ``CloudDatabase`` and never reach for a container of their own. The
    /// private and shared databases stay out of reach on purpose: nothing in
    /// the shipped schema, its grants, or the zone every request names
    /// describes them.
    ///
    var publicDatabase: any CloudDatabase { get }
}

extension CloudContainer {
    /// Passes only with a usable account; throws ``AccountUnavailableError``
    /// carrying the actual status otherwise.
    ///
    /// The guard to run before the first store operation, so a signed-out user
    /// meets one clear error instead of an opaque CloudKit failure per
    /// request. It asks the container every time and caches nothing, which
    /// also makes it the way to re-check after an account change.
    ///
    /// ```swift
    /// do {
    ///     try await container.requireAccount()
    /// } catch let error as AccountUnavailableError {
    ///     presentSignIn(for: error.status)
    /// }
    /// ```
    ///
    public func requireAccount() async throws {
        let status = try await accountStatus()
        guard status == .available else {
            throw AccountUnavailableError(status: status)
        }
    }
}

/// The iCloud account cannot back a store right now — signed out, restricted,
/// or still resolving.
///
/// Thrown by ``CloudContainer/requireAccount()``. The carried status says
/// which case it is, and so what to do about it: `.noAccount` calls for a
/// sign-in prompt, `.restricted` names a device policy the app cannot lift,
/// while `.couldNotDetermine` and `.temporarilyUnavailable` are worth
/// retrying later.
///
public struct AccountUnavailableError: LocalizedError {
    /// The status the container reported instead of `.available`.
    public let status: CKAccountStatus

    public init(status: CKAccountStatus) {
        self.status = status
    }

    /// A diagnostic string carrying the raw status — not a message to show a
    /// user, who needs wording chosen per ``status``.
    public var errorDescription: String? {
        "iCloud account unavailable (status \(status.rawValue))"
    }
}

/// `CKContainer` already answers `accountStatus()`; only its public database
/// needs a name the rest of ScoutDB can see.
extension CKContainer: CloudContainer {
    public var publicDatabase: any CloudDatabase {
        publicCloudDatabase
    }
}
