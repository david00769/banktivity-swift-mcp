// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("CapabilityRegistry")
struct CapabilityRegistryTests {
    @Test("capability report exposes write mode and safety metadata")
    func capabilityReportExposesWriteMetadata() throws {
        let report = CapabilityRegistry.report()
        #expect(report.schemaVersion == 1)
        #expect(!report.commands.isEmpty)
        #expect(!report.tools.isEmpty)
        #expect(report.commands.count == 82)

        let commandNames = Set(report.commands.map(\.name))
        for name in [
            "categories audit-entities",
            "transactions repair-forex",
            "statements status",
            "statements inspect-membership",
            "statements inspect-sync-record",
            "statements visible-row-correction-plan",
            "statements update",
            "statements replace-internal-row-with-visible-statement",
            "statements restore-internal-row-from-preimage",
            "securities create-trade",
            "securities create-income",
        ] {
            #expect(commandNames.contains(name))
        }

        let reconciliation = try #require(
            report.commands.first { $0.name == "reconciliation execute-bundle" }
        )
        #expect(reconciliation.access == "write")
        #expect(reconciliation.requiresWriteMode)
        #expect(reconciliation.notes.contains { $0.contains("hash-bound phase bundle") })

        let transactionCreate = try #require(report.commands.first { $0.name == "transactions create" })
        #expect(transactionCreate.access == "write")
        #expect(transactionCreate.requiresWriteMode)
        #expect(!transactionCreate.supportsDryRun)

        let bulkRecategorize = try #require(report.tools.first { $0.name == "bulk_recategorize" })
        #expect(bulkRecategorize.supportsDryRun)

        let lineItemUpdate = try #require(report.tools.first { $0.name == "update_line_item" })
        #expect(lineItemUpdate.requiredConfirmations.contains("operator_reviewed_target"))
        #expect(lineItemUpdate.uiVerificationRequired)
        #expect(lineItemUpdate.notes.contains { $0.contains("Line-item writes affect balances") })

        let statementDelete = try #require(report.commands.first { $0.name == "statements delete" })
        #expect(statementDelete.notes.contains { $0.contains("allow_internal") })
        let deleteStatementTool = try #require(report.tools.first { $0.name == "delete_statement" })
        #expect(deleteStatementTool.notes.contains { $0.contains("allow_internal") })

        let capabilitiesTool = try #require(report.tools.first { $0.name == "get_capabilities" })
        #expect(capabilitiesTool.access == "read")
        #expect(!capabilitiesTool.requiresWriteMode)
    }
}
