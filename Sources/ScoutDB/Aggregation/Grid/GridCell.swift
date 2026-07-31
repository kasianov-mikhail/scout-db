//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The one cell a view keeps for a group, named for the records standing behind
/// it — what an exact extremum is recomputed from.
struct GridCell: Sendable {
    let view: AggregateView
    let group: String
}
