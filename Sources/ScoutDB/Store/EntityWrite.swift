//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// One record of a batched `EntityStore.write(_:entity:)` call.
public struct EntityWrite: Sendable {
    public let values: [String: RecordValue]
    public let uuid: String
    let assigned: Bool

    /// Writes under a uuid of the caller's choosing, replacing any record that
    /// already carries it.
    public init(values: [String: RecordValue], uuid: String) {
        self.values = values
        self.uuid = uuid
        self.assigned = true
    }

    /// Writes under a fresh uuid, which no stored record can hold.
    public init(values: [String: RecordValue]) {
        self.values = values
        self.uuid = UUID().uuidString
        self.assigned = false
    }
}
