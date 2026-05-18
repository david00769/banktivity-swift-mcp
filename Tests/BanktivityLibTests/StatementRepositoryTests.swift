// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("StatementRepository")
struct StatementRepositoryTests {

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        transactions: TransactionRepository,
        statements: StatementRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)
        let statements = StatementRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, transactions, statements)
    }

    private func createCreditCard(named name: String, using accounts: AccountRepository) throws -> AccountDTO {
        try accounts.create(name: name, accountClass: AccountClass.creditCard, currencyCode: "USD")
    }

    private func accountLineItemId(in transaction: TransactionDTO, accountId: Int) throws -> Int {
        try #require(transaction.lineItems.first { $0.accountId == accountId }?.id)
    }

    @Test("Explicit reconciliation allows manually selected pre-start line items")
    func reconcileAllowsManualPreStartLineItems() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Manual Picker Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-03-26",
            title: "Mammoth Cave",
            lineItems: [(accountId: card.id, amount: -7.05, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: card.id)

        let statement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-03-29",
            endDate: "2026-04-28",
            beginningBalance: 0,
            endingBalance: -7.05,
            name: "April statement"
        )

        let result = try repos.statements.reconcileLineItems(
            statementId: statement.id,
            lineItemIds: [lineItemId]
        )

        #expect(result.reconciledLineItemCount == 1)
        #expect(abs(result.reconciledBalance - -7.05) < 0.005)
        #expect(result.isBalanced)
    }

    @Test("Explicit reconciliation still rejects line items from another account")
    func reconcileRejectsWrongAccountLineItems() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let statementCard = try createCreditCard(named: "Statement Card", using: repos.accounts)
        let otherCard = try createCreditCard(named: "Other Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-04-10",
            title: "Other account charge",
            lineItems: [(accountId: otherCard.id, amount: -10.0, memo: nil)]
        )
        let otherLineItemId = try accountLineItemId(in: transaction, accountId: otherCard.id)

        let statement = try repos.statements.create(
            accountId: statementCard.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: -10.0
        )

        #expect(throws: (any Error).self) {
            try repos.statements.reconcileLineItems(
                statementId: statement.id,
                lineItemIds: [otherLineItemId]
            )
        }
    }

    @Test("Explicit reconciliation still rejects line items already assigned to another statement")
    func reconcileRejectsLineItemsAssignedToAnotherStatement() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Double Assignment Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-01-15",
            title: "Assigned charge",
            lineItems: [(accountId: card.id, amount: -25.0, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: card.id)

        let firstStatement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-01-01",
            endDate: "2026-01-31",
            beginningBalance: 0,
            endingBalance: -25.0
        )
        let secondStatement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-02-01",
            endDate: "2026-02-28",
            beginningBalance: -25.0,
            endingBalance: -25.0
        )

        _ = try repos.statements.reconcileLineItems(
            statementId: firstStatement.id,
            lineItemIds: [lineItemId]
        )

        #expect(throws: (any Error).self) {
            try repos.statements.reconcileLineItems(
                statementId: secondStatement.id,
                lineItemIds: [lineItemId]
            )
        }
    }
}
