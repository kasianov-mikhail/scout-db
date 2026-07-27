//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// Caps how many requests ScoutDB keeps in flight at once.
///
/// The store fans out on purpose — ids fetched a hundred at a time, a cascade
/// probing every referring entity, a claim batch adjudicating in parallel — and
/// a wide fan-out lands as many simultaneous requests as it has chunks. That is
/// the shape a server rate limits, and rate limiting costs more than the
/// parallelism won. Slots are handed to waiters in arrival order, so a burst
/// queues rather than either stalling or arriving all at once.
///
/// A request abandoned by the backstop timeout gives its slot back while it may
/// still be in flight, so the cap is a ceiling on what ScoutDB starts, not a
/// guarantee about what the network is still carrying.
///
actor RequestGate {
    static let shared = RequestGate()

    private var limit: Int
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 8) {
        self.limit = Swift.max(1, limit)
    }

    /// Waits for a slot, taking one as soon as it is free.
    func enter() async {
        guard inFlight >= limit else {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Returns a slot, handing it straight to the longest waiter if there is one.
    func leave() {
        guard waiting.count > 0 else {
            inFlight = Swift.max(0, inFlight - 1)
            return
        }
        waiting.removeFirst().resume()
    }

    func setLimit(_ count: Int) {
        limit = Swift.max(1, count)
        while inFlight < limit, waiting.count > 0 {
            inFlight += 1
            waiting.removeFirst().resume()
        }
    }

    var currentLimit: Int {
        limit
    }
}

/// How ScoutDB paces the requests it sends.
public enum RequestPolicy {
    /// Sets how many requests ScoutDB keeps in flight at once; eight by default.
    ///
    /// Raise it when the work is latency-bound and the container is quiet,
    /// lower it when a long pass keeps meeting rate limits. Values below one
    /// are clamped.
    ///
    public static func setMaxConcurrentRequests(_ count: Int) async {
        await RequestGate.shared.setLimit(count)
    }

    /// How many requests ScoutDB keeps in flight at once.
    public static var maxConcurrentRequests: Int {
        get async { await RequestGate.shared.currentLimit }
    }
}
