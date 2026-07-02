//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CryptoKit
import Foundation

struct GridAggregator {
    let database: any Database
    let maxRetry = 3

    func record(_ entityRecord: EntityRecord, using definition: EntityDefinition) async throws {
        guard entityRecord.deleted == false else { return }
        guard let dateField = definition.envelopeDate, case .date(let date)? = entityRecord.values[dateField] else { return }

        for view in definition.views ?? [] {
            let group = view.groupBy.flatMap { entityRecord.values[$0]?.canonical } ?? ""

            if let histogram = view.histogram {
                guard let value = entityRecord.values[histogram.field]?.scalar else { continue }
                let period = EntityCoder.calendar.startOfDay(for: date)
                let index = histogram.bounds.firstIndex { value < $0 } ?? histogram.bounds.count
                try await bump(index: index, metric: nil, squares: nil, entity: entityRecord.entity, view: view.name, group: group, day: period)
                continue
            }

            let (period, index) = Self.bucket(view.bucket ?? .hour, for: date)
            var metric: (kind: AggregateView.Metric, value: Double)?
            if let (kind, field) = view.metric, let value = entityRecord.values[field]?.scalar {
                metric = (kind, value)
            }
            let squares = view.stats.flatMap { entityRecord.values[$0]?.scalar }.map { $0 * $0 }
            try await bump(index: index, metric: metric, squares: squares, entity: entityRecord.entity, view: view.name, group: group, day: period)
        }
    }

    static func bucket(_ bucket: AggregateView.Bucket, for date: Date) -> (period: Date, index: Int) {
        let calendar = EntityCoder.calendar
        switch bucket {
        case .hour:
            return (calendar.startOfDay(for: date), calendar.component(.hour, from: date))
        case .weekday:
            let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            return (week, calendar.component(.weekday, from: date) - 1)
        case .day:
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            return (month, calendar.component(.day, from: date) - 1)
        }
    }

    // A stats view keeps the running sum in f_index and the sum of squares in
    // f_(index + 32); time buckets never exceed index 30, so the halves cannot clash.
    private func bump(
        index: Int, metric: (kind: AggregateView.Metric, value: Double)?, squares: Double?, entity: String, view: String, group: String, day: Date
    ) async throws {
        var record = try await lookup(entity: entity, view: view, group: group, day: day)
        let countCell = String(format: "c_%02d", index)
        let valueCell = String(format: "f_%02d", index)
        let squareCell = String(format: "f_%02d", index + 32)

        for _ in 0..<maxRetry {
            record.fields[countCell] = .int((record[countCell] as Int64? ?? 0) + 1)
            if let (kind, value) = metric {
                let combined = (record[valueCell] as Double?).map { kind.combine($0, value) } ?? value
                record.fields[valueCell] = .double(combined)
            }
            if let squares {
                record.fields[squareCell] = .double((record[squareCell] as Double? ?? 0) + squares)
            }
            do {
                try await database.write(record: record)
                return
            } catch let conflict as RecordConflictError {
                record = conflict.serverRecord
            }
        }
        throw RecordConflictError(serverRecord: record)
    }

    private func lookup(entity: String, view: String, group: String, day: Date) async throws -> Record {
        let query = RecordQuery(
            recordType: GridItem.self,
            filters: [
                RecordQuery.Filter(field: "entity", op: .equals, value: .string(entity)),
                RecordQuery.Filter(field: "view", op: .equals, value: .string(view)),
                RecordQuery.Filter(field: "group_key", op: .equals, value: .string(group)),
                RecordQuery.Filter(field: "date", op: .equals, value: .date(day)),
            ])
        if let existing = try await database.readAll(matching: query, fields: nil).first {
            return existing
        }

        let key = "\(entity)|\(view)|\(group)|\(day.millisecondsSince1970)"
        let digest = SHA256.hash(data: Data(key.utf8))
        var record = Record(recordType: GridItem.recordType, recordID: "grid-" + digest.map { String(format: "%02x", $0) }.joined())
        record["entity"] = entity
        record["view"] = view
        record["group_key"] = group
        record["date"] = day
        return record
    }
}

struct GridItem: RecordDecodable {
    static let recordType = "GridItem"
    static let desiredKeys: [String] = []

    init(record: Record) throws {}
}
