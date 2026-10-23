// Copyright (c) 2026 Steve Flinter. MIT License.
//
// Minimal HTTP/1.1 front end for the MCP Streamable HTTP transport.
//
// Why this exists: on macOS the permission to read Banktivity's data is judged
// against whichever app spawned the server process. When a client such as
// Claude Desktop spawns banktivity-mcp per session, every launch re-prompts
// ("banktivity-mcp would like to access data from other apps") and the answer
// does not stick. Running ONE long-lived server under launchd, and having
// clients connect over loopback HTTP, means the process that reads the vault
// is never spawned by a client at all — so it is never prompted.
//
// The MCP Swift SDK's HTTP transports are framework-agnostic: they hand you a
// `handleRequest(HTTPRequest) -> HTTPResponse` and expect you to bring the
// listener. This is that listener: Network.framework, loopback only, one
// request per connection, no keep-alive, no TLS. It is not a general web
// server and does not try to be.

import BanktivityMCPLib
import Foundation
import MCP
import Network

// The transport's default pipeline demands `application/json` in Accept.
// Real clients (mcp-remote, Claude Code) send `application/json, text/event-stream`,
// which passes — but any client that omits Accept entirely would be rejected
// with a 406 for no benefit on a loopback-only server, so Accept is not
// validated here. Origin, Content-Type and protocol-version checks stay.
func makeLoopbackTransport() -> StatelessHTTPServerTransport {
    StatelessHTTPServerTransport(
        validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    )
}

final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let transport: StatelessHTTPServerTransport
    private let mcpPath: String
    private let queue = DispatchQueue(label: "banktivity-mcp.http")

    // The SDK's `Server` is a single-session object: it accepts exactly one
    // `initialize` and rejects every later one with "already initialized".
    // This daemon serves many clients (Claude Code, Claude Desktop's session
    // pool, Paperclip agents), each of which starts with its own `initialize`.
    // The first one is forwarded and its result kept; every caller, including
    // ones that arrive while the first is still in flight, gets that result
    // back under its own request id. Everything else (tools/list, tools/call)
    // is session-independent and forwards as-is.
    private let initializeOnce = InitializeOnce()

    init(port: UInt16, path: String, transport: StatelessHTTPServerTransport) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only. Nothing about this server is safe to expose.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: params)
        self.transport = transport
        self.mcpPath = path
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.readRequest(conn, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let err):
                FileHandle.standardError.write("HTTP listener failed: \(err)\n".data(using: .utf8)!)
                exit(1)
            case .ready:
                FileHandle.standardError.write("Banktivity MCP server listening on http://127.0.0.1:\(self.listener.port!.rawValue)\(self.mcpPath)\n".data(using: .utf8)!)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    // MARK: - Request parsing

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if error != nil { conn.cancel(); return }

            switch LoopbackHTTPRequestParser.parse(buf) {
            case .complete(let parsed):
                Task { await self.respond(conn, to: parsed) }
                return
            case .invalid(let status, let reason):
                self.write(conn, status: status, headers: [:], body: Data("\(reason)\n".utf8))
                return
            case .incomplete:
                break
            }
            if isComplete {
                self.write(conn, status: 400, headers: [:], body: Data("bad request\n".utf8))
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    // MARK: - Response

    private func respond(_ conn: NWConnection, to req: LoopbackHTTPRequestParser.Request) async {
        guard req.path == mcpPath else {
            write(conn, status: 404, headers: [:], body: Data("not found\n".utf8))
            return
        }
        let request = HTTPRequest(method: req.method, headers: req.headers, body: req.body.isEmpty ? nil : req.body, path: req.path)
        if let (method, id) = jsonRPCMethod(req.body), method == "initialize" {
            // A replayed result never reaches the transport, so its Origin and
            // Content-Type checks are repeated here first.
            if let refusal = Self.initializeRefusal(req.headers) {
                write(conn, status: refusal.status, headers: [:], body: Data("\(refusal.reason)\n".utf8))
                return
            }
            let transport = self.transport
            let outcome = await initializeOnce.run {
                InitializeOutcome(await transport.handleRequest(request))
            }
            switch outcome {
            case .shared(let result):
                if let reply = Self.initializeReply(id: id, result: result) {
                    write(conn, status: 200, headers: ["Content-Type": "application/json"], body: reply)
                } else {
                    write(conn, status: 500, headers: [:], body: Data("could not replay initialize\n".utf8))
                }
            case .own(let own):
                // This caller's request was the one forwarded: it gets the
                // transport's answer as-is, success or failure.
                write(conn, status: own.status, headers: own.headers, body: own.body)
            }
            return
        }

        let response = await transport.handleRequest(request)

        switch response {
        case .stream(let stream, let headers):
            // Not produced by the stateless transport, but handle it so a
            // future switch to the stateful transport does not silently break.
            var h = headers
            h["Content-Type"] = "text/event-stream"
            h["Cache-Control"] = "no-cache"
            writeHead(conn, status: 200, headers: h, chunked: true)
            do {
                for try await chunk in stream { writeChunk(conn, chunk) }
            } catch {}
            writeChunk(conn, Data())  // terminating chunk
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        default:
            write(conn, status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
        }
    }

    private func jsonRPCMethod(_ body: Data) -> (method: String, id: Any?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = obj["method"] as? String else { return nil }
        return (method, obj["id"])
    }

    /// The transport's Origin and Content-Type rules, for an `initialize` that
    /// may be answered from the shared result without reaching the transport.
    private static func initializeRefusal(_ headers: [String: String]) -> (status: Int, reason: String)? {
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name }?.value
        }
        if let origin = header("origin"),
           let host = URL(string: origin)?.host?.lowercased(),
           !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            return (403, "forbidden origin")
        }
        if let origin = header("origin"), URL(string: origin)?.host == nil {
            return (403, "forbidden origin")
        }
        guard let contentType = header("content-type")?.lowercased(),
              contentType.hasPrefix("application/json") else {
            return (415, "content-type must be application/json")
        }
        return nil
    }

    private static func initializeReply(id: Any?, result: Data) -> Data? {
        guard let resultObject = try? JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed]) else { return nil }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": resultObject]
        return try? JSONSerialization.data(withJSONObject: reply)
    }

    private func writeHead(_ conn: NWConnection, status: Int, headers: [String: String], chunked: Bool) {
        var out = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var h = headers
        h["Connection"] = "close"
        if chunked { h["Transfer-Encoding"] = "chunked" }
        for (k, v) in h { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        conn.send(content: Data(out.utf8), completion: .contentProcessed { _ in })
    }

    private func writeChunk(_ conn: NWConnection, _ data: Data) {
        var frame = Data(String(format: "%x\r\n", data.count).utf8)
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func write(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        var h = headers
        h["Content-Length"] = String(body.count)
        if h["Content-Type"] == nil && !body.isEmpty { h["Content-Type"] = "application/json" }
        writeHead(conn, status: status, headers: h, chunked: false)
        conn.send(content: body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        default: "Status"
        }
    }
}

/// The transport's answer to one forwarded `initialize`, and its `result`
/// member when it succeeded.
struct InitializeOutcome: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let result: Data?

    init(_ response: HTTPResponse) {
        status = response.statusCode
        headers = response.headers
        body = response.bodyData ?? Data()
        if case .data(let data, _) = response,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let member = obj["result"] {
            result = try? JSONSerialization.data(withJSONObject: member, options: [.fragmentsAllowed])
        } else {
            result = nil
        }
    }
}

/// Forwards at most one `initialize` at a time and shares the first success
/// with every caller. The previous optional cache was read and written from
/// concurrent tasks with no synchronisation, so two clients initializing
/// together could both be forwarded and the second refused by the
/// single-session server. Nothing here forwards outside the actor: a caller
/// that waited on an attempt that failed loops and becomes the next forwarder,
/// so a failure never leaves the server initialized with nothing shared.
actor InitializeOnce {
    enum Outcome: Sendable {
        case shared(Data)
        case own(InitializeOutcome)
    }

    private var shared: Data?
    private var pending: Task<InitializeOutcome, Never>?

    func run(_ forward: @escaping @Sendable () async -> InitializeOutcome) async -> Outcome {
        while true {
            if let shared { return .shared(shared) }
            if let pending {
                _ = await pending.value
                continue
            }
            let task = Task { await forward() }
            pending = task
            let outcome = await task.value
            pending = nil
            if let result = outcome.result { shared = result }
            return .own(outcome)
        }
    }
}
