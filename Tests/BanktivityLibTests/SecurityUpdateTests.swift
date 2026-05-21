// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Security updates", .serialized)
struct SecurityUpdateTests {
    @Test("updateSecurityLineItem updates commission and sync blob")
    func updateTradeCommission() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let (_, sellType) = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        let txUUID = UUID().uuidString
        tx.setValue(txUUID, forKey: "pUniqueID")
        tx.setValue(Date(), forKey: "pDate")
        tx.setValue("Test sell", forKey: "pTitle")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(sellType, forKey: "pTransactionType")
        tx.setValue(Date(), forKey: "pCreationTime")
        tx.setValue(Date(), forKey: "pModificationDate")

        let li = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let liUUID = UUID().uuidString
        li.setValue(liUUID, forKey: "pUniqueID")
        li.setValue(account, forKey: "pAccount")
        li.setValue(tx, forKey: "pTransaction")
        li.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        li.setValue(Date(), forKey: "pCreationTime")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(li, forKey: "pLineItem")
        sli.setValue(-1.0 as NSNumber, forKey: "pShares")
        sli.setValue(100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(100.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(100.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        try ctx.save()

        let syncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: BaseRepository.stringValue(account, "pUniqueID"),
            accountAmount: 100.0,
            cleared: false,
            identifier: liUUID,
            memo: nil,
            securityLineItem: SyncBlobUpdater.SyncSecurityLineItem(
                amount: 100.0,
                commission: 100.0,
                pricePerShare: 100.0,
                priceMultiplier: 1.0,
                securityUUID: BaseRepository.stringValue(security, "pUniqueID"),
                shares: -1.0,
                hasDistributionType: false
            ),
            transactionAmount: 100.0
        )
        let updater = SyncBlobUpdater(container: vault.container)
        updater.createTransactionSyncRecord(
            transactionUUID: txUUID,
            currencyUUID: BaseRepository.stringValue(eur, "pUniqueID"),
            date: "2026-01-01",
            title: "Test sell",
            note: nil,
            adjustment: false,
            lineItems: [syncLI],
            transactionTypeBaseType: "Sell",
            transactionTypeUUID: BaseRepository.stringValue(sellType, "pUniqueID")
        )

        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let txPK = BaseRepository.extractPK(from: tx.objectID)
        let result = try repo.updateSecurityLineItem(
            transactionId: txPK,
            pricePerShare: 12.34,
            amount: 56.78,
            commission: 0.0
        )

        #expect(abs(result.pricePerShare - 12.34) < 0.000001)
        #expect(abs(result.amount - 56.78) < 0.000001)
        #expect(result.commission == 0.0)

        ctx.refreshAllObjects()
        let sliRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        let updatedSLI = try #require(try ctx.fetch(sliRequest).first)
        #expect(BaseRepository.doubleValue(updatedSLI, "pCommission") == 0.0)

        let syncRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        syncRequest.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try ctx.fetch(syncRequest).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("name=\"commission\""))
        #expect(xml.contains("<field type=\"decimal\" name=\"commission\">0</field>"))
    }

    @Test("createSecurityTrade creates sell with category offset and sync blob")
    func createSecurityTradeSellWithCategoryOffset() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let category = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        category.setValue("Realized Gain", forKey: "pName")
        category.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        category.setValue(Int16(AccountClass.income), forKey: "pAccountClass")
        category.setValue(false, forKey: "pHidden")
        category.setValue(eur, forKey: "currency")
        BaseRepository.setNow(category, "pCreationTime")
        BaseRepository.setNow(category, "pModificationDate")
        try ctx.save()

        let updater = SyncBlobUpdater(container: vault.container)
        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let categoryPK = BaseRepository.extractPK(from: category.objectID)
        let result = try repo.createSecurityTrade(
            accountId: accountPK,
            symbol: BaseRepository.stringValue(security, "pSymbol"),
            shares: -2.5,
            pricePerShare: 12.34,
            amount: 30.85,
            commission: 1.23,
            cashLineItemAmount: 596.06,
            date: "2026-04-15",
            title: "TEST SELL CREATE",
            memo: "provider sell",
            offsetCategoryId: categoryPK
        )

        #expect(result.type == "Sell")
        #expect(result.shares == -2.5)
        #expect(abs(result.pricePerShare - 12.34) < 0.000001)
        #expect(abs(result.amount - 30.85) < 0.000001)
        #expect(abs(result.commission - 1.23) < 0.000001)

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(result.id)
        #expect(lineItems.count == 2)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let categoryLine = try #require(lineItems.first { $0.accountId == categoryPK })
        #expect(abs(accountLine.amount - 596.06) < 0.000001)
        #expect(abs(categoryLine.amount + 596.06) < 0.000001)
        #expect(accountLine.memo == "provider sell")

        let sliRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        let securityLineItems = try ctx.fetch(sliRequest)
        let createdSLI = try #require(securityLineItems.first)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pShares") + 2.5) < 0.000001)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pPricePerShare") - 12.34) < 0.000001)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pAmount") - 30.85) < 0.000001)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pCommission") - 1.23) < 0.000001)

        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        txRequest.predicate = NSPredicate(format: "pTitle == %@", "TEST SELL CREATE")
        let tx = try #require(try ctx.fetch(txRequest).first)
        let txUUID = BaseRepository.stringValue(tx, "pUniqueID")
        let syncRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        syncRequest.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try ctx.fetch(syncRequest).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">sell</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"shares\">-2.5</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"pricePerShare\">12.34</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"cost\">30.85</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"commission\">1.23</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">596.06</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-596.06</field>"))
        #expect(xml.contains("Account:\(BaseRepository.stringValue(category, "pUniqueID"))"))
    }
}
