// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Request parsing for `banktivity-mcp`'s loopback HTTP mode.
///
/// It lives here rather than beside the listener in the executable target so
/// the tests can reach it: the refusals below are the server's whole defence
/// against a malformed request from another local process.
public enum LoopbackHTTPRequestParser {
    /// Largest request head plus body the server buffers. MCP requests are
    /// small JSON; the cap only exists so a local client cannot grow the
    /// buffer without bound.
    public static let maxRequestBytes = 16 << 20

    public struct Request: Sendable, Equatable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data
    }

    public enum Result: Sendable, Equatable {
        case incomplete
        case invalid(status: Int, reason: String)
        case complete(Request)
    }

    /// `.incomplete` until the full head and (Content-Length) body have arrived.
    ///
    /// Refused rather than trusted: a Content-Length that is not plain digits (a
    /// negative one used to form an inverted range and crash the process), two
    /// Content-Length headers that disagree (which one won depended on
    /// dictionary order), a chunked body (not supported, and previously read as
    /// empty), and anything over `maxRequestBytes`.
    public static func parse(_ data: Data) -> Result {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxRequestBytes ? .invalid(status: 413, reason: "request too large") : .incomplete
        }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(status: 400, reason: "bad request") }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid(status: 400, reason: "bad request") }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        var lengthValues: [String] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "content-length":
                lengthValues.append(value)
            case "transfer-encoding" where value.lowercased() != "identity":
                return .invalid(status: 400, reason: "transfer-encoding not supported")
            default:
                break
            }
            headers[name] = value
        }

        let length: Int
        if lengthValues.isEmpty {
            length = 0
        } else {
            let value = lengthValues[0]
            guard Set(lengthValues).count == 1, !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber),
                  let parsed = Int(value) else {
                return .invalid(status: 400, reason: "bad content-length")
            }
            length = parsed
        }
        guard length <= maxRequestBytes else { return .invalid(status: 413, reason: "request too large") }

        let bodyStart = headEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(Request(method: method, path: path, headers: headers, body: Data(body)))
    }
}
