// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("TurtleWriter")
struct TurtleWriterTests {

    @Test("prefixes are emitted at top")
    func prefixes() {
        let w = TurtleWriter()
        w.addPrefix("schema", "http://schema.org/")
        w.addPrefix("xsd", "http://www.w3.org/2001/XMLSchema#")
        let output = w.build()
        #expect(output.hasPrefix("@prefix schema: <http://schema.org/> .\n"))
        #expect(output.contains("@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n"))
    }

    @Test("subject with type and properties")
    func subjectWithProperties() {
        let w = TurtleWriter()
        w.addPrefix("schema", "http://schema.org/")
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.addProperty("schema:name", literal: "Test")
        w.addProperty("schema:value", integer: 42)
        w.endSubject()
        let output = w.build()
        #expect(output.contains("<urn:test:1> a schema:Thing"))
        #expect(output.contains("schema:name \"Test\""))
        #expect(output.contains("schema:value 42"))
        #expect(output.contains(" .\n"))
    }

    @Test("literal escaping")
    func literalEscaping() {
        let w = TurtleWriter()
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.addProperty("schema:name", literal: "He said \"hello\"\nNew line\\slash")
        w.endSubject()
        let output = w.build()
        #expect(output.contains("\"He said \\\"hello\\\"\\nNew line\\\\slash\""))
    }

    @Test("typed literals")
    func typedLiterals() {
        let w = TurtleWriter()
        w.addPrefix("xsd", "http://www.w3.org/2001/XMLSchema#")
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.addProperty("schema:amount", decimal: 42.5)
        w.addProperty("schema:date", date: "2026-01-15")
        w.addProperty("schema:active", boolean: true)
        w.endSubject()
        let output = w.build()
        #expect(output.contains("\"42.5\"^^xsd:decimal"))
        #expect(output.contains("\"2026-01-15\"^^xsd:date"))
        #expect(output.contains("true"))
    }

    @Test("property list with multiple URIs")
    func propertyList() {
        let w = TurtleWriter()
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.addPropertyList("schema:hasPart", uris: ["<urn:a:1>", "<urn:a:2>"])
        w.endSubject()
        let output = w.build()
        #expect(output.contains("<urn:a:1>"))
        #expect(output.contains("<urn:a:2>"))
    }

    @Test("empty property list is skipped")
    func emptyPropertyList() {
        let w = TurtleWriter()
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.addPropertyList("schema:hasPart", uris: [])
        w.addProperty("schema:name", literal: "Only")
        w.endSubject()
        let output = w.build()
        #expect(!output.contains("hasPart"))
    }

    @Test("multiple subjects")
    func multipleSubjects() {
        let w = TurtleWriter()
        w.startSubject("<urn:a:1>", types: ["schema:Thing"])
        w.addProperty("schema:name", literal: "First")
        w.startSubject("<urn:a:2>", types: ["schema:Thing"])
        w.addProperty("schema:name", literal: "Second")
        w.endSubject()
        let output = w.build()
        #expect(output.contains("<urn:a:1> a schema:Thing"))
        #expect(output.contains("<urn:a:2> a schema:Thing"))
        // First subject auto-closed when second started
        let parts = output.components(separatedBy: " .\n")
        #expect(parts.count >= 2)
    }

    @Test("decimal formatting for whole numbers")
    func decimalFormatting() {
        let w = TurtleWriter()
        w.addPrefix("xsd", "http://www.w3.org/2001/XMLSchema#")
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.addProperty("schema:amount", decimal: 100.0)
        w.endSubject()
        let output = w.build()
        #expect(output.contains("\"100.0\"^^xsd:decimal"))
    }

    @Test("comment")
    func comment() {
        let w = TurtleWriter()
        w.addComment("Section Header")
        w.startSubject("<urn:test:1>", types: ["schema:Thing"])
        w.endSubject()
        let output = w.build()
        #expect(output.contains("# Section Header"))
    }
}
