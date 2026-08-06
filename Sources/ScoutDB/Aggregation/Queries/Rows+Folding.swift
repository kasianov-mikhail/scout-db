//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit

typealias VectorRow = (group: String, record: CKRecord)

extension AggregateDefinition {
    func rows(
        from database: any CloudDatabase, of entity: String, groups: [String]?, folding kind: Metric,
        where include: ((String) -> Bool)? = nil
    ) async throws -> [String: Double] {
        if counts {
            try await VectorReader<IntVector>(database: database, entity: entity, aggregate: self)
                .rows(groups: groups)
                .vectorRows(of: IntVector.self, folding: kind, where: include)
        } else {
            try await VectorReader<DoubleVector>(database: database, entity: entity, aggregate: self)
                .rows(groups: groups)
                .vectorRows(of: DoubleVector.self, folding: kind, where: include)
        }
    }

    func recordIDs(from database: any CloudDatabase, of entity: String) async throws -> [CKRecord.ID] {
        if counts {
            try await VectorReader<IntVector>(database: database, entity: entity, aggregate: self).recordIDs()
        } else {
            try await VectorReader<DoubleVector>(database: database, entity: entity, aggregate: self).recordIDs()
        }
    }
}

extension [VectorRow] {
    func vectorRows<Holder: Vector>(
        of holder: Holder.Type, folding kind: Metric, where include: ((String) -> Bool)?
    ) -> [String: Double] {
        var rows: [String: Double] = [:]

        for (key, record) in self {
            guard include?(key) != false, let value = kind.fold(record.cells(of: holder))?.scalar else {
                continue
            }
            rows[key] = rows[key].map { kind.combine($0, value) } ?? value
        }

        return rows
    }
}

extension CKRecord {
    fileprivate func cells<Holder: Vector>(of holder: Holder.Type) -> [Holder.Cell] {
        allKeys().compactMap { key in
            key.hasPrefix("c_") ? Holder.Cell.cell(of: self, at: key) : nil
        }
    }
}
