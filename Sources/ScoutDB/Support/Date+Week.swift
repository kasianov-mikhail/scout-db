//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension Date {
    static let secondsPerHour = 3_600.0
    static let secondsPerDay = 86_400.0
    static let hoursPerWeek = 168

    var weekStart: Date {
        let days = (timeIntervalSince1970 / Self.secondsPerDay).rounded(.down)
        let weekday = ((Int(days) + 3) % 7 + 7) % 7
        return Date(timeIntervalSince1970: (days - Double(weekday)) * Self.secondsPerDay)
    }

    var hourOfWeek: Int {
        Int((timeIntervalSince(weekStart) / Self.secondsPerHour).rounded(.down))
    }

    func hour(_ index: Int) -> Date {
        addingTimeInterval(Double(index) * Self.secondsPerHour)
    }

    func covers(_ range: Range<Date>) -> Bool {
        self < range.upperBound && hour(Self.hoursPerWeek) > range.lowerBound
    }
}
