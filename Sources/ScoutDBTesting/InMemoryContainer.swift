//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

/// The container double: an in-memory public database and a settable account.
public final class InMemoryContainer: CloudContainer, @unchecked Sendable {
    public let publicDatabase: any CloudDatabase

    private let lock = NSLock()
    private var status: CKAccountStatus

    public init(status: CKAccountStatus = .available) {
        self.status = status
        publicDatabase = InMemoryDatabase()
    }

    public func accountStatus() async throws -> CKAccountStatus {
        lock.withLock { status }
    }

    /// Simulates a sign-in, sign-out, or account switch.
    public func setAccountStatus(_ status: CKAccountStatus) {
        lock.withLock { self.status = status }
    }
}
