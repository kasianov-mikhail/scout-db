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
    var bounds: Bounds?

    init?(branches: [[ClientFilter]]) {
        guard let first = branches.first, var merged = FilterPlan(first) else {
            return nil
        }

        for branch in branches.dropFirst() {
            guard let query = FilterPlan(branch) else {
                return nil
            }
            guard query.groupField == merged.groupField, query.bounds == merged.bounds else {
                return nil
            }

            merged.groupKeys.formUnion(query.groupKeys)
        }

        self = merged
    }

    private init?(_ filters: [ClientFilter]) {
        for filter in filters {
            if let keys = filter.groupKeys, groupField == nil {
                groupField = filter.field
                groupKeys = keys
            } else if let narrowed = (bounds ?? Bounds(field: filter.field)).narrowed(by: filter) {
                bounds = narrowed
            } else {
                return nil
            }
        }
    }
}

extension FilterPlan {
    mutating func expandRange(in definition: EntityDefinition) {
        guard groupField == nil, let bounds else {
            return
        }
        guard let field = try? definition.field(bounds.field, at: definition.version) else {
            return
        }
        guard field.type == .int, field.alwaysPresent else {
            return
        }
        guard case .slot = field.storage, let lower = field.min, let upper = field.max else {
            return
        }
        guard definition.aggregates.contains(where: { $0.groupBy == bounds.field }) else {
            return
        }

        let floor = max(
            lower.rounded(.up),
            bounds.lower?.rounded(.up) ?? -.greatestFiniteMagnitude
        )
        let ceiling = min(
            upper.rounded(.down),
            bounds.upper.map { $0.rounded(.up) - 1 } ?? .greatestFiniteMagnitude
        )

        guard ceiling - floor < 1_024 else {
            return
        }
        guard let first = Int64(exactly: floor), let last = Int64(exactly: ceiling) else {
            return
        }

        groupField = bounds.field
        groupKeys = Set(stride(from: first, through: last, by: 1).map { RecordValue.int($0).canonical })

        self.bounds = nil
    }
}

extension ClientFilter {
    fileprivate var groupKeys: Set<String>? {
        membershipValues.map { Set($0.map(\.canonical)) }
    }
}
