//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    /// A fold over one numeric field of a filtered read.
    public enum Fold: String, Sendable {
        case sum, minimum, maximum, average
    }

    /// Folds a numeric field across the matching records, fetching only that
    /// field's slot rather than whole records.
    ///
    /// A `sum` or `average` over a view that sums the folded field is answered
    /// from that view's grid, for the query shapes ``count()`` covers, without
    /// reading records at all. `minimum` and `maximum` always scan: a deleted
    /// record's extremum cannot be un-applied, so the grid holds it only
    /// best-effort. Otherwise CloudKit runs no aggregates server-side, so the
    /// rows travel — as single-slot projections, not full payloads. `sum` of no
    /// rows is 0; the other folds return nil.
    ///
    /// A `createdBy` scope always scans: a view's grid folds every writer's
    /// records together and cannot be split back by creator.
    ///
    public func aggregate(_ fold: Fold, of field: String, entity: String, filters: [Filter] = [], createdBy creator: String? = nil) async throws -> Double? {
        try await aggregate(fold, of: field, entity: entity, any: [filters], createdBy: creator)
    }

    /// Folds a numeric field across the records matching any of the OR branches.
    public func aggregate(_ fold: Fold, of field: String, entity: String, any branches: [[Filter]], createdBy creator: String? = nil) async throws
        -> Double?
    {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version), [.int, .double].contains(target.type) else {
            throw SchemaError.invalidValue(field)
        }
        if creator == nil, let folded = try await gridFold(fold, of: field, entity: entity, any: branches) {
            let total = folded.values.reduce(into: GridFold()) {
                $0.count += $1.count; $0.total += $1.total
            }
            switch fold {
            case .sum: return total.total
            case .average: return total.count > 0 ? total.total / Double(total.count) : nil
            case .minimum, .maximum: break
            }
        }
        let scalars = try await read(entity: entity, any: branches, fields: [field], createdBy: creator).compactMap { $0.values[field]?.scalar }
        switch fold {
        case .sum: return scalars.reduce(0, +)
        case .minimum: return scalars.min()
        case .maximum: return scalars.max()
        case .average: return scalars.isEmpty ? nil : scalars.reduce(0, +) / Double(scalars.count)
        }
    }

    /// Folds a numeric field per distinct value of the grouping field.
    ///
    /// Fetches only the two involved slots. Keys are the group values' canonical
    /// strings (the raw string for a string field); records missing either field
    /// are skipped.
    ///
    public func aggregate(_ fold: Fold, of field: String, by group: String, entity: String, filters: [Filter] = [], createdBy creator: String? = nil)
        async throws -> [String: Double]
    {
        try await aggregate(fold, of: field, by: group, entity: entity, any: [filters], createdBy: creator)
    }

    /// Folds a numeric field per group across the records matching any of the OR branches.
    public func aggregate(_ fold: Fold, of field: String, by group: String, entity: String, any branches: [[Filter]], createdBy creator: String? = nil)
        async throws -> [String: Double]
    {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version), [.int, .double].contains(target.type) else {
            throw SchemaError.invalidValue(field)
        }
        guard definition.field(named: group, at: definition.version) != nil else {
            throw SchemaError.unknownField(group)
        }
        if creator == nil, let folded = try await gridFold(fold, of: field, by: group, entity: entity, any: branches) {
            switch fold {
            case .sum: return folded.mapValues(\.total)
            case .average: return folded.compactMapValues { $0.count > 0 ? $0.total / Double($0.count) : nil }
            case .minimum, .maximum: break
            }
        }
        var buckets: [String: [Double]] = [:]
        for record in try await read(entity: entity, any: branches, fields: [field, group], createdBy: creator) {
            guard let key = record.values[group]?.canonical, let scalar = record.values[field]?.scalar else { continue }
            buckets[key, default: []].append(scalar)
        }
        return buckets.mapValues { scalars in
            switch fold {
            case .sum: scalars.reduce(0, +)
            case .minimum: scalars.min() ?? 0
            case .maximum: scalars.max() ?? 0
            case .average: scalars.reduce(0, +) / Double(scalars.count)
            }
        }
    }

    /// Counts the matching records per distinct value of the grouping field.
    ///
    /// A view grouping by that field answers the covered query shapes from its
    /// grid, without reading records.
    ///
    public func counts(by group: String, entity: String, filters: [Filter] = [], createdBy creator: String? = nil) async throws -> [String: Int] {
        try await counts(by: group, entity: entity, any: [filters], createdBy: creator)
    }

    /// Counts records per group across the records matching any of the OR branches.
    public func counts(by group: String, entity: String, any branches: [[Filter]], createdBy creator: String? = nil) async throws -> [String: Int] {
        let definition = try await registry.definition(for: entity)
        guard definition.field(named: group, at: definition.version) != nil else {
            throw SchemaError.unknownField(group)
        }
        if creator == nil, try await alwaysPresent(group, entity: entity),
            let folded = try await viewFold(of: nil, by: group, entity: entity, any: branches)
        {
            return folded.mapValues(\.count)
        }
        var counts: [String: Int] = [:]
        for record in try await read(entity: entity, any: branches, fields: [group], createdBy: creator) {
            guard let key = record.values[group]?.canonical else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }

    private func gridFold(_ fold: Fold, of field: String, by group: String? = nil, entity: String, any branches: [[Filter]]) async throws
        -> [String: GridFold]?
    {
        switch fold {
        case .sum:
            break
        case .average:
            guard try await alwaysPresent(field, entity: entity) else { return nil }
        case .minimum, .maximum:
            return nil
        }
        if let group, try await alwaysPresent(group, entity: entity) == false { return nil }
        return try await viewFold(of: field, by: group, entity: entity, any: branches)
    }
}
