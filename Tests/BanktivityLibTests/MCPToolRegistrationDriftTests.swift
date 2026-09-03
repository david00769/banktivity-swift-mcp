// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib
@testable import BanktivityMCPLib

/// What a registered tool actually is, against what the capability report says it is.
///
/// `mcpCapabilities()` is a hand-written literal array and `registerAllTools()` is
/// imperative registration, so the two drifted in both directions with nothing to
/// notice: names were advertised that no tool implemented, and tools were reachable
/// over stdio that the report never mentioned -- several of them writes.
///
/// The existing `CapabilityRegistryTests` could not catch either, because it
/// asserted a count and spot-checked names. A count says something moved; it never
/// says what, and it passes happily while a phantom name sits in the list.
@Suite("MCP tool registration drift", .serialized)
struct MCPToolRegistrationDriftTests {

    private func makeRegistry() throws -> (ToolRegistry, TestVaultHelper.TestVault) {
        let vault = try TestVaultHelper.createFreshVault()
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools()
        return (registry, vault)
    }

    @Test("every registered tool is declared, and every declared tool is registered")
    func registrationAndDeclarationAgree() throws {
        let (registry, vault) = try makeRegistry()
        defer { TestVaultHelper.cleanup(vault) }

        let registered = registry.registeredToolAccess()
        let declared = Dictionary(
            uniqueKeysWithValues: CapabilityRegistry.mcpCapabilities().map { ($0.name, $0.access) }
        )

        let undeclared = Set(registered.keys).subtracting(declared.keys).sorted()
        let unregistered = Set(declared.keys).subtracting(registered.keys).sorted()

        #expect(undeclared.isEmpty, "registered but never declared: \(undeclared)")
        #expect(unregistered.isEmpty, "declared but never registered: \(unregistered)")
    }

    @Test("a tool's declared access matches the access it is registered under")
    func declaredAccessMatchesRegisteredAccess() throws {
        let (registry, vault) = try makeRegistry()
        defer { TestVaultHelper.cleanup(vault) }

        let registered = registry.registeredToolAccess()
        let declared = Dictionary(
            uniqueKeysWithValues: CapabilityRegistry.mcpCapabilities().map { ($0.name, $0.access) }
        )

        // The dangerous direction is declared-read / registered-write: the read-only
        // proxy builds its allowlist from the declaration, so a write advertised as
        // a read is a write let through the transport.
        let disagreements = registered
            .compactMap { name, access -> String? in
                guard let expected = declared[name], expected != access else { return nil }
                return "\(name): registered \(access.rawValue), declared \(expected.rawValue)"
            }
            .sorted()

        #expect(disagreements.isEmpty, "\(disagreements)")
    }

    @Test("requiresWriteMode is never at odds with access")
    func requiresWriteModeFollowsAccess() {
        for capability in CapabilityRegistry.report().commands + CapabilityRegistry.report().tools {
            #expect(
                capability.requiresWriteMode == (capability.access == .write),
                "\(capability.name) declares access \(capability.access.rawValue) with requiresWriteMode \(capability.requiresWriteMode)"
            )
        }
    }

    @Test("a write tool is refused while the store is read-only")
    func writeToolIsRefusedUnderReadOnlyStore() async throws {
        let (registry, vault) = try makeRegistry()
        defer { TestVaultHelper.cleanup(vault) }

        let previous = ProcessInfo.processInfo.environment["BANKTIVITY_STORE_READ_ONLY"]
        setenv("BANKTIVITY_STORE_READ_ONLY", "1", 1)
        defer {
            if let previous { setenv("BANKTIVITY_STORE_READ_ONLY", previous, 1) }
            else { unsetenv("BANKTIVITY_STORE_READ_ONLY") }
        }

        let result = await registry.callTool(name: "delete_transaction", arguments: ["id": .int(1)])
        let text = result.content.compactMap { content -> String? in
            if case let .text(value) = content { return value.text }
            return nil
        }.joined()

        #expect(result.isError == true)
        #expect(text.contains("write tool"), "expected a write refusal, got: \(text)")
    }
}
