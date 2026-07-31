// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing

@Suite("CLIStatementContract", .serialized)
struct CLIStatementContractTests {
    private func cliURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appendingPathComponent(".build")
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "CLIStatementContract", code: 1, userInfo: [NSLocalizedDescriptionKey: "Swift build output is unavailable"])
        }
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "banktivity-cli"
            && candidate.path.contains("/debug/")
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
    }
}
