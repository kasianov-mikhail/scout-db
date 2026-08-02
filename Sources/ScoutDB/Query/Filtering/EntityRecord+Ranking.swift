//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

extension [EntityRecord] {
    func unique() -> [EntityRecord] {
        var seen: Set<String> = []
        return filter { seen.insert($0.uuid).inserted }
    }

    func ranked(using order: [FieldOrder], limit: Int? = nil) -> [EntityRecord] {
        let ranked = order.isEmpty ? self : sorted(using: order)
        guard let limit else {
            return ranked
        }
        return Array(ranked.prefix(limit))
    }
}
