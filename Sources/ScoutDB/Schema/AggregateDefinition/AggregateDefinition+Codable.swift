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
        case groupBy
        case groups
        case sum
        case min
        case max
        case histogram
        case shards
        case date
        case since
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
            groups: try container.decodeIfPresent([String].self, forKey: .groups)
                ?? container.decodeIfPresent(String.self, forKey: .groupBy).map { [$0] } ?? [],
            measure: measures.first,
            shards: try container.decodeIfPresent(Int.self, forKey: .shards),
            date: try container.decodeIfPresent(String.self, forKey: .date),
            since: try container.decodeIfPresent(Int64.self, forKey: .since).map(Date.init(millisecondsSince1970:))
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if groups.count == 1 {
            try container.encode(groups[0], forKey: .groupBy)
        } else if !groups.isEmpty {
            try container.encode(groups, forKey: .groups)
        }
        try container.encodeIfPresent(shards, forKey: .shards)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(since?.millisecondsSince1970, forKey: .since)

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
