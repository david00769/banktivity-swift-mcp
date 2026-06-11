// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Capabilities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List CLI and MCP capabilities as stable JSON"
    )

    @Option(name: .long, help: "Output format: json (pretty-printed) or compact (single-line)")
    var format: OutputFormat = .json

    func run() async throws {
        try outputJSON(CapabilityRegistry.report(), format: format)
    }
}
