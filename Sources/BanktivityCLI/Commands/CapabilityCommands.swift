// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Capabilities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Show supported CLI and MCP capabilities as stable JSON",
        discussion: """
        Use this command before planning work. The report identifies read and write
        operations, write-mode requirements, dry-run support, required confirmations,
        UI-verification requirements, and safety notes.

        The default output is pretty-printed JSON for people. Use --format compact
        for one line of JSON when a script needs to consume the report.
        """
    )

    @Option(name: .long, help: "Output format: json (pretty-printed) or compact (single-line)")
    var format: OutputFormat = .json

    func run() async throws {
        try outputJSON(CapabilityRegistry.report(), format: format)
    }
}
