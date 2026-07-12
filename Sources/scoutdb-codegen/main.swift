//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import ScoutDB

// The command-line face of `DefinitionCodeGenerator`, driven by the
// ScoutDBCodegen build-tool plugin: one entity-definition JSON in, one
// generated Swift file out.
let arguments = CommandLine.arguments
guard arguments.count == 4, arguments[2] == "--output" else {
    FileHandle.standardError.write(Data("usage: scoutdb-codegen <definition.entity.json> --output <file.swift>\n".utf8))
    exit(1)
}

do {
    let definition = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let source = try DefinitionCodeGenerator().source(forJSON: definition)
    try source.write(to: URL(fileURLWithPath: arguments[3]), atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("scoutdb-codegen: \(error)\n".utf8))
    exit(1)
}
