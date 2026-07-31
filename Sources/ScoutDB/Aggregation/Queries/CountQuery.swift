//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct CountQuery {
    private static let namedDomain = 1_024.0

    var groupField: String?
    var groupKeys: Set<String>?
    var from: Date?
    var to: Date?
    var numericField: String?
    var numericGTE: Double?
    var numericLT: Double?

    var serverGroup: String? {
        groupKeys?.count == 1 ? groupKeys?.first : nil
    }

    func covers(_ key: String) -> Bool {
        groupKeys?.contains(key) ?? true
    }

    init?(_ filters: [EntityStore.Filter], envelopeDate: String?) {
        for filter in filters {
            guard !filter.negated, filter.radius == nil else {
                return nil
            }

            switch (filter.op, filter.value) {
            case (.greaterThanOrEquals, .date(let date)) where filter.field == envelopeDate:
                guard from == nil else {
                    return nil
                }
                from = date

            case (.lessThan, .date(let date)) where filter.field == envelopeDate:
                guard to == nil else {
                    return nil
                }
                to = date

            case (.equals, let value):
                guard groupField == nil else {
                    return nil
                }
                groupField = filter.field
                groupKeys = [value.canonical]

            case (.in, let value):
                guard groupField == nil, let keys = value.elementCanonicals else {
                    return nil
                }
                groupField = filter.field
                groupKeys = keys

            case (.greaterThanOrEquals, let value):
                guard let scalar = value.scalar, numericField == nil || numericField == filter.field, numericGTE == nil else {
                    return nil
                }
                numericField = filter.field
                numericGTE = scalar

            case (.lessThan, let value):
                guard let scalar = value.scalar, numericField == nil || numericField == filter.field, numericLT == nil else {
                    return nil
                }
                numericField = filter.field
                numericLT = scalar

            case (.greaterThan, .int(let value)):
                guard value < Int64.max, numericField == nil || numericField == filter.field, numericGTE == nil else {
                    return nil
                }
                numericField = filter.field
                numericGTE = Double(value + 1)

            case (.lessThanOrEquals, .int(let value)):
                guard value < Int64.max, numericField == nil || numericField == filter.field, numericLT == nil else {
                    return nil
                }
                numericField = filter.field
                numericLT = Double(value + 1)

            default:
                return nil
            }
        }
    }

    init?(any branches: [[EntityStore.Filter]], envelopeDate: String?) {
        guard let first = branches.first, var merged = CountQuery(first, envelopeDate: envelopeDate) else {
            return nil
        }
        for branch in branches.dropFirst() {
            guard let query = CountQuery(branch, envelopeDate: envelopeDate) else {
                return nil
            }
            guard query.groupField == merged.groupField, query.from == merged.from, query.to == merged.to else {
                return nil
            }
            guard query.numericField == merged.numericField, query.numericGTE == merged.numericGTE else {
                return nil
            }
            guard query.numericLT == merged.numericLT else {
                return nil
            }
            guard let keys = merged.groupKeys, let more = query.groupKeys else {
                return nil
            }
            merged.groupKeys = keys.union(more)
        }
        self = merged
    }

    func matchesGrouping(of view: AggregateView) -> Bool {
        groupField == nil || groupField == view.groupBy
    }

    func foldPlan(in definition: EntityDefinition, folding metric: (kind: Metric, field: String)?, grouping group: String?) -> AggregateView? {
        let ranged = from != nil || to != nil
        for view in definition.views ?? [] where view.histogram == nil && matchesGrouping(of: view) {
            guard group == nil || view.groupBy == group else {
                continue
            }
            if let metric, !view.answers(metric.kind, of: metric.field) {
                continue
            }

            let bucket = view.bucket ?? .hour
            guard ranged else {
                guard bucket == .lifetime else {
                    continue
                }
                return view
            }

            guard bucket != .lifetime else {
                continue
            }

            let unit: Calendar.Component = bucket == .hour ? .hour : .day
            let aligned = [from, to].compactMap { $0 }.allSatisfy { EntityCoder.periodStart(of: unit, for: $0) == $0 }

            guard aligned else {
                continue
            }
            return view
        }
        return nil
    }

    mutating func key(in definition: EntityDefinition) {
        guard groupField == nil, let name = numericField else {
            return
        }
        guard let field = definition.field(named: name, at: definition.version) else {
            return
        }
        guard field.type == .int, field.alwaysPresent, field.encrypted != true else {
            return
        }
        guard case .slot = field.storage, let lower = field.min, let upper = field.max else {
            return
        }
        guard (definition.views ?? []).contains(where: { $0.histogram == nil && $0.groupBy == name }) else {
            return
        }

        let floor = max(lower.rounded(.up), numericGTE?.rounded(.up) ?? -.greatestFiniteMagnitude)
        let ceiling = min(upper.rounded(.down), numericLT.map { $0.rounded(.up) - 1 } ?? .greatestFiniteMagnitude)
        guard ceiling - floor < Self.namedDomain, let first = Int64(exactly: floor), let last = Int64(exactly: ceiling) else {
            return
        }

        groupField = name
        groupKeys = Set((first <= last ? Array(first...last) : []).map { RecordValue.int($0).canonical })
        numericField = nil
        numericGTE = nil
        numericLT = nil
    }

    func histogramPlan(in definition: EntityDefinition) -> (view: AggregateView, cells: Range<Int>)? {
        for view in definition.views ?? [] {
            guard let histogram = view.histogram, histogram.field == numericField, matchesGrouping(of: view) else {
                continue
            }
            var first = 0
            var last = histogram.bounds.count
            if let gte = numericGTE {
                guard let bound = histogram.bounds.firstIndex(of: gte) else {
                    continue
                }
                first = bound + 1
            }
            if let below = numericLT {
                guard let bound = histogram.bounds.firstIndex(of: below) else {
                    continue
                }
                last = bound
            }
            guard first <= last else {
                continue
            }
            return (view, first..<last + 1)
        }
        return nil
    }
}

extension RecordValue {
    fileprivate var elementCanonicals: Set<String>? {
        members.map { Set($0.map(\.canonical)) }
    }
}
