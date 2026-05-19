// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("TransactionForex")
struct TransactionForexTests {

    private struct Repos {
        let vault: TestVaultHelper.TestVault
        let accounts: AccountRepository
        let categories: CategoryRepository
        let lineItems: LineItemRepository
        let transactions: TransactionRepository
    }

    private func makeRepos() throws -> Repos {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        try seedCurrency("AUD", name: "Australian Dollar", in: vault.container)
        try seedTransferTransactionType(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let categories = CategoryRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)

        return Repos(
            vault: vault,
            accounts: accounts,
            categories: categories,
            lineItems: lineItems,
            transactions: transactions
        )
    }

    private func seedCurrency(_ code: String, name: String, in container: NSPersistentContainer) throws {
        let ctx = container.viewContext
        let currency = NSEntityDescription.insertNewObject(forEntityName: "Currency", into: ctx)
        currency.setValue(code, forKey: "pCode")
        currency.setValue(name, forKey: "pName")
        currency.setValue(UUID().uuidString, forKey: "pUniqueID")
        currency.setValue(Date(), forKey: "pCreationTime")
        currency.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
    }

    private func seedTransferTransactionType(in container: NSPersistentContainer) throws {
        let ctx = container.viewContext
        let transfer = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        transfer.setValue(Int16(3), forKey: "pBaseType")
        transfer.setValue("Transfer", forKey: "pName")
        transfer.setValue(UUID().uuidString, forKey: "pUniqueID")
        transfer.setValue(Date(), forKey: "pCreationTime")
        transfer.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
    }

    private func makeForexAccounts(_ repos: Repos) throws -> (source: AccountDTO, target: AccountDTO, fee: CategoryDTO) {
        let source = try repos.accounts.create(
            name: "Macquarie AUD",
            accountClass: AccountClass.savings,
            currencyCode: "AUD"
        )
        let target = try repos.accounts.create(
            name: "Chase USD",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let fee = try repos.categories.create(
            name: "Wise Fees",
            type: "expense",
            currencyCode: "AUD"
        )
        return (source, target, fee)
    }

    private func line(_ tx: TransactionDTO, accountId: Int) throws -> LineItemDTO {
        try #require(tx.lineItems.first { $0.accountId == accountId })
    }

    private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.0001) {
        #expect(abs(actual - expected) <= tolerance, "\(actual) should equal \(expected)")
    }

    @Test("repairForexTransfer creates source target and fee lines")
    func repairForexTransferCreatesExpectedLines() throws {
        let repos = try makeRepos()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let ids = try makeForexAccounts(repos)

        let original = try repos.transactions.create(
            date: "2026-04-27",
            title: "Wise equal numeric transfer",
            lineItems: [
                (accountId: ids.source.id, amount: -3000, memo: "source"),
                (accountId: ids.target.id, amount: 3000, memo: "target"),
            ]
        )

        let repaired = try #require(try repos.transactions.repairForexTransfer(
            transactionId: original.id,
            sourceAccountId: ids.source.id,
            targetAccountId: ids.target.id,
            feeCategoryId: ids.fee.id,
            grossSourceAmount: 3000,
            sourceFeeAmount: 100,
            targetAmount: 1450,
            exchangeRate: 0.5,
            title: "Wise Forex Transfer",
            note: "TRANSFER-TEST",
            date: "2026-04-27",
            sourceMemo: "AUD gross",
            targetMemo: "USD receipt",
            feeMemo: "Wise fee"
        ))

        #expect(repaired.title == "Wise Forex Transfer")
        #expect(repaired.transactionType?.lowercased() == "transfer")
        #expect(repaired.lineItems.count == 3)

        let source = try line(repaired, accountId: ids.source.id)
        let target = try line(repaired, accountId: ids.target.id)
        let fee = try line(repaired, accountId: ids.fee.id)

        expectClose(source.amount, -3000)
        expectClose(source.exchangeRate, 1)
        expectClose(source.accountAmount, -3000)
        expectClose(source.runningBalance ?? 0, -3000)
        #expect(source.memo == "AUD gross")

        expectClose(target.amount, 2900)
        expectClose(target.exchangeRate, 0.5)
        expectClose(target.accountAmount, 1450)
        expectClose(target.runningBalance ?? 0, 1450)
        #expect(target.memo == "USD receipt")

        expectClose(fee.amount, 100)
        expectClose(fee.exchangeRate, 1)
        expectClose(fee.accountAmount, 100)
        #expect(fee.memo == "Wise fee")
    }

    @Test("repairForexTransfer stores source account currency on transaction")
    func repairForexTransferUsesSourceCurrency() throws {
        let repos = try makeRepos()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let ids = try makeForexAccounts(repos)

        let original = try repos.transactions.create(
            date: "2026-04-27",
            title: "Wise currency test",
            lineItems: [
                (accountId: ids.source.id, amount: -3000, memo: nil),
                (accountId: ids.target.id, amount: 3000, memo: nil),
            ]
        )

        _ = try repos.transactions.repairForexTransfer(
            transactionId: original.id,
            sourceAccountId: ids.source.id,
            targetAccountId: ids.target.id,
            feeCategoryId: ids.fee.id,
            grossSourceAmount: 3000,
            sourceFeeAmount: 100,
            targetAmount: 1450,
            exchangeRate: 0.5
        )

        let tx = try #require(try repos.transactions.fetchByPK(entityName: "Transaction", pk: original.id))
        let currency = try #require(BaseRepository.relatedObject(tx, "pCurrency"))
        #expect(BaseRepository.stringValue(currency, "pCode") == "AUD")
    }

    @Test("repairForexTransfer rejects mismatched target amount")
    func repairForexTransferRejectsMismatchedTargetAmount() throws {
        let repos = try makeRepos()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let ids = try makeForexAccounts(repos)

        let original = try repos.transactions.create(
            date: "2026-04-27",
            title: "Wise mismatch test",
            lineItems: [
                (accountId: ids.source.id, amount: -3000, memo: nil),
                (accountId: ids.target.id, amount: 3000, memo: nil),
            ]
        )

        #expect(throws: (any Error).self) {
            try repos.transactions.repairForexTransfer(
                transactionId: original.id,
                sourceAccountId: ids.source.id,
                targetAccountId: ids.target.id,
                feeCategoryId: ids.fee.id,
                grossSourceAmount: 3000,
                sourceFeeAmount: 100,
                targetAmount: 1400,
                exchangeRate: 0.5
            )
        }
    }

    @Test("repairForexTransfer rejects unmanaged extra line items")
    func repairForexTransferRejectsUnmanagedExtraLineItems() throws {
        let repos = try makeRepos()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let ids = try makeForexAccounts(repos)
        let otherCategory = try repos.categories.create(name: "Other Expense", type: "expense", currencyCode: "AUD")

        let original = try repos.transactions.create(
            date: "2026-04-27",
            title: "Wise extra line test",
            lineItems: [
                (accountId: ids.source.id, amount: -3000, memo: nil),
                (accountId: ids.target.id, amount: 2900, memo: nil),
                (accountId: otherCategory.id, amount: 100, memo: nil),
            ]
        )

        #expect(throws: (any Error).self) {
            try repos.transactions.repairForexTransfer(
                transactionId: original.id,
                sourceAccountId: ids.source.id,
                targetAccountId: ids.target.id,
                feeCategoryId: ids.fee.id,
                grossSourceAmount: 3000,
                sourceFeeAmount: 100,
                targetAmount: 1450,
                exchangeRate: 0.5
            )
        }
    }
}
