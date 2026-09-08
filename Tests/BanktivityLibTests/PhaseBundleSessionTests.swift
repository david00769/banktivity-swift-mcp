// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import CryptoKit
import Foundation
import Testing
@testable import BanktivityLib

/// What a phase bundle session does when one of its operations fails.
///
/// A failed *operation* is not a failed *session*. The clearest case is a
/// delete's readback: it asks whether the row is gone, and `not_found` is the
/// answer that proves the delete worked. Ending the session there left a bundle
/// unable to verify its own deletes -- the readback killed the executor and the
/// next operation met a dead process, *after* the delete had already committed.
///
/// The other half is the envelope. A one-shot run says why it failed twice,
/// through its exit code and its `Error: [category]` line. A session has
/// neither channel; without the category on the envelope a caller cannot tell
/// "the row is absent" from "the read did not work", and a delete becomes
/// self-certifying.
///
/// Both were previously covered only by a single-operation test, which cannot
/// observe either one.
@Suite("Phase bundle session", .serialized)
struct PhaseBundleSessionTests {

    private func cliURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let expectedBuildDirectory = "/debug/"
        #else
        let expectedBuildDirectory = "/release/"
        #endif
        guard let enumerator = FileManager.default.enumerator(
            at: packageRoot.appendingPathComponent(".build"),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "PhaseBundleSession", code: 1)
        }
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "banktivity-cli"
            && candidate.path.contains(expectedBuildDirectory)
            && !candidate.path.contains(".dSYM/") {
            if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return candidate
            }
        }
        throw NSError(domain: "PhaseBundleSession", code: 2)
    }

    /// Run an ordered bundle, sending `requests` and returning every envelope
    /// after the `ready` one. `requests` is separate from `operations` so a test
    /// can send something the bundle did not declare.
    private func runBundle(
        vaultPath: String,
        operations: [(id: String, args: [String])],
        requests: [(index: Int, id: String, args: [String])]
    ) throws -> (status: Int32, envelopes: [[String: Any]]) {
        let bundle: [String: Any] = [
            "schema_version": "banktivity_reconciliation_phase_bundle.v1",
            "vault": vaultPath,
            "phase": "session-semantics",
            "plan_sha256": String(repeating: "a", count: 64),
            "operations": operations.enumerated().map { index, operation in
                [
                    "operation_index": index,
                    "operation_id": operation.id,
                    "cli_args_template": operation.args,
                ]
            },
        ]
        let bundleData = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase-bundle-\(UUID().uuidString).json")
        try bundleData.write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = try cliURL()
        process.arguments = [
            "reconciliation", "execute-bundle",
            "--bundle", bundleURL.path,
            "--expected-sha256", SHA256.hash(data: bundleData).map { String(format: "%02x", $0) }.joined(),
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        for request in requests {
            let payload: [String: Any] = [
                "operation_index": request.index,
                "operation_id": request.id,
                "cli_args": request.args,
            ]
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            input.fileHandleForWriting.write(Data("\n".utf8))
        }
        try input.fileHandleForWriting.close()
        let raw = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        let envelopes: [[String: Any]] = raw
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(envelopes.first?["status"] as? String == "ready")
        return (process.terminationStatus, Array(envelopes.dropFirst()))
    }

    /// A vault with one readable transaction, copied so the executor opens a
    /// file no test context holds.
    private func seededVaultCopy() throws -> (path: String, transactionId: Int, cleanup: () -> Void) {
        let source = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: source.container)
        let accounts = AccountRepository(container: source.container)
        let lineItems = LineItemRepository(container: source.container)
        let transactions = TransactionRepository(container: source.container, lineItemRepo: lineItems)
        let account = try accounts.create(
            name: "Session semantics", accountClass: AccountClass.creditCard, currencyCode: "USD"
        )
        let transaction = try transactions.create(
            date: "2026-04-10", title: "Readable row",
            lineItems: [(accountId: account.id, amount: -42, memo: nil)]
        )
        let copyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase-bundle-copy-\(UUID().uuidString).bank8")
        try FileManager.default.copyItem(atPath: source.path, toPath: copyURL.path)
        TestVaultHelper.cleanup(source)
        return (copyURL.path, transaction.id, { try? FileManager.default.removeItem(at: copyURL) })
    }

    @Test("a failed operation leaves the session able to run the next one")
    func aFailedOperationDoesNotEndTheSession() throws {
        let vault = try seededVaultCopy()
        defer { vault.cleanup() }

        let present = ["transactions", "get", "--vault", vault.path, "\(vault.transactionId)", "--format", "compact"]
        let absent = ["transactions", "get", "--vault", vault.path, "999999999", "--format", "compact"]
        let operations = [(id: "read-present", args: present),
                          (id: "read-absent", args: absent),
                          (id: "read-present-again", args: present)]

        let run = try runBundle(
            vaultPath: vault.path,
            operations: operations,
            requests: operations.enumerated().map { (index: $0.offset, id: $0.element.id, args: $0.element.args) }
        )

        #expect(run.status == 0)
        #expect(run.envelopes.count == 3)

        #expect(run.envelopes[0]["status"] as? String == "completed")

        // The failure carries what a one-shot run would have said through its
        // exit code: absent, not broken.
        #expect(run.envelopes[1]["status"] as? String == "failed")
        #expect(run.envelopes[1]["category"] as? String == "not_found")
        #expect(run.envelopes[1]["exit_code"] as? Int == 66)

        // The operation after the failure is the whole point.
        #expect(run.envelopes[2]["status"] as? String == "completed")
        #expect(run.envelopes[2]["operation_id"] as? String == "read-present-again")
    }

    @Test("a request that does not match its bound template still ends the session at once")
    func aProtocolViolationStillTerminates() throws {
        let vault = try seededVaultCopy()
        defer { vault.cleanup() }

        let present = ["transactions", "get", "--vault", vault.path, "\(vault.transactionId)", "--format", "compact"]
        let unbound = ["transactions", "get", "--vault", vault.path, "123456789", "--format", "compact"]
        let operations = [(id: "bound", args: present), (id: "second", args: present)]

        // The first request asks for arguments the bundle never declared.
        let run = try runBundle(
            vaultPath: vault.path,
            operations: operations,
            requests: [(index: 0, id: "bound", args: unbound),
                       (index: 1, id: "second", args: present)]
        )

        #expect(run.envelopes.count == 1)
        #expect(run.envelopes[0]["status"] as? String == "failed")
        #expect((run.envelopes[0]["error"] as? String)?.contains("bound template") == true)
        // No category: this is the protocol refusing the request, not a command
        // reporting an outcome.
        #expect(run.envelopes[0]["category"] == nil)
    }
}
