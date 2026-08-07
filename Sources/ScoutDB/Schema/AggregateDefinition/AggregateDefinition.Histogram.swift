//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension AggregateDefinition {
    struct Histogram: Codable, Equatable, Sendable {
        let field: String
        let bounds: [Double]
    }
}

extension AggregateDefinition.Histogram {
    func groupKey(of value: Double) -> String {
        let bin = bounds.firstIndex { value < $0 } ?? bounds.count
        return RecordValue.int(Int64(bin)).canonical
    }

    var groupKeys: [String] {
        (0...bounds.count).map { RecordValue.int(Int64($0)).canonical }
    }
}
