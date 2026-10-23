// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("Account update", .serialized)
@MainActor
struct AccountUpdateTests {

    private func expectInvalidInput(_ action: () throws -> Void) {
        do {
            try action()
            Issue.record("Expected invalidInput")
        } catch let error as ToolError {
            if case .invalidInput = error { return }
            Issue.record("Expected invalidInput, got \(error)")
        } catch {
            Issue.record("Expected ToolError.invalidInput, got \(error)")
        }
    }

    @Test("Update renames, reclassifies and hides, and stamps the modification date")
    func updateWritesFieldsAndStampsModificationDate() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let created = try accounts.create(name: "Gemini 401k", accountClass: AccountClass.collegeSavings529, currencyCode: "USD")
        let uuid = try TestVaultHelper.uniqueID(entityName: "Account", pk: created.id, in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Account", uuid: uuid, in: vault.container)
        let pinned = try #require(TestVaultHelper.modificationDate(entityName: "Account", uuid: uuid, in: vault.container))

        let updated = try accounts.update(
            accountId: created.id,
            name: "Gemini Retirement",
            accountClass: AccountClass.slugs["401k"],
            hidden: true
        )

        #expect(updated.name == "Gemini Retirement")
        #expect(updated.fullName == "Gemini Retirement")
        #expect(updated.accountClass == AccountClass.fourOhOneK)
        #expect(updated.hidden)
        let stamped = try #require(TestVaultHelper.modificationDate(entityName: "Account", uuid: uuid, in: vault.container))
        #expect(stamped > pinned)
    }

    @Test("Update leaves fields it was not given alone")
    func updateLeavesOmittedFieldsAlone() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let created = try accounts.create(name: "Everyday", accountClass: AccountClass.checking, currencyCode: "USD", hidden: true)

        let updated = try accounts.update(accountId: created.id, hidden: false)

        #expect(updated.name == "Everyday")
        #expect(updated.accountClass == AccountClass.checking)
        #expect(!updated.hidden)
    }

    @Test("Update refuses an empty request, an empty name and a category class")
    func updateRefusesInvalidRequests() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let created = try accounts.create(name: "Everyday", accountClass: AccountClass.checking, currencyCode: "USD")

        expectInvalidInput { _ = try accounts.update(accountId: created.id) }
        expectInvalidInput { _ = try accounts.update(accountId: created.id, name: "  ") }
        expectInvalidInput { _ = try accounts.update(accountId: created.id, accountClass: AccountClass.expense) }
        #expect(try accounts.get(accountId: created.id)?.accountClass == AccountClass.checking)
    }

    @Test("Update refuses to modify a category account")
    func updateRefusesCategoryTarget() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        let category = try CategoryRepository(container: vault.container).create(name: "Groceries", type: "expense")

        let accounts = AccountRepository(container: vault.container)
        expectInvalidInput { _ = try accounts.update(accountId: category.id, name: "Food") }
    }

    @Test("Every account type slug names a class create and update accept")
    func slugsNeverNameACategory() {
        #expect(!AccountClass.slugs.isEmpty)
        #expect(AccountClass.slugs.values.allSatisfy { $0 < AccountClass.income })
    }
}
