//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

final class StagedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var holds: [String: Int] = [:]
    private var retired: Set<String> = []

    func retain(_ url: URL) {
        lock.withLock { holds[url.standardizedFileURL.path, default: 0] += 1 }
    }

    func release(_ url: URL, retiring: Bool) {
        let path = url.standardizedFileURL.path
        lock.withLock {
            if retiring {
                retired.insert(path)
            }
            let remaining = (holds[path] ?? 0) - 1
            guard remaining <= 0 else {
                holds[path] = remaining
                return
            }
            holds[path] = nil
            guard retired.remove(path) != nil else {
                return
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.withLock {
            holds[path] = nil
            retired.remove(path)
        }
    }
}
