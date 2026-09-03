// Hash-bound persistent execution surface for one reconciliation phase.

import ArgumentParser
import BanktivityLib
import CryptoKit
import Foundation

struct Reconciliation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute a reviewed, hash-bound reconciliation phase",
        discussion: """
        This command runs an ordered phase bundle whose bytes, vault, operation
        order, and nested command shapes are checked before execution. It is intended
        for the reconciliation workflow, not for ad-hoc command batching.
        """,
        subcommands: [ExecuteBundle.self]
    )

    struct BundleOperation: Decodable {
        let operationIndex: Int
        let operationId: String
        let cliArgsTemplate: [String]

        enum CodingKeys: String, CodingKey {
            case operationIndex = "operation_index"
            case operationId = "operation_id"
            case cliArgsTemplate = "cli_args_template"
        }
    }

    struct PhaseBundle: Decodable {
        let schemaVersion: String
        let vault: String
        let phase: String
        let planSha256: String
        let operations: [BundleOperation]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case vault, phase
            case planSha256 = "plan_sha256"
            case operations
        }
    }

    struct OperationRequest: Decodable {
        let operationIndex: Int
        let operationId: String
        let cliArgs: [String]

        enum CodingKeys: String, CodingKey {
            case operationIndex = "operation_index"
            case operationId = "operation_id"
            case cliArgs = "cli_args"
        }
    }

    struct ExecuteBundle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "execute-bundle",
            abstract: "Execute a reviewed hash-bound phase bundle over one Core Data stack",
            discussion: """
            The bundle must be the exact file reviewed by the caller. Its SHA-256
            digest is checked before any operation is read, and each operation must
            arrive in the declared order with the declared arguments. The local
            guarded wrapper classifies every nested command before this command is
            started.
            """
        )

        @Option(name: .long, help: "Absolute phase bundle path")
        var bundle: String

        @Option(name: .long, help: "Expected SHA-256 of the exact bundle bytes")
        var expectedSha256: String

        func run() async throws {
            let bundleURL = URL(fileURLWithPath: bundle)
            let data = try Data(contentsOf: bundleURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSha256.lowercased() else {
                throw ValidationError("Phase bundle digest mismatch")
            }
            let phaseBundle = try JSONDecoder().decode(PhaseBundle.self, from: data)
            guard phaseBundle.schemaVersion == "banktivity_reconciliation_phase_bundle.v1",
                  !phaseBundle.operations.isEmpty else {
                throw ValidationError("Phase bundle schema or operations are invalid")
            }
            emitEnvelope([
                "status": "ready",
                "phase": phaseBundle.phase,
                "plan_sha256": phaseBundle.planSha256,
                "operation_count": phaseBundle.operations.count,
            ])

            for expected in phaseBundle.operations {
                guard let line = readLine(), let requestData = line.data(using: .utf8) else {
                    return
                }
                let request: OperationRequest
                do {
                    request = try JSONDecoder().decode(OperationRequest.self, from: requestData)
                } catch {
                    emitEnvelope(["status": "failed", "error": "malformed operation request: \(error)"])
                    return
                }
                guard request.operationIndex == expected.operationIndex,
                      request.operationId == expected.operationId,
                      resolvedArguments(request.cliArgs, match: expected.cliArgsTemplate) else {
                    emitEnvelope([
                        "status": "failed",
                        "operation_id": request.operationId,
                        "error": "operation request does not match the bound template or order",
                    ])
                    return
                }
                var captured: String?
                CLIProcessState.shared.beginOutputCapture { captured = $0 }
                do {
                    var command = try BanktivityCLI.parseAsRoot(request.cliArgs)
                    if var asyncCommand = command as? AsyncParsableCommand {
                        try await asyncCommand.run()
                    } else {
                        try command.run()
                    }
                    CLIProcessState.shared.endOutputCapture()
                    guard let captured, let payloadData = captured.data(using: .utf8) else {
                        throw ValidationError("operation emitted no JSON result")
                    }
                    let payload = try JSONSerialization.jsonObject(with: payloadData)
                    emitEnvelope([
                        "status": "completed",
                        "operation_id": request.operationId,
                        "operation_index": request.operationIndex,
                        "payload": payload,
                    ])
                } catch {
                    CLIProcessState.shared.endOutputCapture()
                    // A one-shot CLI run reports *why* it failed twice: the exit
                    // code and the `Error: [<category>] ...` stderr line, both
                    // derived from `cliExitCategory` (CLI.swift). A session has
                    // neither channel -- it has this envelope -- and callers
                    // depend on the distinction. Reading a row that is genuinely
                    // absent must not look like a read that failed, or a delete's
                    // readback becomes self-certifying: it asks whether the row is
                    // gone and a broken read answers "gone". So carry the category
                    // rather than making the caller parse the message text.
                    var envelope: [String: Any] = [
                        "status": "failed",
                        "operation_id": request.operationId,
                        "operation_index": request.operationIndex,
                        "error": String(describing: error),
                    ]
                    let category = (error as? ToolError)?.cliExitCategory
                        ?? (error as? RepositoryError)?.cliExitCategory
                    if let category {
                        envelope["category"] = category.rawValue
                        envelope["exit_code"] = Int(category.exitCode)
                    }
                    emitEnvelope(envelope)
                    return
                }
            }
        }

        private func resolvedArguments(_ actual: [String], match template: [String]) -> Bool {
            guard actual.count == template.count else { return false }
            let capturePattern = try! NSRegularExpression(
                pattern: #"^\{\{capture:[A-Za-z0-9_.-]+\.[A-Za-z0-9_-]+\}\}$"#
            )
            for (resolved, bound) in zip(actual, template) {
                if resolved == bound { continue }
                let range = NSRange(bound.startIndex..<bound.endIndex, in: bound)
                if capturePattern.firstMatch(in: bound, range: range) == nil { return false }
                if resolved.isEmpty || resolved.hasPrefix("--") { return false }
            }
            return true
        }

        private func emitEnvelope(_ value: [String: Any]) {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                return
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
