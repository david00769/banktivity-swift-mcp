// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("Vault path resolution")
struct VaultLocatorTests {

    /// A temp directory laid out like Banktivity 10's library.
    private func library(_ vaults: [String]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-locator-\(UUID().uuidString)").path
        for v in vaults {
            try FileManager.default.createDirectory(
                atPath: (root as NSString).appendingPathComponent(v),
                withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A blank setting finds the one Banktivity 10 vault")
    func blankFindsSingleVault() throws {
        let lib = try library(["143CB839/1.bank8"])
        for setting in [nil, "", "  ", "${user_config.vault_path}"] as [String?] {
            #expect(try VaultLocator.resolve(setting, library: lib) == lib + "/143CB839/1.bank8")
        }
    }

    @Test("A blank setting with several vaults lists them instead of guessing")
    func blankWithSeveralVaultsLists() throws {
        let lib = try library(["B/1.bank8", "A/1.bank8"])
        #expect(throws: VaultLocator.Failure.severalDiscovered([lib + "/A/1.bank8", lib + "/B/1.bank8"])) {
            try VaultLocator.resolve("", library: lib)
        }
    }

    @Test("A blank setting with no vault says how to set one")
    func blankWithNoVault() throws {
        let lib = try library([])
        #expect(throws: VaultLocator.Failure.noneDiscovered(library: lib)) {
            try VaultLocator.resolve(nil, library: lib)
        }
        #expect(throws: VaultLocator.Failure.noneDiscovered(library: lib + "/missing")) {
            try VaultLocator.resolve(nil, library: lib + "/missing")
        }
    }

    @Test("An unreadable library is reported as blocked, not as empty")
    func unreadableLibrary() throws {
        let lib = try library(["V/1.bank8"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lib)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib) }
        #expect(throws: VaultLocator.Failure.libraryUnreadable(library: lib)) {
            try VaultLocator.resolve(nil, library: lib)
        }
    }

    @Test("An explicit .bank8 path is used as given, with ~ expanded")
    func explicitPath() throws {
        let lib = try library(["X/My Accounts.bank8"])
        let path = lib + "/X/My Accounts.bank8"
        #expect(try VaultLocator.resolve(path, library: "/nonexistent") == path)
        #expect(VaultLocator.expand("~/Documents/x.bank8") == NSHomeDirectory() + "/Documents/x.bank8")
    }

    @Test("A missing path is reported, not looked up elsewhere")
    func missingPath() {
        #expect(throws: VaultLocator.Failure.notFound("/nonexistent/x.bank8")) {
            try VaultLocator.resolve("/nonexistent/x.bank8", library: "/nonexistent")
        }
    }

    @Test("A folder that is not a vault lists the vaults inside it")
    func folderIsNotAVault() throws {
        let lib = try library(["V/1.bank8"])
        #expect(throws: VaultLocator.Failure.notAVault(lib, candidates: [lib + "/V/1.bank8"])) {
            try VaultLocator.resolve(lib, library: "/nonexistent")
        }
    }
}
