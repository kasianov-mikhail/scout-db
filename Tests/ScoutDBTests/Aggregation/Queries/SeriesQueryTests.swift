//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting
import Testing

@testable import ScoutDB

@Suite("Series read off the hours a vector holds")
struct SeriesQueryTests {
    let database = InMemoryDatabase()
    let store: EntityStore
    let registry: SchemaRegistry

    let noon = Date(timeIntervalSince1970: 36_000)

    var evening: Date {
        noon.hour(6)
    }

    var week: Range<Date> {
        noon.weekStart..<noon.weekStart.hour(Date.hoursPerWeek)
    }

    init() async throws {
        registry = SchemaRegistry(database: database)
        store = EntityStore(database: database, registry: registry)

        try await store.schema("payment")
            .field("product", .string, .required)
            .field("amount", .double, .required)
            .field("date", .timestamp)
            .sum("amount", by: "product", at: "date")
            .count(by: "product", at: "date")
            .create()

        try await write(("app", 5, noon), ("app", 15, evening), ("pro", 25, noon))
    }

    private func write(_ payments: (product: String, amount: Double, date: Date)...) async throws {
        for payment in payments {
            try await store.write(
                [
                    EntityWrite(
                        values: [
                            "product": .string(payment.product),
                            "amount": .double(payment.amount),
                            "date": .date(payment.date),
                        ],
                        uuid: nil
                    )
                ],
                entity: "payment"
            )
        }
    }

    @Test("Each hour a group wrote in comes back as its own point")
    func pointsPerHour() async throws {
        let points = try await store.query("payment").series("amount", metric: .sum, group: "product", in: week)

        #expect(
            points == [
                SeriesPoint(group: "app", date: noon, value: 5),
                SeriesPoint(group: "pro", date: noon, value: 25),
                SeriesPoint(group: "app", date: evening, value: 15),
            ]
        )
    }

    @Test("The points of a group sum to the total folded over the same vector")
    func pointsFoldToTheTotal() async throws {
        let points = try await store.query("payment").series("amount", metric: .sum, group: "product", in: week)
        let totals = try await store.query("payment").totals("amount", metric: .sum, group: "product")

        for total in totals {
            let folded = points.filter { $0.group == total.group }.map(\.value).reduce(0, +)
            #expect(folded == total.value)
        }
    }

    @Test("Counting alone needs no metric field")
    func countingPoints() async throws {
        let points = try await store.query("payment").series(metric: .sum, group: "product", in: week)

        #expect(points.map(\.group) == ["app", "pro", "app"])
        #expect(points.map(\.value) == [1, 1, 1])
    }

    @Test("An hour nothing wrote in has no point rather than a zero")
    func gapsStayGaps() async throws {
        let points = try await store.query("payment").series("amount", metric: .sum, group: "product", in: week)
        #expect(points.count == 3)
    }

    @Test("A range narrows the points to the hours it covers")
    func rangeNarrowsPoints() async throws {
        let points = try await store.query("payment").series(
            "amount", metric: .sum, group: "product", in: evening..<week.upperBound)

        #expect(points == [SeriesPoint(group: "app", date: evening, value: 15)])
    }

    @Test("A range the vectors miss entirely comes back empty")
    func rangeOutsideTheWeek() async throws {
        let next = week.upperBound..<week.upperBound.hour(Date.hoursPerWeek)
        let points = try await store.query("payment").series("amount", metric: .sum, group: "product", in: next)

        #expect(points.count == 0)
    }

    @Test("An equality filter on the grouping field narrows to that group")
    func filterNarrowsToOneGroup() async throws {
        let points = try await store.query("payment")
            .filter("product", .equals, .string("app"))
            .series("amount", metric: .sum, group: "product", in: week)

        #expect(points.map(\.group) == ["app", "app"])
    }

    @Test("An average divides the total by the count hour by hour")
    func averagePerHour() async throws {
        try await write(("app", 25, noon))

        let points = try await store.query("payment").series(
            "amount", metric: .average, group: "product", in: week)

        #expect(
            points == [
                SeriesPoint(group: "app", date: noon, value: 15),
                SeriesPoint(group: "pro", date: noon, value: 25),
                SeriesPoint(group: "app", date: evening, value: 15),
            ]
        )
    }

    @Test("A filter a vector cannot honor throws instead of being dropped")
    func unhonorableFilterThrows() async throws {
        await #expect(throws: SchemaError.self) {
            try await store.query("payment")
                .filter("amount" > 10)
                .series("amount", metric: .sum, group: "product", in: week)
        }
    }

    @Test("A shape no vector covers says so")
    func missingShapeThrows() async throws {
        await #expect(throws: SchemaError.self) {
            try await store.query("payment").series("amount", metric: .sum, group: "missing", in: week)
        }
    }
}
