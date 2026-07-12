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
    /// CloudKit runs no aggregates server-side, so the rows still travel — but
    /// as single-slot projections, not full payloads. `sum` of no rows is 0;
    /// the other folds return nil.
    ///
    public func aggregate(_ fold: Fold, of field: String, entity: String, filters: [Filter] = []) async throws -> Double? {
        try await aggregate(fold, of: field, entity: entity, any: [filters])
    }

    /// Folds a numeric field across the records matching any of the OR branches.
    public func aggregate(_ fold: Fold, of field: String, entity: String, any branches: [[Filter]]) async throws -> Double? {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version), [.int, .double].contains(target.type) else {
            throw SchemaError.invalidValue(field)
        }
        let scalars = try await read(entity: entity, any: branches, fields: [field]).compactMap { $0.values[field]?.scalar }
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
    public func aggregate(_ fold: Fold, of field: String, by group: String, entity: String, filters: [Filter] = []) async throws -> [String: Double] {
        try await aggregate(fold, of: field, by: group, entity: entity, any: [filters])
    }

    /// Folds a numeric field per group across the records matching any of the OR branches.
    public func aggregate(_ fold: Fold, of field: String, by group: String, entity: String, any branches: [[Filter]]) async throws -> [String: Double] {
        let definition = try await registry.definition(for: entity)
        guard let target = definition.field(named: field, at: definition.version), [.int, .double].contains(target.type) else {
            throw SchemaError.invalidValue(field)
        }
        guard definition.field(named: group, at: definition.version) != nil else {
            throw SchemaError.unknownField(group)
        }
        var buckets: [String: [Double]] = [:]
        for record in try await read(entity: entity, any: branches, fields: [field, group]) {
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
    public func counts(by group: String, entity: String, filters: [Filter] = []) async throws -> [String: Int] {
        try await counts(by: group, entity: entity, any: [filters])
    }

    /// Counts records per group across the records matching any of the OR branches.
    public func counts(by group: String, entity: String, any branches: [[Filter]]) async throws -> [String: Int] {
        let definition = try await registry.definition(for: entity)
        guard definition.field(named: group, at: definition.version) != nil else {
            throw SchemaError.unknownField(group)
        }
        var counts: [String: Int] = [:]
        for record in try await read(entity: entity, any: branches, fields: [group]) {
            guard let key = record.values[group]?.canonical else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }
}
