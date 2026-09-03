// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("AccountRepository", .serialized)
struct AccountRepositoryTests {

    private func expectAccountNotFound(accountId: Int, _ action: () throws -> Void) {
        do {
            try action()
            Issue.record("Expected account lookup to fail")
        } catch let error as ToolError {
            if case .notFound(let message) = error {
                #expect(message == "Account not found: \(accountId)")
            } else {
                Issue.record("Expected notFound, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError.notFound, got \(error)")
        }
    }

    @Test("Balance uses account-currency amount when exchange rate is present")
    func balanceUsesExchangeRate() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let account = try accounts.create(
            name: "Foreign Cash",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let base = BaseRepository(container: vault.container)

        try base.performWrite { ctx in
            guard let accountObject = try base.fetchByPK(entityName: "Account", pk: account.id, in: ctx) else {
                throw ToolError.notFound("Account not found: \(account.id)")
            }

            let transaction = BaseRepository.createObject(entityName: "Transaction", in: ctx)
            transaction.setValue("Converted deposit", forKey: "pTitle")
            transaction.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            transaction.setValue(false, forKey: "pCleared")
            transaction.setValue(false, forKey: "pVoid")
            transaction.setValue(false, forKey: "pAdjustment")
            transaction.setValue(BaseRepository.relatedObject(accountObject, "currency"), forKey: "pCurrency")
            BaseRepository.setNow(transaction, "pCreationTime")
            BaseRepository.setNow(transaction, "pModificationDate")
            BaseRepository.setDate(transaction, "pDate", isoString: "2026-05-22")

            let lineItem = BaseRepository.createObject(entityName: "LineItem", in: ctx)
            lineItem.setValue(100.0 as NSNumber, forKey: "pTransactionAmount")
            lineItem.setValue(1.25 as NSNumber, forKey: "pExchangeRate")
            lineItem.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            lineItem.setValue(false, forKey: "pCleared")
            lineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(lineItem, "pCreationTime")
            lineItem.setValue(accountObject, forKey: "pAccount")
            lineItem.setValue(transaction, forKey: "pTransaction")
        }

        let balance = try accounts.getBalance(accountId: account.id)
        #expect(abs(balance - 125.0) < 0.005)
    }

    @Test("Missing account IDs fail instead of resolving to zero-balance unknown accounts")
    func missingAccountIdsFailLoudly() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let accounts = AccountRepository(container: vault.container)

        expectAccountNotFound(accountId: 999_999) {
            _ = try accounts.resolveAccountId(id: 999_999, name: nil)
        }
        expectAccountNotFound(accountId: 999_999) {
            _ = try accounts.getBalance(accountId: 999_999)
        }
    }

    @Test("Hidden accounts still resolve when addressed by explicit ID")
    func hiddenAccountsResolveByExplicitId() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let hidden = try accounts.create(
            name: "Retired But Existing",
            accountClass: AccountClass.checking,
            currencyCode: "USD",
            hidden: true
        )

        let visibleAccounts = try accounts.list()
        #expect(!visibleAccounts.contains { $0.id == hidden.id })
        #expect(try accounts.resolveAccountId(id: hidden.id, name: nil) == hidden.id)
        #expect(try accounts.get(accountId: hidden.id)?.hidden == true)
    }
}
