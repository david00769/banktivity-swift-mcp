// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Serializes Core Data write contexts inside the current process.
///
/// This covers concurrent MCP tool calls handled by one `banktivity-mcp` server
/// process and overlapping writes inside one CLI command. It does not coordinate
/// two separate `banktivity-cli` or `banktivity-mcp` processes pointed at the
/// same vault.
enum CoreDataWriteCoordinator {
    private static let queueKey = DispatchSpecificKey<Void>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.sflinter.banktivity-swift-mcp.core-data-writes")
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    static func perform<T>(_ block: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }
}
