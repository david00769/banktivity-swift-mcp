// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("SyncRecord", .serialized)
@MainActor
struct SyncRecordTests {

    // MARK: - Inserts: the modification date is the only upload signal

    /// A create stamps `pCreationTime` and `pModificationDate` and writes no
    /// `SyncedHostedEntity`: Banktivity inserts its own when it uploads the row.
    private func expectInsertedWithoutSyncRecord(
        transactionPK: Int, notBefore start: Date, in container: NSPersistentContainer
    ) throws {
        #expect(TestVaultHelper.syncRecordCount(in: container) == 0)
        let uuid = try TestVaultHelper.uniqueID(entityName: "Transaction", pk: transactionPK, in: container)
        let created = try #require(TestVaultHelper.creationDate(entityName: "Transaction", uuid: uuid, in: container))
        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: uuid, in: container))
        #expect(created >= start)
        #expect(modified >= start)
    }

    @Test("transaction create stamps its dates and writes no sync record")
    func transactionCreateWritesNoSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)

        let transactions = TransactionRepository(
            container: vault.container,
            lineItemRepo: LineItemRepository(container: vault.container))
        let start = Date()
        let created = try transactions.create(
            date: "2026-04-01",
            title: "ADVISORY FEE",
            note: "Test fee",
            lineItems: [(accountId: accountPK, amount: -12.34, memo: "fee")]
        )
        #expect(created.title == "ADVISORY FEE")
        try expectInsertedWithoutSyncRecord(transactionPK: created.id, notBefore: start, in: vault.container)
    }

    @Test("security trade, income and share adjustment creates write no sync record")
    func securityCreatesWriteNoSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let ctx = vault.container.viewContext
        let dividend = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        dividend.setValue(Int16(301), forKey: "pBaseType")
        dividend.setValue("Dividend", forKey: "pName")
        dividend.setValue(UUID().uuidString, forKey: "pUniqueID")
        dividend.setValue(Date(), forKey: "pCreationTime")
        dividend.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let sec = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let symbol = BaseRepository.stringValue(sec, "pSymbol")

        let secRepo = SecurityRepository(
            container: vault.container)
        let start = Date()
        let trade = try secRepo.createSecurityTrade(
            accountId: accountPK, symbol: symbol, shares: 2, pricePerShare: 10,
            amount: 20, commission: 0, cashLineItemAmount: -20, date: "2026-02-15"
        )
        let income = try secRepo.createSecurityIncome(
            accountId: accountPK, symbol: symbol, amount: 3.5, date: "2026-02-16"
        )
        let adjustment = try secRepo.createShareAdjustment(
            accountId: accountPK, symbol: symbol, shares: 5.0, date: "2026-02-17"
        )
        #expect(income.type == "Dividend")
        for pk in [trade.id, income.id, adjustment.id] {
            try expectInsertedWithoutSyncRecord(transactionPK: pk, notBefore: start, in: vault.container)
        }
    }

    // MARK: - Line items travel inside the Transaction's record

    private func seedSyncedTransaction(
        in vault: TestVaultHelper.TestVault
    ) throws -> (transactions: TransactionRepository, lineItems: LineItemRepository, transaction: TransactionDTO, uuid: String, accountId: Int, baseline: TestVaultHelper.SyncRecordSnapshot) {
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)
        let transaction = try transactions.create(
            date: "2026-04-01", title: "Synced row",
            lineItems: [(accountId: accountPK, amount: -10, memo: nil)]
        )
        let uuid = try TestVaultHelper.uniqueID(entityName: "Transaction", pk: transaction.id, in: vault.container)
        let baseline = try TestVaultHelper.seedSyncRecord(uuid: uuid, entityType: "Transaction", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: uuid, in: vault.container)
        return (transactions, lineItems, transaction, uuid, accountPK, baseline)
    }

    @Test("adding a line item marks its transaction modified and leaves the sync record alone")
    func lineItemAddMarksTransactionModified() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let seeded = try seedSyncedTransaction(in: vault)

        _ = try seeded.lineItems.create(transactionId: seeded.transaction.id, accountId: seeded.accountId, amount: -1)

        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: seeded.uuid, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: seeded.uuid, in: vault.container) == seeded.baseline)
    }

    @Test("deleting a line item marks its transaction modified and leaves the sync record alone")
    func lineItemDeleteMarksTransactionModified() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let seeded = try seedSyncedTransaction(in: vault)
        let lineItemId = try #require(seeded.transaction.lineItems.first?.id)

        _ = try seeded.lineItems.delete(lineItemId: lineItemId)

        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: seeded.uuid, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: seeded.uuid, in: vault.container) == seeded.baseline)
    }

    @Test("updateSecurityLineItem cash-line repair marks the transaction modified, not the sync blob")
    func updateSecurityLineItemRepairsCashLineAmounts() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let txTypes = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)

        let ctx = vault.container.viewContext
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        let txUUID = BaseRepository.generateUUID()
        tx.setValue("TEST BUY", forKey: "pTitle")
        tx.setValue(txUUID, forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: "2026-03-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(txTypes.buy, forKey: "pTransactionType")

        let cashLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let cashLIUUID = BaseRepository.generateUUID()
        cashLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        cashLI.setValue(cashLIUUID, forKey: "pUniqueID")
        cashLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        cashLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        cashLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(cashLI, "pCreationTime")
        cashLI.setValue(account, forKey: "pAccount")
        cashLI.setValue(tx, forKey: "pTransaction")

        let offsetLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let offsetLIUUID = BaseRepository.generateUUID()
        offsetLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        offsetLI.setValue(offsetLIUUID, forKey: "pUniqueID")
        offsetLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        offsetLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        offsetLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(offsetLI, "pCreationTime")
        offsetLI.setValue(tx, forKey: "pTransaction")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(10.0 as NSNumber, forKey: "pShares")
        sli.setValue(-100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(10.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(0.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(cashLI, forKey: "pLineItem")

        try ctx.obtainPermanentIDs(for: [tx, cashLI, offsetLI, sli])
        try ctx.save()
        let txPK = BaseRepository.extractPK(from: tx.objectID)

        try TestVaultHelper.seedSyncRecord(uuid: txUUID, entityType: "Transaction", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: txUUID, in: vault.container)
        let baseline = try #require(TestVaultHelper.syncRecordSnapshot(uuid: txUUID, in: vault.container))

        let repo = SecurityRepository(container: vault.container)
        let updated = try repo.updateSecurityLineItem(
            transactionId: txPK,
            amount: -125,
            cashLineItemAmount: -125
        )
        #expect(updated.amount == -125)

        // The repository wrote on a background context, and
        // `automaticallyMergesChangesFromParent` delivers that merge to the view
        // context's queue asynchronously. This body now owns that queue, so the
        // merge cannot run until the body yields: the read below has to refresh
        // rather than hope the merge won a race. It saw the new values before
        // only because the body ran on the wrong thread while the main runloop
        // serviced the merge.
        vault.container.viewContext.refreshAllObjects()

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(txPK)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let balancingLine = try #require(lineItems.first { $0.accountId == 0 })
        #expect(accountLine.amount == -125)
        #expect(balancingLine.amount == 125)
        #expect(accountLine.runningBalance == -125)

        // Banktivity's merge base stays exactly as it was; the upload is
        // triggered by the bumped modification date instead.
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: txUUID, in: vault.container) == baseline)
        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: txUUID, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
    }

    @Test("updateSecurityLineItem can repair cash line item amounts with category offset")
    func updateSecurityLineItemRepairsCashLineAmountsWithCategoryOffset() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let txTypes = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)

        let ctx = vault.container.viewContext
        let category = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        category.setValue("Dividend Income Tax-Free", forKey: "pName")
        category.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        category.setValue(Int16(AccountClass.income), forKey: "pAccountClass")
        category.setValue(false, forKey: "pHidden")
        category.setValue(eur, forKey: "currency")
        BaseRepository.setNow(category, "pCreationTime")
        BaseRepository.setNow(category, "pModificationDate")

        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        let txUUID = BaseRepository.generateUUID()
        tx.setValue("TEST SELL", forKey: "pTitle")
        tx.setValue(txUUID, forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: "2026-04-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(txTypes.sell, forKey: "pTransactionType")

        let cashLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let cashLIUUID = BaseRepository.generateUUID()
        cashLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        cashLI.setValue(cashLIUUID, forKey: "pUniqueID")
        cashLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        cashLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        cashLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(cashLI, "pCreationTime")
        cashLI.setValue(account, forKey: "pAccount")
        cashLI.setValue(tx, forKey: "pTransaction")

        let categoryLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let categoryLIUUID = BaseRepository.generateUUID()
        categoryLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        categoryLI.setValue(categoryLIUUID, forKey: "pUniqueID")
        categoryLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        categoryLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        categoryLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(categoryLI, "pCreationTime")
        categoryLI.setValue(category, forKey: "pAccount")
        categoryLI.setValue(tx, forKey: "pTransaction")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(-1.0 as NSNumber, forKey: "pShares")
        sli.setValue(100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(100.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(0.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(cashLI, forKey: "pLineItem")

        try ctx.obtainPermanentIDs(for: [category, tx, cashLI, categoryLI, sli])
        try ctx.save()
        let txPK = BaseRepository.extractPK(from: tx.objectID)

        try TestVaultHelper.seedSyncRecord(uuid: txUUID, entityType: "Transaction", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: txUUID, in: vault.container)
        let baseline = try #require(TestVaultHelper.syncRecordSnapshot(uuid: txUUID, in: vault.container))

        let repo = SecurityRepository(container: vault.container)
        let updated = try repo.updateSecurityLineItem(
            transactionId: txPK,
            cashLineItemAmount: 596.06
        )
        #expect(updated.amount == 100)

        // The repository wrote on a background context, and
        // `automaticallyMergesChangesFromParent` delivers that merge to the view
        // context's queue asynchronously. This body now owns that queue, so the
        // merge cannot run until the body yields: the read below has to refresh
        // rather than hope the merge won a race. It saw the new values before
        // only because the body ran on the wrong thread while the main runloop
        // serviced the merge.
        vault.container.viewContext.refreshAllObjects()

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(txPK)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let categoryLine = try #require(lineItems.first { $0.accountId != accountPK })
        #expect(abs(accountLine.amount - 596.06) < 0.000001)
        #expect(abs(categoryLine.amount + 596.06) < 0.000001)

        #expect(TestVaultHelper.syncRecordSnapshot(uuid: txUUID, in: vault.container) == baseline)
        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: txUUID, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
    }

    @Test("transaction delete tombstones its sync record in the same save")
    func transactionDeleteTombstonesSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let seeded = try seedSyncedTransaction(in: vault)

        #expect(try seeded.transactions.delete(transactionId: seeded.transaction.id))

        // Banktivity's pending-delete mark: record kept, state 3, synced date
        // moved to now, merge base untouched.
        let after = try #require(TestVaultHelper.syncRecordSnapshot(uuid: seeded.uuid, in: vault.container))
        #expect(after.syncedState == 3)
        #expect(after.remoteEntityData == seeded.baseline.remoteEntityData)
        let syncedAt = try #require(after.syncedModificationDate)
        #expect(syncedAt > (seeded.baseline.syncedModificationDate ?? .distantPast))
    }

    @Test("deleting a row whose record is already pending deletion leaves the mark as it is")
    func deleteIsIdempotentOnPendingDeleteRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let seeded = try seedSyncedTransaction(in: vault)
        let pendingSince = Date(timeIntervalSince1970: 1_700_000_000)
        let base = BaseRepository(container: vault.container)
        let uuid = seeded.uuid
        try base.performWrite { ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
            request.predicate = NSPredicate(format: "pLocalID == %@", uuid)
            let record = try #require(try ctx.fetch(request).first)
            record.setValue(Int16(3), forKey: "pSyncedState")
            record.setValue(pendingSince, forKey: "pSyncedModificationDate")
        }

        #expect(try seeded.transactions.delete(transactionId: seeded.transaction.id))

        #expect(try seeded.transactions.get(transactionId: seeded.transaction.id) == nil)
        let after = try #require(TestVaultHelper.syncRecordSnapshot(uuid: uuid, in: vault.container))
        #expect(after.syncedState == 3)
        #expect(after.syncedModificationDate == pendingSince)
    }

    @Test("tag delete marks tagged transactions modified and tombstones the tag's record")
    func tagDeleteMarksTransactionsAndTombstonesTag() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let seeded = try seedSyncedTransaction(in: vault)
        let tags = TagRepository(container: vault.container)
        let tag = try tags.create(name: "Tax 2026")
        #expect(try tags.tagTransaction(transactionId: seeded.transaction.id, tagId: tag.id) > 0)
        let tagUUID = try TestVaultHelper.uniqueID(entityName: "Tag", pk: tag.id, in: vault.container)
        try TestVaultHelper.seedSyncRecord(uuid: tagUUID, entityType: "Tag", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: seeded.uuid, in: vault.container)

        #expect(try tags.delete(tagId: tag.id))

        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: seeded.uuid, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: seeded.uuid, in: vault.container) == seeded.baseline)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: tagUUID, in: vault.container)?.syncedState == 3)
    }

    @Test("deleting a never-synced transaction just deletes it")
    func deletingNeverSyncedTransactionMarksNothing() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let transactions = TransactionRepository(
            container: vault.container,
            lineItemRepo: LineItemRepository(container: vault.container))
        let created = try transactions.create(
            date: "2026-04-01", title: "Local only",
            lineItems: [(accountId: BaseRepository.extractPK(from: account.objectID), amount: -5, memo: nil)]
        )

        #expect(try transactions.delete(transactionId: created.id))
        #expect(try transactions.get(transactionId: created.id) == nil)
        #expect(TestVaultHelper.syncRecordCount(in: vault.container) == 0)
    }
}
