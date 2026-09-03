// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("TransactionRepository", .serialized)
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
            name: "Synthetic Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let existing = try repos.transactions.create(
            date: "2026-05-10",
            title: "Later Vendor Alpha Payment",
            lineItems: [(accountId: account.id, amount: -10.0, memo: nil)]
        )

        let created = try repos.transactions.create(
            date: "2026-04-09",
            title: "Vendor Alpha",
            lineItems: [(accountId: account.id, amount: -20.0, memo: nil)]
        )

        #expect(created.id != existing.id)
        #expect(created.title == "Vendor Alpha")
        #expect(created.date == "2026-04-09")
        #expect(created.lineItems.contains { $0.accountId == account.id && abs($0.amount - -20.0) < 0.005 })
    }

    @Test("List rejects missing account filter instead of returning the whole vault")
    func listRejectsMissingAccountFilter() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Filtered Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        _ = try repos.transactions.create(
            date: "2026-05-10",
            title: "Should not leak through missing account filter",
            lineItems: [(accountId: account.id, amount: -10.0, memo: nil)]
        )

        do {
            _ = try repos.transactions.list(accountId: 999_999)
            Issue.record("Expected missing account filter to fail")
        } catch let error as ToolError {
            if case .notFound(let message) = error {
                #expect(message == "Account not found: 999999")
            } else {
                Issue.record("Expected notFound, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError.notFound, got \(error)")
        }

        let filtered = try repos.transactions.list(accountId: account.id)
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Should not leak through missing account filter")
    }
    // Added 2026-09-02. Midnight is the START of a day, so an end bound built as
    // `pDate <= midnight(endDate)` drops every row stored later in that day.
    // Measured on the production vault before any anchoring work: two of three
    // sampled rows were already missing from a same-day window. Anchored writes
    // land at 10:00 UTC and would be dropped every time.
    @Test("a same-day window returns a row written that day")
    func sameDayWindowReturnsTheRowWrittenThatDay() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Synthetic Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let created = try repos.transactions.create(
            date: "2026-06-08",
            title: "Same day window probe",
            lineItems: [(accountId: account.id, amount: -12.34, memo: nil)]
        )
        #expect(created.date == "2026-06-08")

        let sameDay = try repos.transactions.list(
            accountId: account.id, startDate: "2026-06-08", endDate: "2026-06-08"
        )
        #expect(sameDay.contains { $0.id == created.id })

        // The bound must be exclusive of the NEXT day, not inclusive of this one:
        // a window ending the day before must still not return it.
        let dayBefore = try repos.transactions.list(
            accountId: account.id, startDate: "2026-06-01", endDate: "2026-06-07"
        )
        #expect(!dayBefore.contains { $0.id == created.id })
    }

}
