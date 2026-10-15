// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("Holdings value", .serialized)
@MainActor
struct HoldingsValueTests {

    /// Insert one trade: a transaction, its cash line and its security line.
    private func insertTrade(
        ctx: NSManagedObjectContext,
        account: NSManagedObject,
        security: NSManagedObject,
        date: String,
        cash: Double,
        shares: Double,
        multiplier: Double
    ) {
        let transaction = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        transaction.setValue("Trade \(date)", forKey: "pTitle")
        transaction.setValue(UUID().uuidString, forKey: "pUniqueID")
        transaction.setValue(false, forKey: "pCleared")
        transaction.setValue(false, forKey: "pVoid")
        transaction.setValue(false, forKey: "pAdjustment")
        BaseRepository.setNow(transaction, "pCreationTime")
        BaseRepository.setNow(transaction, "pModificationDate")
        BaseRepository.setDate(transaction, "pDate", isoString: date)

        let lineItem = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        lineItem.setValue(NSDecimalNumber(value: cash), forKey: "pTransactionAmount")
        lineItem.setValue(NSDecimalNumber.one, forKey: "pExchangeRate")
        lineItem.setValue(NSDecimalNumber.zero, forKey: "pRunningBalance")
        lineItem.setValue(false, forKey: "pCleared")
        lineItem.setValue(UUID().uuidString, forKey: "pUniqueID")
        BaseRepository.setNow(lineItem, "pCreationTime")
        lineItem.setValue(account, forKey: "pAccount")
        lineItem.setValue(transaction, forKey: "pTransaction")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(NSDecimalNumber(value: shares), forKey: "pShares")
        sli.setValue(NSDecimalNumber(value: cash), forKey: "pAmount")
        sli.setValue(NSDecimalNumber(value: multiplier), forKey: "pPriceMultiplier")
        sli.setValue(NSDecimalNumber.zero, forKey: "pPricePerShare")
        sli.setValue(NSDecimalNumber.zero, forKey: "pCommission")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(lineItem, forKey: "pLineItem")
    }

    private func insertClose(ctx: NSManagedObjectContext, security: NSManagedObject, day: Int32, close: Double) {
        let uniqueId = BaseRepository.stringValue(security, "pUniqueID")
        let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        request.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
        let item = (try? ctx.fetch(request).first) ?? {
            let created = NSEntityDescription.insertNewObject(forEntityName: "SecurityPriceItem", into: ctx)
            created.setValue(uniqueId, forKey: "pSecurityID")
            return created
        }()
        let price = NSEntityDescription.insertNewObject(forEntityName: "SecurityPrice", into: ctx)
        price.setValue(day, forKey: "pDate")
        price.setValue(NSDecimalNumber(value: close), forKey: "pClosePrice")
        price.setValue(item, forKey: "pSecurityPriceItem")
    }

    @Test("Holdings value is shares x latest close x latest price multiplier, beside an unchanged cash balance")
    func holdingsValueIsReportedBesideCash() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: usd)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "HOLD", currency: usd)
        let other = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "GONE", currency: usd)

        let ctx = vault.container.viewContext
        account.setValue(Int16(AccountClass.investment), forKey: "pAccountClass")
        // HOLD: buy 10, buy 5, sell 3 -> 12 shares; the latest trade's multiplier (2) applies.
        insertTrade(ctx: ctx, account: account, security: security, date: "2026-01-02", cash: -1000, shares: 10, multiplier: 1)
        insertTrade(ctx: ctx, account: account, security: security, date: "2026-02-02", cash: -500, shares: 5, multiplier: 1)
        insertTrade(ctx: ctx, account: account, security: security, date: "2026-03-02", cash: 330, shares: -3, multiplier: 2)
        // GONE: bought and fully sold, so it contributes nothing even with a price.
        insertTrade(ctx: ctx, account: account, security: other, date: "2026-01-05", cash: -50, shares: 1, multiplier: 1)
        insertTrade(ctx: ctx, account: account, security: other, date: "2026-01-06", cash: 60, shares: -1, multiplier: 1)
        insertClose(ctx: ctx, security: security, day: 20_000, close: 90)
        insertClose(ctx: ctx, security: security, day: 20_100, close: 110.25)
        insertClose(ctx: ctx, security: other, day: 20_100, close: 70)
        try ctx.save()

        let accounts = AccountRepository(container: vault.container)
        let accountId = BaseRepository.extractPK(from: account.objectID)

        // 12 shares x 110.25 (latest close) x 2 (latest multiplier).
        let holdings = try #require(try accounts.holdingsValue(accountId: accountId))
        #expect(abs(holdings - 2646.0) < 0.000001)

        // The cash balance is the cash lines only, exactly as before.
        let balance = try accounts.getBalance(accountId: accountId)
        #expect(abs(balance - (-1160.0)) < 0.000001)

        let listed = try #require(try accounts.listWithBalances().first { $0.id == accountId })
        #expect(abs((listed.balance ?? 0) - (-1160.0)) < 0.000001)
        #expect(abs((listed.holdingsValue ?? 0) - 2646.0) < 0.000001)
        #expect(listed.formattedHoldingsValue != nil)
    }

    @Test("A non-investment account reports no holdings value and its JSON gains no field")
    func nonInvestmentAccountHasNoHoldingsField() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let checking = try accounts.create(name: "Plain Checking", accountClass: AccountClass.checking, currencyCode: "USD")
        #expect(try accounts.holdingsValue(accountId: checking.id) == nil)

        let listed = try #require(try accounts.listWithBalances().first { $0.id == checking.id })
        let json = try #require(String(data: try JSONEncoder().encode(listed), encoding: .utf8))
        #expect(!json.contains("holdingsValue"))
    }
}
