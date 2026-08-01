//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import ScoutDBTesting
import Testing

@Suite("Predicate evaluator")
struct PredicateEvaluatorTests {
    @Test("A missing field stays excluded under NOT, directly and inside a compound")
    func missingFieldUnderNot() {
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "r"))
        let leaf = NSPredicate(format: "b == %d", 1)

        let notLeaf = NSCompoundPredicate(notPredicateWithSubpredicate: leaf)
        #expect(PredicateEvaluator.evaluate(notLeaf, record: record) != true)

        let compound = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(value: true), leaf])
        let notCompound = NSCompoundPredicate(notPredicateWithSubpredicate: compound)
        #expect(PredicateEvaluator.evaluate(notCompound, record: record) != true)
    }

    @Test("Concrete boolean combinations are unaffected")
    func concreteCombinations() {
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "r"))
        record["a"] = 1 as Int64
        #expect(PredicateEvaluator.evaluate(NSPredicate(format: "a == %d", 1), record: record) == true)
        #expect(
            PredicateEvaluator.evaluate(
                NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "a == %d", 1), NSPredicate(value: true)]),
                record: record) == true)
        #expect(
            PredicateEvaluator.evaluate(
                NSCompoundPredicate(orPredicateWithSubpredicates: [NSPredicate(format: "a == %d", 2), NSPredicate(value: false)]),
                record: record) == false)
    }
}
