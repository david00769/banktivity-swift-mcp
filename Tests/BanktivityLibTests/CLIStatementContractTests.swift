// Copyright (c) 2026 Steve Flinter. MIT License.

import CryptoKit
import Foundation
import Testing
@testable import BanktivityLib

@Suite("CLIStatementContract", .serialized)
struct CLIStatementContractTests {
    private func cliURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appendingPathComponent(".build")
        #if DEBUG
        let expectedBuildDirectory = "/debug/"
        #else
        let expectedBuildDirectory = "/release/"
        #endif
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "CLIStatementContract", code: 1, userInfo: [NSLocalizedDescriptionKey: "Swift build output is unavailable"])
        }
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "banktivity-cli"
            && candidate.path.contains(expectedBuildDirectory)
            && !candidate.path.contains(".dSYM/") {
            if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return candidate
            }
        }
        throw NSError(domain: "CLIStatementContract", code: 2, userInfo: [NSLocalizedDescriptionKey: "banktivity-cli test product is unavailable"])
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = try cliURL()
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func jsonObject(_ output: String) throws -> [String: Any] {
        let jsonLine = try #require(
            output.split(separator: "\n").reversed().first {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
            }
        )
        return try #require(
            JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any]
        )
    }

    private func runSingleOperationBundle(
        vaultPath: String,
        phase: String,
        operationId: String,
        cliArgs: [String]
    ) throws -> [String: Any] {
        let bundle: [String: Any] = [
            "schema_version": "banktivity_reconciliation_phase_bundle.v1",
            "vault": vaultPath,
            "phase": phase,
            "plan_sha256": String(repeating: "a", count: 64),
            "operations": [[
                "operation_index": 0,
                "operation_id": operationId,
                "cli_args_template": cliArgs,
            ]],
        ]
        let bundleData = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statement-phase-\(UUID().uuidString).json")
        try bundleData.write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let digest = SHA256.hash(data: bundleData).map { String(format: "%02x", $0) }.joined()

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = try cliURL()
        process.arguments = [
            "reconciliation", "execute-bundle",
            "--bundle", bundleURL.path,
            "--expected-sha256", digest,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let request: [String: Any] = [
            "operation_index": 0,
            "operation_id": operationId,
            "cli_args": cliArgs,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        input.fileHandleForWriting.write(requestData)
        input.fileHandleForWriting.write(Data("\n".utf8))
        try input.fileHandleForWriting.close()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let rows = (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        let envelopes = try rows.map { row in
            try jsonObject(String(row))
        }
        let completed = try #require(envelopes.last)
        #expect(completed["status"] as? String == "completed")
        return try #require(completed["payload"] as? [String: Any])
    }

    @Test("installed CLI exposes the explicit inspection and typed restore contracts")
    func statementCommandsAreAvailableAtTheProcessBoundary() throws {
        let inspection = try runCLI(["statements", "inspect-membership", "--help"])
        #expect(inspection.status == 0)
        #expect(inspection.output.contains("--line-item-id"))

        let syncInspection = try runCLI(["statements", "inspect-sync-record", "--help"])
        #expect(syncInspection.status == 0)
        #expect(syncInspection.output.contains("<statement-id>"))

        let replacement = try runCLI(["statements", "replace-internal-row-with-visible-statement", "--help"])
        #expect(replacement.status == 0)
        #expect(replacement.output.contains("--preimage-sha256"))
        #expect(replacement.output.contains("--membership-preimage-sha256"))
        #expect(replacement.output.contains("--replacement-membership-preimage-sha256"))

        let restore = try runCLI(["statements", "restore-internal-row-from-preimage", "--help"])
        #expect(restore.status == 0)
        #expect(restore.output.contains("--statement-preimage-json"))
        #expect(restore.output.contains("--line-item-memberships-json"))
        #expect(restore.output.contains("--replacement-line-item-ids"))
        #expect(restore.output.contains("--replacement-membership-preimage-sha256"))
        #expect(restore.output.contains("--replacement-preimage-sha256"))

        let create = try runCLI(["statements", "create", "--help"])
        #expect(create.status == 0)
        #expect(create.output.contains("--line-item-ids"))

        let bundle = try runCLI(["reconciliation", "execute-bundle", "--help"])
        #expect(bundle.status == 0)
        #expect(bundle.output.contains("--expected-sha256"))
    }

    @Test("phase bundle proves disposable copied-vault statement create inverse replay membership closure")
    func copiedVaultStatementCreateInverseReplayClosure() throws {
        let source = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(source) }
        _ = try TestVaultHelper.seedCurrencies(in: source.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: source.container)
        let accounts = AccountRepository(container: source.container)
        let lineItems = LineItemRepository(container: source.container)
        let transactions = TransactionRepository(container: source.container, lineItemRepo: lineItems)
        let account = try accounts.create(
            name: "Bundled statement closure", accountClass: AccountClass.creditCard, currencyCode: "USD"
        )
        let transaction = try transactions.create(
            date: "2026-04-10", title: "Statement membership",
            lineItems: [(accountId: account.id, amount: -42, memo: nil)]
        )
        let lineItemId = try #require(transaction.lineItems.first { $0.accountId == account.id }?.id)

        let copiedVaultURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statement-closure-copy-\(UUID().uuidString).bank8")
        try FileManager.default.copyItem(atPath: source.path, toPath: copiedVaultURL.path)
        defer { try? FileManager.default.removeItem(at: copiedVaultURL) }

        let createArgs = [
            "statements", "create", "--vault", copiedVaultURL.path,
            "--account-id", "\(account.id)",
            "--start-date", "2026-04-01", "--end-date", "2026-04-30",
            "--beginning-balance", "0", "--ending-balance", "-42",
            "--line-item-ids", "\(lineItemId)",
            "--backup-confirmed", "--post-ui-verification-required",
            "--operator-confirmed-visible", "--format", "compact",
        ]
        let firstCreate = try runSingleOperationBundle(
            vaultPath: copiedVaultURL.path, phase: "forward",
            operationId: "create-visible-statement", cliArgs: createArgs
        )
        let firstId = try #require(firstCreate["id"] as? Int)
        let firstStatement = try runCLI([
            "statements", "get", "\(firstId)", "--vault", copiedVaultURL.path,
            "--format", "compact",
        ])
        #expect(firstStatement.status == 0)
        let firstReadback = try jsonObject(firstStatement.output)
        #expect(firstReadback["reconciledLineItemCount"] as? Int == 1)
        #expect(
            ((firstReadback["lineItems"] as? [[String: Any]])?.compactMap { $0["id"] as? Int })
                == [lineItemId]
        )

        let inverseArgs = [
            "statements", "delete", "\(firstId)", "--vault", copiedVaultURL.path,
            "--backup-confirmed", "--post-ui-verification-required", "--format", "compact",
        ]
        _ = try runSingleOperationBundle(
            vaultPath: copiedVaultURL.path, phase: "inverse",
            operationId: "delete-visible-statement", cliArgs: inverseArgs
        )
        let inverseStatus = try runCLI([
            "statements", "status", "--account-id", "\(account.id)",
            "--vault", copiedVaultURL.path, "--format", "compact",
        ])
        #expect(inverseStatus.status == 0)
        #expect((try jsonObject(inverseStatus.output))["hasReconciledStatements"] as? Bool == false)

        let replayCreate = try runSingleOperationBundle(
            vaultPath: copiedVaultURL.path, phase: "replay",
            operationId: "replay-create-visible-statement", cliArgs: createArgs
        )
        let replayId = try #require(replayCreate["id"] as? Int)
        let replayStatement = try runCLI([
            "statements", "get", "\(replayId)", "--vault", copiedVaultURL.path,
            "--format", "compact",
        ])
        #expect(replayStatement.status == 0)
        let replayReadback = try jsonObject(replayStatement.output)
        #expect(replayReadback["reconciledLineItemCount"] as? Int == 1)
        #expect(
            ((replayReadback["lineItems"] as? [[String: Any]])?.compactMap { $0["id"] as? Int })
                == [lineItemId]
        )
    }
}
