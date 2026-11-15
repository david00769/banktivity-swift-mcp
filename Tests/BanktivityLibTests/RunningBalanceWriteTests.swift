// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Running balance on write", .serialized)
@MainActor
struct RunningBalanceWriteTests {

    private struct Injected: Error {}

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault, accounts: AccountRepository, transactions: TransactionRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        return (vault, AccountRepository(container: vault.container),
                TransactionRepository(container: vault.container, lineItemRepo: lineItems))
    }

    private final class SaveCounter: @unchecked Sendable {
        var count = 0
        var token: NSObjectProtocol?
        init(coordinator: NSPersistentStoreCoordinator) {
            token = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
            ) { [self] note in
                if (note.object as? NSManagedObjectContext)?.persistentStoreCoordinator === coordinator { count += 1 }
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    @Test("A write updates the running balance in a single save")
    func writeUpdatesBalanceInOneSave() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let account = try repos.accounts.create(name: "Checking", accountClass: AccountClass.checking, currencyCode: "USD")

        let counter = SaveCounter(coordinator: repos.vault.container.persistentStoreCoordinator)
        let tx = try repos.transactions.create(
            date: "2026-05-10", title: "Pay",
            lineItems: [(accountId: account.id, amount: -42, memo: nil)])
        #expect(counter.count == 1)

        repos.vault.container.viewContext.refreshAllObjects()
        let stored = try LineItemRepository(container: repos.vault.container).getForTransactionPK(tx.id)
        #expect(stored.first { $0.accountId == account.id }?.runningBalance == -42)
    }

    @Test("A failing recalculation never fails the committed write")
    func recalculationFailureDoesNotFailWrite() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let account = try repos.accounts.create(name: "Checking", accountClass: AccountClass.checking, currencyCode: "USD")
        let coordinator = repos.vault.container.persistentStoreCoordinator

        BaseRepository.runningBalanceFailureHook = { ctx in
            if ctx.persistentStoreCoordinator === coordinator { throw Injected() }
        }
        defer { BaseRepository.runningBalanceFailureHook = nil }

        let tx = try repos.transactions.create(
            date: "2026-05-10", title: "Pay",
            lineItems: [(accountId: account.id, amount: -42, memo: nil)])
        BaseRepository.runningBalanceFailureHook = nil

        repos.vault.container.viewContext.refreshAllObjects()
        let fetched = try repos.transactions.get(transactionId: tx.id)
        #expect(fetched != nil)
    }
}
