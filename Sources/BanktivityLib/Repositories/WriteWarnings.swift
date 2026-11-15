// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Non-fatal problems a write hit after it committed (today: the running-balance
/// recalculation failed). stderr is invisible to an MCP client, so the CLI and
/// MCP layers read these and put them in the result they return.
///
/// MCP runs each tool call with its own box (`$current`), so concurrent calls
/// never see each other's warnings; the CLI is one process per command and uses
/// the process-wide box.
public final class WriteWarnings: @unchecked Sendable {
    @TaskLocal public static var current: WriteWarnings?
    public static let process = WriteWarnings()

    private let lock = NSLock()
    private var items: [String] = []

    public init() {}

    /// The box the calling task reports into.
    public static var active: WriteWarnings { current ?? process }

    public func add(_ message: String) {
        lock.lock(); items.append(message); lock.unlock()
    }

    public var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// Add `warnings` and `balancesStale` to a JSON-object result text. Anything
    /// that is not a JSON object is returned unchanged (the caller still has
    /// stderr / a separate content item for it).
    public func inject(into text: String) -> String {
        let found = messages
        guard !found.isEmpty,
              let data = text.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return text }
        object["warnings"] = ((object["warnings"] as? [String]) ?? []) + found
        object["balancesStale"] = true
        let options: JSONSerialization.WritingOptions = text.contains("\n") ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: options) else { return text }
        return String(data: out, encoding: .utf8) ?? text
    }
}
