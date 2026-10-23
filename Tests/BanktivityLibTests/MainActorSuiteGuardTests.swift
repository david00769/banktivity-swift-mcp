// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing

/// Every suite that touches Core Data must run on the main actor.
///
/// TestVaultHelper explains why: a Swift Testing body runs on the cooperative
/// pool, so using a main-queue `viewContext` from it is a threading violation
/// that fails unpredictably -- a corrupted change-tracking set, error 133010, or
/// a segfault in a different test each run. That was Finances board item 60. It
/// was fixed on 2026-09-07 by annotating the suites, then came back because two
/// suites written later did not carry the annotation. A convention that only
/// reviewers enforce recurs; this test enforces it.
///
/// It reads the test sources themselves. A suite "touches Core Data" when its
/// body mentions one of `markers`; such a suite needs `@MainActor` among the
/// attributes directly above its declaration.
@Suite("Core Data suites run on the main actor")
struct MainActorSuiteGuardTests {

    static let markers = [
        "createFreshVault", "TestVaultHelper.", "viewContext",
        "PersistentContainerFactory.create", "NSPersistentContainer",
    ]

    struct SuiteSource {
        let file: String
        let name: String
        let attributes: [String]
        let body: String
    }

    /// Split a source file into its top-level suites. A suite runs from its
    /// attribute block to the next top-level suite's attribute block, so any
    /// file-private helpers between suites count towards the one above them.
    static func suites(in source: String, file: String) -> [SuiteSource] {
        let lines = source.components(separatedBy: "\n")
        var starts: [(attributeStart: Int, declaration: Int)] = []
        for (index, line) in lines.enumerated() {
            let isDeclaration = ["struct ", "final class ", "class ", "enum "].contains { line.hasPrefix($0) }
            guard isDeclaration else { continue }
            var first = index
            while first > 0, lines[first - 1].hasPrefix("@") { first -= 1 }
            let attributes = lines[first..<index]
            guard attributes.contains(where: { $0.hasPrefix("@Suite") }) else { continue }
            starts.append((first, index))
        }
        return starts.enumerated().map { position, start in
            let end = position + 1 < starts.count ? starts[position + 1].attributeStart : lines.count
            let declaration = lines[start.declaration]
            let name = declaration.split(separator: " ").dropFirst(declaration.hasPrefix("final ") ? 2 : 1).first
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "{:")) } ?? declaration
            return SuiteSource(
                file: file, name: name,
                attributes: Array(lines[start.attributeStart..<start.declaration]),
                body: lines[start.declaration..<end].joined(separator: "\n")
            )
        }
    }

    static func violations(_ suites: [SuiteSource]) -> [String] {
        suites.compactMap { suite in
            let touchesCoreData = markers.contains { suite.body.contains($0) }
            let onMainActor = suite.attributes.contains { $0.hasPrefix("@MainActor") }
            return touchesCoreData && !onMainActor ? "\(suite.file): \(suite.name)" : nil
        }
    }

    @Test("Every suite that touches Core Data is @MainActor")
    func everyCoreDataSuiteIsMainActor() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let thisFile = URL(fileURLWithPath: #filePath).lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") && $0 != thisFile }
            .sorted()

        var all: [SuiteSource] = []
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            all += Self.suites(in: source, file: file)
        }

        // Guard the guard: if parsing stops finding suites, an empty list
        // would pass silently.
        #expect(all.count >= 30, "found only \(all.count) suites; the parser has stopped matching")
        #expect(all.filter { suite in Self.markers.contains { suite.body.contains($0) } }.count >= 20)

        let found = Self.violations(all)
        #expect(found.isEmpty, "Core Data suites without @MainActor (see TestVaultHelper): \(found.joined(separator: ", "))")
    }

    @Test("The check flags a vault suite without @MainActor and passes one with it")
    func checkDistinguishesTheTwoCases() {
        let source = """
        @Suite("Without", .serialized)
        struct WithoutMainActor {
            func test() throws { _ = try TestVaultHelper.createFreshVault() }
        }

        @Suite("With", .serialized)
        @MainActor
        struct WithMainActor {
            func test() throws { _ = try TestVaultHelper.createFreshVault() }
        }

        @Suite("Pure")
        struct NoCoreData {
            func test() { _ = 1 + 1 }
        }
        """
        let suites = Self.suites(in: source, file: "Example.swift")
        #expect(suites.map(\.name) == ["WithoutMainActor", "WithMainActor", "NoCoreData"])
        #expect(Self.violations(suites) == ["Example.swift: WithoutMainActor"])
    }
}
