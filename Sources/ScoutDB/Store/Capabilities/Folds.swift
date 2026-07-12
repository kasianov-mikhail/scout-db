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
}
