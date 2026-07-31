//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct CellRange: Sendable {
    let view: AggregateView
    let group: String
    let period: Date
    let index: Int

    var window: (from: Date, to: Date)? {
        let calendar = EntityCoder.calendar
        let unit: Calendar.Component

        switch view.bucket ?? .hour {
        case .hour:
            unit = .hour
        case .weekday, .day:
            unit = .day
        case .lifetime:
            return nil
        }

        guard let from = calendar.date(byAdding: unit, value: index, to: period) else {
            return nil
        }
        guard let to = calendar.date(byAdding: unit, value: 1, to: from) else {
            return nil
        }

        return (from, to)
    }
}
