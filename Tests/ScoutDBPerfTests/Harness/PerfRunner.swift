//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

@testable import ScoutDB

enum PerfRunner {
    static func sweep(_ scenarios: [PerfScenario], sizes: [DatasetSize] = DatasetSize.selected, onResult: (PerfResult) -> Void = { _ in }) async throws
        -> [PerfResult]
    {
        var results: [PerfResult] = []
        for size in sizes {
            let bench = PerfBench(corpus: try await CorpusCache.shared.corpus(for: size))
            for scenario in scenarios {
                let result = await run(scenario, on: bench)
                onResult(result)
                results.append(result)
            }
        }
        return results
    }

    static func run(_ scenario: PerfScenario, on bench: PerfBench) async -> PerfResult {
        let iterations = scenario.repeats(on: bench.corpus.size)
        do {
            let world = try await bench.world(for: scenario)
            if let setUp = scenario.setUp {
                try await setUp(world)
                world.app.reset()
                world.wire.reset()
            }
            for iteration in 0..<iterations {
                try await scenario.body(world, iteration)
            }
            return PerfResult(
                feature: scenario.feature, scenario: scenario.name, size: bench.corpus.size, iterations: iterations, sql: scenario.sql,
                app: world.app.snapshot, wire: world.wire.snapshot, failure: nil)
        } catch {
            return PerfResult(
                feature: scenario.feature, scenario: scenario.name, size: bench.corpus.size, iterations: iterations, sql: scenario.sql,
                app: PerfRecorder.Tally(), wire: PerfRecorder.Tally(), failure: "\(error)")
        }
    }
}
