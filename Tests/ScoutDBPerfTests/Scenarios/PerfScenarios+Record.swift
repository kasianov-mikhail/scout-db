//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

extension PerfScenarios {
    static var encryption: [PerfScenario] {
        [
            PerfScenario("Encryption", "write a sealed field", sql: 1) { world, iteration in
                try await world.store.write(
                    [
                        "customer": .string(world.customer(iteration)),
                        "device": .string("mac"),
                        "started": .date(world.corpus.now),
                        "token": .string("secret-\(iteration)"),
                    ], entity: PerfSchema.session, uuid: world.fresh("sec", iteration))
            },
            PerfScenario(
                "Encryption", "read a sealed field back", sql: 1, writes: false,
                setUp: { world in
                    for iteration in 0..<world.repeats {
                        let uuid = world.fresh("open", iteration)
                        try await world.store.write(
                            [
                                "customer": .string(world.customer(iteration)),
                                "device": .string("watch"),
                                "started": .date(world.corpus.now),
                                "token": .string("secret-\(iteration)"),
                            ], entity: PerfSchema.session, uuid: uuid)
                        world.stage.uuids.append(uuid)
                    }
                }
            ) { world, iteration in
                _ = try await world.store.fetch(entity: PerfSchema.session, uuids: [world.stage.uuids[iteration]])
            },
        ]
    }
}
