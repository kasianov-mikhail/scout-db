//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension GridQuery {
    func totals(having: (AggregateTotal) -> Bool = { _ in true }) async throws -> [AggregateTotal] {
        let kind = try await store.registry
            .definition(for: entity)
            .view(named: view)?
            .metric?.kind

        let rows = try await rows()

        return Dictionary(grouping: rows, by: \.group).map { group, rows in
            let count = rows.reduce(0) {
                $0 + $1.count
            }
            let value = rows.reduce(Double?.none) {
                combined($0, $1.value, kind)
            }
            let squares = rows.reduce(Double?.none) {
                combined($0, $1.squares, nil)
            }

            return AggregateTotal(
                group: group,
                count: count,
                value: value,
                squares: squares
            )
        }
        .filter(having).sorted()
    }
}
