//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

/// One record of a batched `EntityStore.write(_:entity:)` call.
public struct EntityWrite: Sendable {
    public let values: [String: RecordValue]

    /// The uuid to write under, replacing any record that already carries it,
    /// or `nil` to write under a fresh one that no stored record can hold.
    public let uuid: String?

    public init(values: [String: RecordValue], uuid: String? = nil) {
        self.values = values
        self.uuid = uuid
    }
}
