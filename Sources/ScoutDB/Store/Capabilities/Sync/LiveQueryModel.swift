//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import Observation

@available(iOS 17.0, macOS 14.0, *)
@MainActor @Observable public final class LiveQuery<Element: Sendable> {
    /// The query's current result; empty until the first pass lands.
    public private(set) var items: [Element] = []
    /// The failure that stopped the tracking, nil while it runs.
    public private(set) var error: (any Error)?

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
    @MainActor public func live() -> LiveQuery<EntityRecord> {
        LiveQuery(stream: observe())
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension TypedQueryBuilder where T: Sendable {
    @MainActor public func live() -> LiveQuery<T> {
        LiveQuery(stream: observe())
    }
}
