//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

/// Several filters combined with `&&` and `||`, ready for a query to run.
///
/// CloudKit joins predicates with `AND` alone, so a disjunction is not one
/// query but several: the store runs one per alternative and merges the
/// results. An expression is therefore held in disjunctive normal form as it is
/// built — a list of alternatives, each a list of filters that must hold at
/// once — and `alternatives.count` is what the query will cost in requests.
///
/// That form is kept by construction rather than derived at the end: `||`
/// appends the alternatives of both sides, `&&` multiplies them out. So two
/// two-way choices `AND`-ed together are four alternatives and four requests,
/// which is worth seeing before the query runs rather than after.
///
/// Equalities over one field are the exception. `"level" == "error" || "level"
/// == "fatal"` folds into a single `in` filter, so widening a choice over one
/// field stays one request however many values it admits.
///
/// ```swift
/// try await store.query("log")
///     .filter("level" == "error" || ("level" == "warning" && "count" > 10))
///     .take(50)
/// ```
///
public struct FilterExpression: Sendable {
    let alternatives: [[Filter]]

    init(_ alternatives: [[Filter]]) {
        self.alternatives = alternatives
    }

    init(_ filter: Filter) {
        alternatives = [[filter]]
    }
}

/// Requires both sides at once.
///
/// Every alternative of the left side is paired with every alternative of the
/// right, so a conjunction of disjunctions costs the product of their counts in
/// requests: `(a || b) && (c || d)` is four alternatives, not two.
///
/// ```swift
/// try await store.query("purchase")
///     .filter("status" == "paid" && "amount" > 100)
///     .take(50)
/// ```
///
public func && (lhs: FilterExpression, rhs: FilterExpression) -> FilterExpression {
    let left = lhs.alternatives
    let right = rhs.alternatives

    return FilterExpression(
        left.flatMap { branch in
            right.map { branch + $0 }
        }
    )
}

/// Admits either side, as alternatives of one another.
///
/// Each side keeps its own alternatives and the two lists are joined, so this
/// normally costs one request per alternative. Two equalities over the same
/// field are folded into a single `in` filter instead, and folding is pairwise
/// along the chain, so `"a" == 1 || "a" == 2 || "a" == 3` ends as one filter
/// rather than three alternatives.
///
/// ```swift
/// try await store.query("log")
///     .filter("level" == "error" || "level" == "fatal")   // one request
///     .take(50)
/// ```
///
public func || (lhs: FilterExpression, rhs: FilterExpression) -> FilterExpression {
    let left = lhs.alternatives
    let right = rhs.alternatives

    guard let folded = Filter(folding: left, right) else {
        return FilterExpression(left + right)
    }
    return FilterExpression([[folded]])
}
