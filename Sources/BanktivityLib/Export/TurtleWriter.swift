// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

public final class TurtleWriter: @unchecked Sendable {
    private var prefixes: [(String, String)] = []
    private var body = ""
    private var inSubject = false
    private var propertyCount = 0

    public init() {}

    public func addPrefix(_ prefix: String, _ iri: String) {
        prefixes.append((prefix, iri))
    }

    public func startSubject(_ uri: String, types: [String]) {
        endSubject()
        body += "\n\(uri) a \(types.joined(separator: " , "))"
        inSubject = true
        propertyCount = 0
    }

    public func addProperty(_ predicate: String, uri value: String) {
        appendProperty(predicate, value)
    }

    public func addProperty(_ predicate: String, literal value: String) {
        appendProperty(predicate, "\"\(escapeLiteral(value))\"")
    }

    public func addProperty(_ predicate: String, decimal value: Double) {
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15
            ? String(format: "%.1f", value)
            : String(value)
        appendProperty(predicate, "\"\(formatted)\"^^xsd:decimal")
    }

    public func addProperty(_ predicate: String, integer value: Int) {
        appendProperty(predicate, "\(value)")
    }

    public func addProperty(_ predicate: String, boolean value: Bool) {
        appendProperty(predicate, value ? "true" : "false")
    }

    public func addProperty(_ predicate: String, date value: String) {
        appendProperty(predicate, "\"\(value)\"^^xsd:date")
    }

    public func addPropertyList(_ predicate: String, uris: [String]) {
        guard !uris.isEmpty else { return }
        let value = uris.joined(separator: " ,\n        ")
        appendProperty(predicate, value)
    }

    public func addComment(_ text: String) {
        endSubject()
        body += "\n# \(text)\n"
    }

    public func endSubject() {
        guard inSubject else { return }
        body += " .\n"
        inSubject = false
        propertyCount = 0
    }

    public func build() -> String {
        endSubject()
        var result = ""
        for (prefix, iri) in prefixes {
            result += "@prefix \(prefix): <\(iri)> .\n"
        }
        result += body
        return result
    }

    private func appendProperty(_ predicate: String, _ object: String) {
        guard inSubject else { return }
        propertyCount += 1
        body += " ;\n    \(predicate) \(object)"
    }

    private func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
