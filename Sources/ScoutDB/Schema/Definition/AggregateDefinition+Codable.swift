//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.
//

import Foundation

extension AggregateDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case groupBy
        case sum
        case min
        case max
        case histogram
        case shards
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let measures: [Measure] = try [
            container.decodeIfPresent(String.self, forKey: .sum).map(Measure.sum),
            container.decodeIfPresent(String.self, forKey: .min).map(Measure.min),
            container.decodeIfPresent(String.self, forKey: .max).map(Measure.max),
            container.decodeIfPresent(Histogram.self, forKey: .histogram).map(Measure.histogram),
        ]
        .compactMap(\.self)

        guard measures.count <= 1 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "An aggregate declares more than one measure"
                )
            )
        }

        self.init(
            name: try container.decode(String.self, forKey: .name),
            groupBy: try container.decodeIfPresent(String.self, forKey: .groupBy),
            measure: measures.first,
            shards: try container.decodeIfPresent(Int.self, forKey: .shards),
            date: try container.decodeIfPresent(String.self, forKey: .date)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(groupBy, forKey: .groupBy)
        try container.encodeIfPresent(shards, forKey: .shards)
        try container.encodeIfPresent(date, forKey: .date)

        switch measure {
        case .sum(let field):
            try container.encode(field, forKey: .sum)
        case .min(let field):
            try container.encode(field, forKey: .min)
        case .max(let field):
            try container.encode(field, forKey: .max)
        case .histogram(let histogram):
            try container.encode(histogram, forKey: .histogram)
        case nil:
            break
        }
    }
}
