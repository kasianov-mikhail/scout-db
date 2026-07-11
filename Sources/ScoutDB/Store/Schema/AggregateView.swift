//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

public struct AggregateView: Codable, Equatable, Sendable {
    public let name: String
    public var groupBy: String?
    public var bucket: Bucket?
    public var sum: String?
    public var min: String?
    public var max: String?
    public var stats: String?
    public var histogram: Histogram?

    public init(
        name: String, groupBy: String? = nil, bucket: Bucket? = nil, sum: String? = nil, min: String? = nil, max: String? = nil, stats: String? = nil,
        histogram: Histogram? = nil
    ) {
        self.name = name
        self.groupBy = groupBy
        self.bucket = bucket
        self.sum = sum
        self.min = min
        self.max = max
        self.stats = stats
        self.histogram = histogram
    }

    public struct Histogram: Codable, Equatable, Sendable {
        public let field: String
        public let bounds: [Double]

        public init(field: String, bounds: [Double]) {
            self.field = field
            self.bounds = bounds
        }
    }

    public enum Bucket: String, Codable, Sendable {
        case hour, weekday, day
    }

    public enum Metric: Equatable, Sendable {
        case sum, min, max

        func combine(_ lhs: Double, _ rhs: Double) -> Double {
            switch self {
            case .sum: lhs + rhs
            case .min: Swift.min(lhs, rhs)
            case .max: Swift.max(lhs, rhs)
            }
        }
    }

    var metric: (kind: Metric, field: String)? {
        if let sum { return (.sum, sum) }
        if let min { return (.min, min) }
        if let max { return (.max, max) }
        if let stats { return (.sum, stats) }
        return nil
    }
}
