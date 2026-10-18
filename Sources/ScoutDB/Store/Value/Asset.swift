//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Foundation

/// A file a record carries as a CloudKit asset.
///
/// An `.asset` field takes it through `EntityRecord`'s typed subscript; a
/// plain `Data` value would land in a `.bytes` field instead.
///
public struct Asset: Hashable, Sendable, RecordValue.Convertible {
    /// The file's contents.
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init?(recordValue: RecordValue) {
        guard case .asset(let data) = recordValue else {
            return nil
        }
        self.data = data
    }

    public var recordValue: RecordValue {
        .asset(data)
    }
}
