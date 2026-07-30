//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The transforms a derived field can apply to its source.
///
/// `lowercase` and `fold` serve normalized comparisons, `reversed` turns an
/// `endsWith` into a server-side `beginsWith`, `ngrams` narrows `contains` and
/// `like` before the exact client check, `hour`, `day`, `week` and `month`
/// truncate a timestamp to group by it, and `hmac` keeps an encrypted field
/// filterable through a keyed digest.
///
public enum FieldTransform: String, Codable, Sendable {
    case lowercase, fold, reversed, ngrams, hour, day, week, month, hmac
}

struct Derivation: Codable, Equatable, Sendable {
    let source: String

    let transform: FieldTransform
}
