// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib
@testable import BanktivityMCPLib

/// `BANKTIVITY_MCP_STATEMENT_WRITES`: an opt-out that leaves the five statement
/// write tools out of the MCP registry, with the upstream default unchanged.
@Suite("Statement write tools option", .serialized)
@MainActor
struct StatementWriteToolsOptionTests {

    private func registered(statementWrites: Bool) throws -> [String: CapabilityAccess] {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools(statementWrites: statementWrites)
        return registry.registeredToolAccess()
    }

    @Test("unset, empty or any other value keeps the statement writes (upstream default)")
    func defaultIsOn() {
        #expect(ToolRegistry.statementWritesEnabled(environment: [:]))
        for value in ["", "1", "true", "yes", "on", "anything"] {
            #expect(ToolRegistry.statementWritesEnabled(
                environment: ["BANKTIVITY_MCP_STATEMENT_WRITES": value]))
        }
    }

    @Test("0, false, no and off turn the statement writes off, case- and space-insensitively")
    func offSpellings() {
        for value in ["0", "false", "no", "off", " OFF ", "False"] {
            #expect(!ToolRegistry.statementWritesEnabled(
                environment: ["BANKTIVITY_MCP_STATEMENT_WRITES": value]))
        }
    }

    @Test("off: the five write tools are absent and every statement read tool remains")
    func offRemovesOnlyTheWrites() throws {
        let on = try registered(statementWrites: true)
        let off = try registered(statementWrites: false)

        #expect(ToolRegistry.statementWriteToolNames.isSubset(of: Set(on.keys)))
        #expect(ToolRegistry.statementWriteToolNames.isDisjoint(with: Set(off.keys)))
        for name in ToolRegistry.statementWriteToolNames {
            #expect(on[name] == .write, "\(name) should be a write tool")
        }
        // Nothing else moves: the difference is exactly the five writes.
        #expect(Set(on.keys).subtracting(off.keys) == ToolRegistry.statementWriteToolNames)
        for name in ["list_statements", "get_statement", "get_account_reconciliation_status",
                     "plan_statement_visible_row_correction", "get_unreconciled_line_items"] {
            #expect(off[name] == .read, "\(name) must stay registered as a read")
        }
    }

    @Test("an absent statement write tool is refused as unknown at dispatch")
    func absentToolIsUnknown() async throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools(statementWrites: false)
        let result = await registry.callTool(name: "create_statement", arguments: [:])
        #expect(result.isError == true)
        #expect("\(result.content)".contains("Unknown tool: create_statement"))
    }
}
