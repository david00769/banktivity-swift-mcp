// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export vault data",
        subcommands: [Turtle.self]
    )

    struct Turtle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "turtle",
            abstract: "Export vault as RDF/Turtle (.ttl)"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
        var output: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let turtle = try VaultExporter.exportTurtle(container: container, bankFilePath: path)

            if let output = output {
                try turtle.write(toFile: output, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(
                    "Exported to \(output)\n".data(using: .utf8)!
                )
            } else {
                print(turtle)
            }
        }
    }
}
