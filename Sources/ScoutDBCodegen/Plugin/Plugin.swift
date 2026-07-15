//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import Foundation
import PackagePlugin

/// Generates a typed entity struct for every `*.entity.json` file in the
/// target's sources, through the `scoutdb-codegen` executable.
@main
struct CodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target as? SourceModuleTarget else { return [] }
        let generator = try context.tool(named: "scoutdb-codegen")
        return module.sourceFiles(withSuffix: ".entity.json").map { file in
            let name = file.url.deletingPathExtension().deletingPathExtension().lastPathComponent
            let output = context.pluginWorkDirectoryURL.appending(path: "\(name).swift")
            return .buildCommand(
                displayName: "Generating \(name).swift from \(file.url.lastPathComponent)",
                executable: generator.url,
                arguments: [file.url.path, "--output", output.path],
                inputFiles: [file.url],
                outputFiles: [output])
        }
    }
}
