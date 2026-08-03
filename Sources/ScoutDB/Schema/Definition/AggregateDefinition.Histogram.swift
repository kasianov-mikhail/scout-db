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
    var bins: Range<Int> {
        0..<(bounds.count + 1)
    }

    func bin(of value: Double) -> Int {
        bounds.firstIndex { value < $0 } ?? bounds.count
    }

    func groupKey(of value: Double) -> String {
        RecordValue.int(Int64(bin(of: value))).canonical
    }

    var groupKeys: [String] {
        bins.map { RecordValue.int(Int64($0)).canonical }
    }
}
