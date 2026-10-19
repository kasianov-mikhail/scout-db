//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

extension String {
    init(slotPrefix: String, index: Int) {
        self = "\(slotPrefix)_\(String(format: "%02d", index))"
    }

    func slotIndex(prefix: String) -> Int? {
        guard hasPrefix("\(prefix)_"), let index = Int(dropFirst(prefix.count + 1)) else {
            return nil
        }
        return index >= 0 ? index : nil
    }
}
