//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Observation

/// An observable live query result: hand it to a SwiftUI view, read `items`.
///
/// ```swift
/// @State private var purchases = store.query(Purchase.self).live()
/// // ...
/// List(purchases.items, id: \.productId) { ... }
/// ```
///
/// The model tracks the query for its whole life: the first value is the
/// current result, and every relevant local mutation delivers a fresh one —
/// remote edits arrive when a `SyncCoordinator` pass applies them. Updates
/// land on the main actor, so views bind to `items` directly. A failed pass
/// ends the tracking and surfaces in `error`.
///
@available(iOS 17.0, macOS 14.0, *)
@MainActor @Observable public final class LiveQuery<Element: Sendable> {
    /// The query's current result; empty until the first pass lands.
    public private(set) var items: [Element] = []
    /// The failure that stopped the tracking, nil while it runs.
    public private(set) var error: (any Error)?

    // Set once in init, read in deinit — the nonisolated escape hatch is safe
    // because no other context ever touches it.
    @ObservationIgnored nonisolated(unsafe) private var task: Task<Void, Never>?

    init(stream: AsyncThrowingStream<[Element], any Error>) {
        task = Task { [weak self] in
            do {
                for try await items in stream {
                    self?.items = items
                }
            } catch {
                self?.error = error
            }
        }
    }

    deinit {
        task?.cancel()
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension QueryBuilder {
    /// The built query as an observable live model — filters, groups, sorts,
    /// and limits included.
    @MainActor public func live() -> LiveQuery<EntityRecord> {
        LiveQuery(stream: observe())
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension TypedQueryBuilder where T: Sendable {
    /// The typed query as an observable live model — SwiftUI binds to `items`.
    @MainActor public func live() -> LiveQuery<T> {
        LiveQuery(stream: observe())
    }
}
