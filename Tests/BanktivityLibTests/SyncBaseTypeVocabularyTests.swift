// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// The sync blob's `baseType` must describe the row it is attached to.
///
/// It did not. Five call sites built that string by hand and three built it
/// wrong: `securities create-income` always wrote `dividend` whatever
/// `--income-type` asked for, `securities adjust` always wrote `buy` or `sell`
/// whatever movement type it had just resolved, and `transactions create` wrote
/// `deposit` for everything that was not a deposit. Measured on a production
/// vault of 22,361 transaction sync records: 12 Return Of Capital rows and one
/// Cap. Gains Long row carry `dividend`, and 10 Split Shares rows carry a
/// spelling Banktivity's own enum does not contain.
///
/// The row was right in Core Data every time, which is why this stayed invisible
/// -- `transactions get` reads the type through `pTransactionType` and reports it
/// correctly. Only the record that describes the row to every other device
/// disagreed.
// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("Sync base type vocabulary", .serialized)
@MainActor
struct SyncBaseTypeVocabularyTests {

    /// Two of these are misspelled and both are load-bearing. They come from the
    /// `IGGCSyncAccountingTransactionBaseType` string table in `IGGSyncServices`
    /// and are confirmed by what Banktivity itself wrote into this vault.
    /// Correcting the spelling would emit a value the enum does not contain.
    @Test(
        "the enum keeps Banktivity's spelling, including the two typos",
        arguments: [
            (Int16(250), "slpit-shares"),
            (Int16(300), "misc-inv-income"),
            (Int16(304), "intrest-income"),
            (Int16(301), "dividend"),
            (Int16(302), "cap-gains-short"),
            (Int16(303), "cap-gains-long"),
            (Int16(310), "return-of-capital"),
            (Int16(1), "deposit"),
            (Int16(2), "withdrawal"),
        ]
    )
    func enumSpellingIsBanktivitys(baseType: Int16, expected: String) {
        #expect(SyncBlobUpdater.syncBaseTypeName(for: baseType) == expected)
    }

    /// The CLI's own `--transaction-type` vocabulary is a different vocabulary.
    /// Deriving one from the other is the defect, so this asserts they differ.
    @Test("the CLI slug vocabulary is not the sync enum")
    func theTwoVocabulariesAreNotTheSame() {
        for (slug, code) in TransactionRepository.transactionTypeBaseTypes where code == 250 || code == 300 || code == 304 {
            let syncName = SyncBlobUpdater.syncBaseTypeName(for: Int16(code))
            #expect(syncName != slug, "slug \(slug) must not be used as the sync enum value")
        }
    }

    @Test("a base type the enum cannot name is refused rather than guessed")
    func anUnknownBaseTypeWritesNoRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)

        let updater = SyncBlobUpdater(container: vault.container)
        let txUUID = UUID().uuidString
        updater.createTransactionSyncRecord(
            transactionUUID: txUUID,
            currencyUUID: BaseRepository.stringValue(usd, "pUniqueID"),
            date: "2026-03-01", title: "Unnameable", note: nil, adjustment: false,
            lineItems: [SyncBlobUpdater.SyncLineItem(
                accountUUID: UUID().uuidString, accountAmount: 1, cleared: false,
                identifier: UUID().uuidString, memo: nil, securityLineItem: nil,
                transactionAmount: 1
            )],
            transactionTypeBaseTypeCode: 999, transactionTypeUUID: UUID().uuidString
        )

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        #expect(try vault.container.viewContext.fetch(request).isEmpty)
    }

    // MARK: - The write paths that got it wrong

    private func syncXML(for txUUID: String, in container: NSPersistentContainer) throws -> String {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try container.viewContext.fetch(request).first)
        let blob = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blob))
        return try #require(String(data: decompressed, encoding: .utf8))
    }

    private func baseTypeField(_ xml: String) throws -> String {
        let marker = "<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">"
        let start = try #require(xml.range(of: marker))
        let end = try #require(xml.range(of: "</field>", range: start.upperBound..<xml.endIndex))
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private func seedIncomeVault() throws -> (vault: TestVaultHelper.TestVault, accountId: Int, categoryId: Int) {
        let vault = try TestVaultHelper.createFreshVault()
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let ctx = vault.container.viewContext
        for (code, name) in [(Int16(301), "Dividend"), (Int16(310), "Return Of Capital"), (Int16(250), "Split Shares")] {
            let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
            type.setValue(code, forKey: "pBaseType")
            type.setValue(name, forKey: "pName")
            type.setValue(UUID().uuidString, forKey: "pUniqueID")
            type.setValue(Date(), forKey: "pCreationTime")
            type.setValue(Date(), forKey: "pModificationDate")
        }
        try ctx.save()
        _ = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: usd)
        let accounts = AccountRepository(container: vault.container)
        let account = try accounts.create(name: "Income vault", accountClass: AccountClass.investment, currencyCode: "USD")
        let categories = CategoryRepository(container: vault.container)
        let category = try categories.create(name: "Investment income", type: "income", currencyCode: "USD")
        return (vault, account.id, category.id)
    }

    @Test("a return-of-capital income says so in its sync record, and echoes the vault's label")
    func incomeSyncRecordNamesTheIncomeType() throws {
        let seeded = try seedIncomeVault()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        _ = try TestVaultHelper.seedSecurity(
            in: seeded.vault.container, symbol: "BX",
            currency: try TestVaultHelper.seedCurrencies(in: seeded.vault.container).usd
        )

        let securities = SecurityRepository(
            container: seeded.vault.container,
            syncBlobUpdater: SyncBlobUpdater(container: seeded.vault.container)
        )
        let income = try securities.createSecurityIncome(
            accountId: seeded.accountId, symbol: "BX", amount: 2.59, date: "2026-09-04",
            offsetCategoryId: seeded.categoryId, incomeType: "return-of-capital"
        )

        // The echo is the vault's own label, so a create agrees with its readback.
        #expect(income.type == "Return Of Capital")

        // The sync record is keyed by the transaction's UUID, which the DTO does
        // not carry, so read it off the row the create just wrote.
        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        let rows = try seeded.vault.container.viewContext.fetch(txRequest)
        let row = try #require(rows.first { BaseRepository.extractPK(from: $0.objectID) == income.id })
        let xml = try syncXML(for: BaseRepository.stringValue(row, "pUniqueID"), in: seeded.vault.container)
        #expect(try baseTypeField(xml) == "return-of-capital")
    }

    /// The base type is read from the store, so the conversion to `Int16` has to
    /// be total: a trapping initialiser would turn unreadable data into a crash.
    @Test("a base type outside the enum resolves to no name rather than trapping")
    func outOfRangeBaseTypeHasNoName() {
        #expect(SyncBlobUpdater.syncBaseTypeName(for: 0) == nil)
        #expect(SyncBlobUpdater.syncBaseTypeName(for: Int16.max) == nil)
        #expect(SyncBlobUpdater.syncBaseTypeName(for: -1) == nil)
    }
}
