//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation

struct VectorIndex: Hashable {
    static let namespace = "__index"

    let entity: String
    let aggregate: String
    let week: Date?
    let part: Int

    var recordID: CKRecord.ID {
        var components = [entity, aggregate]
        if let week {
            components.append(String(week.millisecondsSince1970))
        }
        if part > 0 {
            components.append("part-\(part)")
        }
        return CKRecord.ID(recordName: "index-" + contentDigest(components: components))
    }
}

extension VectorIndex {
    init(entity: String, aggregate: String) {
        self.init(entity: entity, aggregate: aggregate, week: nil, part: 0)
    }
}
