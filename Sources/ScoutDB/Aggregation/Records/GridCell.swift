//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct GridCell: Hashable {
    static let days = 0...6
    static let hours = 0...23

    let day: Int
    let hour: Int

    var key: String {
        Self.keys[day * Self.hours.count + hour]
    }

    static let keys: [String] = days.flatMap { day in
        hours.map { String(format: "c_%02d_%02d", day, $0) }
    }
}

extension GridCell {
    init(of date: Date) {
        let elapsed = date.timeIntervalSince(date.weekStart) / Date.secondsPerHour
        let hours = Int(elapsed.rounded(.down))

        self.init(day: hours / Self.hours.count, hour: hours % Self.hours.count)
    }
}
