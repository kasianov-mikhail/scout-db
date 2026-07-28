//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

enum PerfScenarios {
    static var all: [PerfScenario] {
        schema + queries + writes + pagination + aggregates + counters + uniqueKeys + transactions + leases + conflicts
            + relations + revisions + lifecycle + assets + encryption + migrations
            + liveQueries + subscriptions + pushEvents
    }
}

extension PerfWorld {
    func order(_ index: Int) -> String {
        corpus.orders[(index &* 37) % corpus.orders.count]
    }

    func customer(_ index: Int) -> String {
        corpus.customers[(index &* 13) % corpus.customers.count]
    }

    func item(_ index: Int) -> String {
        corpus.items[(index &* 17) % corpus.items.count]
    }

    func session(_ index: Int) -> String {
        corpus.sessions[(index &* 11) % (corpus.sessions.count - corpus.deleted.count)]
    }

    func tombstoned(_ index: Int) -> String {
        corpus.deleted[index % corpus.deleted.count]
    }

    var hotProduct: String {
        PerfSchema.products[0]
    }

    func orders(_ count: Int, from index: Int) -> [String] {
        (0..<count).map { order(index &* count &+ $0) }
    }

    func newOrder(_ iteration: Int, offset: Int = 0) -> [String: RecordValue] {
        [
            "customer": .string(customer(iteration)),
            "product": .string(PerfSchema.products[(iteration &+ offset) % PerfSchema.products.count]),
            "status": .string("placed"),
            "quantity": .int(Int64(1 + (iteration &+ offset) % 20)),
            "total": .double(19.99 + Double((iteration &+ offset) % 400)),
            "date": .date(corpus.now.addingTimeInterval(-Double((iteration &+ offset) % 30) * 86_400)),
        ]
    }

    func window(days: Int) -> (from: Date, to: Date) {
        (corpus.now.addingTimeInterval(-Double(days) * 86_400), corpus.now.addingTimeInterval(86_400))
    }
}
