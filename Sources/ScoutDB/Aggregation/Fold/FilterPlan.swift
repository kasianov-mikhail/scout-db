//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

struct FilterPlan {
    var groupField: String?
    var groupKeys: Set<String> = []
    var numericField: String?

    private var numericGTE: Double?
    private var numericLT: Double?

    init?(any branches: [[Filter]]) {
        guard let first = branches.first, var merged = FilterPlan(first) else {
            return nil
        }

        for branch in branches.dropFirst() {
            guard let query = FilterPlan(branch) else {
                return nil
            }
            guard query.groupField == merged.groupField else {
                return nil
            }
            guard query.numericField == merged.numericField else {
                return nil
            }
            guard query.numericGTE == merged.numericGTE else {
                return nil
            }
            guard query.numericLT == merged.numericLT else {
                return nil
            }

            merged.groupKeys.formUnion(query.groupKeys)
        }

        self = merged
    }

    func foldPlan(
        in definition: EntityDefinition, folding kind: Metric, of field: String?, grouping group: String?
    ) -> AggregateDefinition? {
        let grouping = group ?? groupField

        return (definition.aggregates ?? []).first { aggregate in
            guard grouping == nil || aggregate.groupBy == grouping else {
                return false
            }
            return field.map {
                aggregate.metricKind == kind && aggregate.metricField == $0
            } ?? true
        }
    }

    mutating func expandRange(in definition: EntityDefinition) {
        guard groupField == nil, let name = numericField else {
            return
        }
        guard let field = definition.field(named: name, at: definition.version) else {
            return
        }
        guard field.type == .int, field.alwaysPresent else {
            return
        }
        guard case .slot = field.storage, let lower = field.min, let upper = field.max else {
            return
        }
        guard (definition.aggregates ?? []).contains(where: { $0.groupBy == name }) else {
            return
        }

        let floor = max(
            lower.rounded(.up),
            numericGTE?.rounded(.up) ?? -.greatestFiniteMagnitude
        )
        let ceiling = min(
            upper.rounded(.down),
            numericLT.map { $0.rounded(.up) - 1 } ?? .greatestFiniteMagnitude
        )

        guard ceiling - floor < 1_024 else {
            return
        }
        guard let first = Int64(exactly: floor), let last = Int64(exactly: ceiling) else {
            return
        }

        groupField = name
        groupKeys = Set((first <= last ? Array(first...last) : []).map { RecordValue.int($0).canonical })
        numericField = nil
        numericGTE = nil
        numericLT = nil
    }
}

extension FilterPlan {
    private init?(_ filters: [Filter]) {
        for filter in filters {
            switch (filter.op, filter.value) {
            case (.equals, let value):
                guard groupField == nil else {
                    return nil
                }
                groupField = filter.field
                groupKeys = [value.canonical]

            case (.in, let value):
                guard groupField == nil else {
                    return nil
                }
                guard let keys = value.elementCanonicals else {
                    return nil
                }
                groupField = filter.field
                groupKeys = keys

            case (.greaterThanOrEquals, let value):
                guard let scalar = value.scalar else {
                    return nil
                }
                guard numericField == nil || numericField == filter.field else {
                    return nil
                }
                guard numericGTE == nil else {
                    return nil
                }
                numericField = filter.field
                numericGTE = scalar

            case (.lessThan, let value):
                guard let scalar = value.scalar else {
                    return nil
                }
                guard numericField == nil || numericField == filter.field else {
                    return nil
                }
                guard numericLT == nil else {
                    return nil
                }
                numericField = filter.field
                numericLT = scalar

            case (.greaterThan, .int(let value)):
                guard value < Int64.max else {
                    return nil
                }
                guard numericField == nil || numericField == filter.field else {
                    return nil
                }
                guard numericGTE == nil else {
                    return nil
                }
                numericField = filter.field
                numericGTE = Double(value + 1)

            case (.lessThanOrEquals, .int(let value)):
                guard value < Int64.max else {
                    return nil
                }
                guard numericField == nil || numericField == filter.field else {
                    return nil
                }
                guard numericLT == nil else {
                    return nil
                }
                numericField = filter.field
                numericLT = Double(value + 1)

            default:
                return nil
            }
        }
    }
}

extension RecordValue {
    fileprivate var elementCanonicals: Set<String>? {
        members.map { Set($0.map(\.canonical)) }
    }
}
