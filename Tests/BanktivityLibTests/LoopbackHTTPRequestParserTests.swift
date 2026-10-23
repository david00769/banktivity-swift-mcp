// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityMCPLib

@Suite("Loopback HTTP request parser")
struct LoopbackHTTPRequestParserTests {

    private func request(_ head: String, body: String = "") -> Data {
        Data((head + "\r\n\r\n" + body).utf8)
    }

    @Test("A complete request parses, path without its query")
    func completeRequest() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let result = LoopbackHTTPRequestParser.parse(request(
            "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)", body: body))
        guard case .complete(let parsed) = result else {
            Issue.record("Expected complete, got \(result)"); return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/mcp")
        #expect(parsed.body == Data(body.utf8))
    }

    @Test("A head or body still arriving is incomplete")
    func partialRequests() {
        #expect(LoopbackHTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8)) == .incomplete)
        #expect(LoopbackHTTPRequestParser.parse(request("POST /mcp HTTP/1.1\r\nContent-Length: 10", body: "12345")) == .incomplete)
    }

    @Test("A negative or non-numeric Content-Length is a 400, not a crash")
    func badContentLength() {
        for value in ["-1", "abc", "1e3", ""] {
            let result = LoopbackHTTPRequestParser.parse(request("POST /mcp HTTP/1.1\r\nContent-Length: \(value)"))
            guard case .invalid(let status, _) = result else {
                Issue.record("Content-Length \(value): expected invalid, got \(result)"); continue
            }
            #expect(status == 400)
        }
    }

    @Test("Two Content-Length headers that disagree are refused")
    func conflictingContentLength() {
        let result = LoopbackHTTPRequestParser.parse(request(
            "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 5", body: "12345"))
        guard case .invalid(400, _) = result else {
            Issue.record("Expected 400, got \(result)"); return
        }
    }

    @Test("A chunked body is refused rather than read as empty")
    func chunkedBody() {
        let result = LoopbackHTTPRequestParser.parse(request(
            "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked", body: "5\r\nhello\r\n0\r\n\r\n"))
        guard case .invalid(400, _) = result else {
            Issue.record("Expected 400, got \(result)"); return
        }
    }

    @Test("An oversized declared length, or a head that never ends, is a 413")
    func oversized() {
        let declared = LoopbackHTTPRequestParser.parse(request(
            "POST /mcp HTTP/1.1\r\nContent-Length: \(LoopbackHTTPRequestParser.maxRequestBytes + 1)"))
        guard case .invalid(413, _) = declared else {
            Issue.record("Expected 413, got \(declared)"); return
        }
        let endless = Data(repeating: UInt8(ascii: "a"), count: LoopbackHTTPRequestParser.maxRequestBytes + 1)
        guard case .invalid(413, _) = LoopbackHTTPRequestParser.parse(endless) else {
            Issue.record("Expected 413 for a head with no end"); return
        }
    }

    @Test("A malformed request line is a 400")
    func malformedRequestLine() {
        guard case .invalid(400, _) = LoopbackHTTPRequestParser.parse(request("GARBAGE")) else {
            Issue.record("Expected 400"); return
        }
    }
}
