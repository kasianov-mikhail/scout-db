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
/// check `accountStatus()` (or `requireAccount()`) before the first store
/// operation.
///
public protocol CloudContainer: Sendable {
    /// The current iCloud account state.
    func accountStatus() async throws -> CKAccountStatus

    /// The database every store runs against.
    var publicDatabase: any CloudDatabase { get }
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

extension CKContainer: CloudContainer {
    public var publicDatabase: any CloudDatabase {
        publicCloudDatabase
    }
}
