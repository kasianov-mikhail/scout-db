//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation

protocol Vector {
    associatedtype Cell: VectorCell

    static var recordType: String { get }
    static var slug: String { get }
}

extension Vector {
    static var cellKeys: [String] {
        hourKeys
    }
}

enum DoubleVector: Vector {
    typealias Cell = Double

    static let recordType = "DoubleVector"
    static let slug = "double"
}

enum IntVector: Vector {
    typealias Cell = Int64

    static let recordType = "IntVector"
    static let slug = "int"
}

private let hourKeys: [String] = (0..<Date.hoursPerWeek).map { String(format: "c_%03d", $0) }
