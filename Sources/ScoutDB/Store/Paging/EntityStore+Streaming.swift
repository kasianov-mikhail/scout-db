//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension EntityStore {
    func stream(entity: String, any branches: [[Filter]], fields: [String]? = nil, pageSize: Int = 100, createdBy creator: String? = nil)
        -> AsyncThrowingStream<EntityRecord, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: EntityCursor?
                do {
                    repeat {
                        let page = try await read(
                            entity: entity,
                            any: branches,
                            fields: fields,
                            limit: pageSize,
                            after: cursor,
                            createdBy: creator
                        )

                        for record in page {
                            continuation.yield(record)
                        }

                        cursor = page.cursor
                    } while cursor != nil && !Task.isCancelled

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
