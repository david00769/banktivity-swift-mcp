// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("TransactionRepository")
struct TransactionRepositoryTests {

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        transactions: TransactionRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, transactions)
    }

    @Test("Create returns the newly inserted transaction, not a title-search match")
    func createReturnsInsertedTransactionWhenLaterMatchingTitleExists() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Macquarie Transaction Test",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let existing = try repos.transactions.create(
            date: "2026-05-10",
            title: "Payment to American Express",
            lineItems: [(accountId: account.id, amount: -108.84, memo: nil)]
        )

        let created = try repos.transactions.create(
            date: "2026-04-09",
            title: "American Express",
            lineItems: [(accountId: account.id, amount: -8699.28, memo: nil)]
        )

        #expect(created.id != existing.id)
        #expect(created.title == "American Express")
        #expect(created.date == "2026-04-09")
        #expect(created.lineItems.contains { $0.accountId == account.id && abs($0.amount - -8699.28) < 0.005 })
    }
}
