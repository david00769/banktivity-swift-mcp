// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// The store is Banktivity's, so this package must never let Core Data migrate
/// it. With the defaults left on, a merged model whose hashes differ from what
/// Banktivity wrote is "migrated" by dropping and recreating tables; one
/// observed run emptied ZSECURITYPRICE and reported success.
@Suite("Migration guard", .serialized)
@MainActor
struct MigrationGuardTests {

    @Test("The store description turns off automatic migration and mapping inference")
    func storeDescriptionDisablesMigration() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let description = try #require(vault.container.persistentStoreDescriptions.first)
        #expect(description.shouldMigrateStoreAutomatically == false)
        #expect(description.shouldInferMappingModelAutomatically == false)
    }

    @Test("A model that no longer matches the store fails to load and leaves the store untouched")
    func mismatchedModelFailsLoudly() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        // Close the fixture's own handle so the store is at rest.
        let coordinator = vault.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        let storeContent = URL(fileURLWithPath: vault.path).appendingPathComponent("StoreContent")
        let sqlURL = storeContent.appendingPathComponent("core.sql")
        // The entity version hashes recorded in the store are exactly what a
        // migration rewrites, so they are the evidence that none happened.
        let before = try storeVersionHashes(at: sqlURL)

        // Dropping one model bundle changes the merged model's entity hashes,
        // the same kind of mismatch a different .momd merge order produced.
        try FileManager.default.removeItem(at: storeContent.appendingPathComponent("budget.momd"))

        #expect(throws: BanktivityError.self) {
            _ = try PersistentContainerFactory.create(bankFilePath: vault.path)
        }
        #expect(try storeVersionHashes(at: sqlURL) == before)
    }

    private func storeVersionHashes(at url: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        return metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:]
    }

    @Test("The merged model is the same whatever order the bundles are listed in")
    func mergedModelIsStable() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let storeContent = URL(fileURLWithPath: vault.path).appendingPathComponent("StoreContent")
        let first = try PersistentContainerFactory.loadMergedModel(from: storeContent)
        let second = try PersistentContainerFactory.loadMergedModel(from: storeContent)
        #expect(first.entityVersionHashesByName == second.entityVersionHashesByName)
    }
}
