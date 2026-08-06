//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import Foundation
import ScoutDBTesting

@testable import ScoutDB

extension InMemoryDatabase {
    var entityRecords: [CKRecord] {
        records.filter {
            $0.recordType == "Entity" && $0[Envelope.entity] as? String != SchemaDescriptorEntry.namespace
        }
    }
}
