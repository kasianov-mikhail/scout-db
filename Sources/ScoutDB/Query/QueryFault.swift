//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// The reason a query's shape cannot be served.
public enum QueryFault: Equatable, Sendable {
    case singleSortRequired
    case unsortableField(String)
    case unsearchableField(String)
    case unpageableField(String)
    case nonNumericField(String)
    case disjunctionUnsupported
    case equalityOnly(group: String?)
    case noAggregate(entity: String, grouping: String?, folding: String?)
    case averageOfOptional(String)
    case noHistogram(entity: String, field: String)
    case filteredHistogram
    case rankOutOfRange(Double)
}

extension QueryFault: CustomStringConvertible {
    public var description: String {
        switch self {
        case .singleSortRequired:
            "A field-ordered page requires exactly one sort clause"
        case .unsortableField(let field):
            "Field '\(field)' lives in a pool the server cannot sort by"
        case .unsearchableField(let field):
            "Field '\(field)' is not a searchable text field"
        case .unpageableField(let field):
            "Field '\(field)' cannot carry a page cursor"
        case .nonNumericField(let field):
            "Field '\(field)' is not numeric"
        case .disjunctionUnsupported:
            "An aggregate reads the grid and cannot honor a disjunction"
        case .equalityOnly(let group):
            "An aggregate reads the grid and can only be filtered by an equal '\(group ?? "group")'"
        case .noAggregate(let entity, let grouping, let folding):
            "Entity '\(entity)' keeps no aggregate "
                + [grouping.map { "grouped by '\($0)'" }, folding.map { "folding '\($0)'" }]
                .compactMap(\.self)
                .joined(separator: ", ")
        case .averageOfOptional(let field):
            "An average divides by a count taking in records without '\(field)'"
        case .noHistogram(let entity, let field):
            "Entity '\(entity)' keeps no histogram of '\(field)'"
        case .filteredHistogram:
            "A percentile reads a histogram grid, whose grouping is the bucket, and cannot honor a filter"
        case .rankOutOfRange(let rank):
            "A percentile rank of \(rank) lies outside 0...1"
        }
    }
}
