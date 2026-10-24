// Copyright (c) 2026 Steve Flinter. MIT License.

import BanktivityMCPLib
import CoreData
import Foundation
import MCP

// MARK: - Configuration

// An empty or unset BANKTIVITY_FILE_PATH means "find the Banktivity 10 vault".
let bankFilePath: String
do {
    bankFilePath = try VaultLocator.resolve(ProcessInfo.processInfo.environment["BANKTIVITY_FILE_PATH"])
} catch {
    FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardError.write("Vault: \(bankFilePath)\n".data(using: .utf8)!)

// MARK: - Core Data Setup

let container: NSPersistentContainer
do {
    container = try PersistentContainerFactory.create(
        bankFilePath: bankFilePath,
        readOnly: PersistentContainerFactory.readOnlyFromEnvironment
    )
    FileHandle.standardError.write(
        "Core Data container loaded successfully\n".data(using: .utf8)!
    )
} catch {
    FileHandle.standardError.write(
        "Failed to initialize Core Data: \(error)\n".data(using: .utf8)!
    )
    exit(1)
}

// MARK: - Write Guard

let dbPath =
    URL(fileURLWithPath: bankFilePath)
    .appendingPathComponent("StoreContent")
    .appendingPathComponent("core.sql")
    .path
let writeGuard = WriteGuard(dbPath: dbPath)
// Same choke point as the CLI: a tool that never calls the guard is still
// refused at the write rather than relying on every handler remembering.
VaultWriteGate.install(writeGuard.monitor.writeRefusal)

// MARK: - Tool Registry

let registry = ToolRegistry(
    container: container,
    writeGuard: writeGuard,
    bankFilePath: bankFilePath
)
registry.registerAllTools()

// MARK: - MCP Server

let server = Server(
    name: "banktivity-mcp",
    version: version,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: registry.listTools())
}

await server.withMethodHandler(CallTool.self) { params in
    await registry.callTool(name: params.name, arguments: params.arguments)
}

// MARK: - Start Server

// BANKTIVITY_HTTP_PORT selects the long-lived loopback HTTP mode (see
// HTTPServer.swift for why it exists). Unset = classic stdio, unchanged.
if let portText = ProcessInfo.processInfo.environment["BANKTIVITY_HTTP_PORT"] {
    guard let port = UInt16(portText), port > 0 else {
        FileHandle.standardError.write(
            "Error: BANKTIVITY_HTTP_PORT must be a port number, got '\(portText)'\n".data(using: .utf8)!
        )
        exit(1)
    }
    let path = ProcessInfo.processInfo.environment["BANKTIVITY_HTTP_PATH"] ?? "/mcp"
    let transport = makeLoopbackTransport()
    try await server.start(transport: transport)
    let http = try LoopbackHTTPServer(port: port, path: path, transport: transport)
    http.start()
    await server.waitUntilCompleted()
} else {
    FileHandle.standardError.write(
        "Banktivity MCP server starting on stdio\n".data(using: .utf8)!
    )
    let transport = StdioTransport()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
}
