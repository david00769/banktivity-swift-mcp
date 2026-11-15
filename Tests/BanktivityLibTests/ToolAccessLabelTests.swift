// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib
@testable import BanktivityMCPLib

/// MCP clients may relax approval for a tool advertised as read-only, so a
/// write labelled `.read` must never get through. Every write tool calls
/// `guardWriteAccess` before touching the vault; this reads the tool sources
/// and checks each registration's label against that call.
@Suite("MCP tool access labels", .serialized)
@MainActor
struct ToolAccessLabelTests {

    private struct Registration {
        let name: String
        let access: String?
        let guardsWrites: Bool
    }

    private func registrations() throws -> [Registration] {
        let mcpDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BanktivityMCPLib/MCP")
        let files = try FileManager.default
            .contentsOfDirectory(at: mcpDir.appendingPathComponent("Tools"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" } + [mcpDir.appendingPathComponent("ToolRegistry.swift")]

        let nameRegex = try NSRegularExpression(pattern: #"name: "([a-z_]+)""#)
        let accessRegex = try NSRegularExpression(pattern: #"access: \.([a-z]+)"#)
        var result: [Registration] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Each block runs from one register( call to the next.
            let blocks = source.components(separatedBy: "register(\n").dropFirst()
            for block in blocks {
                let range = NSRange(block.startIndex..., in: block)
                guard let nameMatch = nameRegex.firstMatch(in: block, range: range),
                      let nameRange = Range(nameMatch.range(at: 1), in: block) else { continue }
                let access = accessRegex.firstMatch(in: block, range: range)
                    .flatMap { Range($0.range(at: 1), in: block) }
                    .map { String(block[$0]) }
                result.append(Registration(
                    name: String(block[nameRange]),
                    access: access,
                    guardsWrites: block.contains("guardWriteAccess")
                ))
            }
        }
        return result
    }

    @Test("No tool that guards writes is labelled read-only")
    func writesAreNeverReadOnly() throws {
        let regs = try registrations()
        #expect(regs.count > 60, "expected to find every registration, found \(regs.count)")
        let mislabelled = regs.filter { $0.guardsWrites && $0.access == "read" }.map(\.name)
        #expect(mislabelled.isEmpty, "write tools labelled read: \(mislabelled)")
    }

    @Test("Every tool that never guards writes is labelled read, except file export")
    func readsAreLabelled() throws {
        let unlabelled = try registrations()
            .filter { !$0.guardsWrites && $0.access != "read" && $0.name != "export_turtle" }
            .map(\.name)
        #expect(unlabelled.isEmpty, "read tools not labelled .read: \(unlabelled)")
    }

    @Test("Source labels agree with the access each tool is registered under")
    func sourceLabelsMatchRegistry() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools()
        let registered = registry.registeredToolAccess()
        for reg in try registrations() {
            guard let actual = registered[reg.name], let label = reg.access else { continue }
            #expect(actual.rawValue == label, "\(reg.name): source says .\(label), registered \(actual.rawValue)")
        }
    }

    @Test("Every additive tool is a registered write tool, and add_line_item is additive")
    func additiveToolsAreWrites() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools(statementWrites: true)
        let registered = registry.registeredToolAccess()
        for name in ToolRegistry.additiveToolNames {
            #expect(registered[name] == .write, "\(name) is additive but not a registered write tool")
        }
        #expect(ToolRegistry.additiveToolNames.contains("add_line_item"))
        #expect(ToolRegistry.annotations(for: "add_line_item", access: .write).destructiveHint == false)
    }
}
