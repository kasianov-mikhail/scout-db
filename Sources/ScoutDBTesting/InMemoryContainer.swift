//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDB

/// The container double: an in-memory public database and a fixed account.
public final class InMemoryContainer: CloudContainer, @unchecked Sendable {
    public let publicDatabase: any CloudDatabase

    private let status: CKAccountStatus

    public init(status: CKAccountStatus = .available) {
        self.status = status
        publicDatabase = InMemoryDatabase()
    }

    public func accountStatus() async throws -> CKAccountStatus {
        status
    }
}
