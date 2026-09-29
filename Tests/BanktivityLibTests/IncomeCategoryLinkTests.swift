import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// An income row's category is read through its security leg's
/// `pIncomeCategoryLineItemID`, not by inspecting the other line. `create-income`
/// left it nil, and every dividend it wrote showed "Uncategorized" in Banktivity
/// although its category line was right (9617's 21 restored dividends,
/// 2026-09-29). Compared field by field against a Banktivity-written dividend,
/// that pointer and `pDistributionType` (1, "deposit") were the only differences.
@Suite("Income rows link their category line")
struct IncomeCategoryLinkTests {

    private func seed() throws -> (vault: TestVaultHelper.TestVault, accountId: Int, categoryId: Int) {
        let vault = try TestVaultHelper.createFreshVault()
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let ctx = vault.container.viewContext
        let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        type.setValue(Int16(301), forKey: "pBaseType")
        type.setValue("Dividend", forKey: "pName")
        type.setValue(UUID().uuidString, forKey: "pUniqueID")
        type.setValue(Date(), forKey: "pCreationTime")
        type.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
        _ = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "BBCA", currency: usd)
        let account = try AccountRepository(container: vault.container)
            .create(name: "Taxable", accountClass: AccountClass.investment, currencyCode: "USD")
        let category = try CategoryRepository(container: vault.container)
            .create(name: "Dividend Income", type: "income", currencyCode: "USD")
        return (vault, account.id, category.id)
    }

    /// Read the security leg's link and the category line's UUID, fresh, inside
    /// a context that stays alive for the whole read.
    private func readLink(_ transactionId: Int, in container: NSPersistentContainer)
        -> (linked: String?, distType: Int16, categoryLineUUID: String?) {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var out: (String?, Int16, String?) = (nil, 0, nil)
        ctx.performAndWait {
            let rows = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))) ?? []
            guard let tx = rows.first(where: { BaseRepository.extractPK(from: $0.objectID) == transactionId }),
                  let lines = tx.value(forKey: "lineItems") as? Set<NSManagedObject> else { return }
            let sli = lines.compactMap { $0.value(forKey: "pSecurityLineItem") as? NSManagedObject }.first
            let category = lines.first { $0.value(forKey: "pSecurityLineItem") == nil }
            out = (sli?.value(forKey: "pIncomeCategoryLineItemID") as? String,
                   (sli?.value(forKey: "pDistributionType") as? NSNumber)?.int16Value ?? 0,
                   category.map { BaseRepository.stringValue($0, "pUniqueID") })
        }
        return (out.0, out.1, out.2)
    }

    /// Reproduce a row written before the fix: pointer nil, distribution type 0.
    private func unlink(_ transactionId: Int, in container: NSPersistentContainer) {
        let ctx = container.newBackgroundContext()
        ctx.performAndWait {
            let rows = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))) ?? []
            guard let tx = rows.first(where: { BaseRepository.extractPK(from: $0.objectID) == transactionId }),
                  let lines = tx.value(forKey: "lineItems") as? Set<NSManagedObject>,
                  let sli = lines.compactMap({ $0.value(forKey: "pSecurityLineItem") as? NSManagedObject }).first
            else { return }
            sli.setValue(nil, forKey: "pIncomeCategoryLineItemID")
            sli.setValue(Int16(0) as NSNumber, forKey: "pDistributionType")
            try? ctx.save()
        }
    }

    @Test("create-income points the security leg at its category line, as a deposit")
    func createIncomeLinksItsCategory() throws {
        let seeded = try seed()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        let securities = SecurityRepository(container: seeded.vault.container)
        let income = try securities.createSecurityIncome(
            accountId: seeded.accountId, symbol: "BBCA", amount: 12.59, date: "2026-06-25",
            offsetCategoryId: seeded.categoryId)

        let link = readLink(income.id, in: seeded.vault.container)
        #expect(link.categoryLineUUID != nil)
        #expect(link.linked == link.categoryLineUUID)
        #expect(link.distType == SecurityRepository.distributionTypeDeposit)

        let listed = try securities.getIncome(accountId: seeded.accountId)
        #expect(listed.first { $0.id == income.id }?.categoryLinked == true)
    }

    @Test("link-income-category repairs an unlinked row, and a dry run writes nothing")
    func linkRepairsAnUnlinkedRow() throws {
        let seeded = try seed()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        let securities = SecurityRepository(container: seeded.vault.container)
        let income = try securities.createSecurityIncome(
            accountId: seeded.accountId, symbol: "BBCA", amount: 7.23, date: "2026-08-03",
            offsetCategoryId: seeded.categoryId)

        unlink(income.id, in: seeded.vault.container)
        #expect(try securities.getIncome(accountId: seeded.accountId)
            .first { $0.id == income.id }?.categoryLinked == false)

        let dry = try securities.linkIncomeCategory(transactionId: income.id, dryRun: true)
        #expect(dry["status"] == "would_link")
        #expect(readLink(income.id, in: seeded.vault.container).linked == nil)

        let done = try securities.linkIncomeCategory(transactionId: income.id)
        #expect(done["status"] == "linked")
        let link = readLink(income.id, in: seeded.vault.container)
        #expect(link.linked == link.categoryLineUUID)
        #expect(link.distType == SecurityRepository.distributionTypeDeposit)

        #expect(try securities.linkIncomeCategory(transactionId: income.id)["status"] == "already_linked")
    }

    @Test("a row that is already linked is never re-pointed, and a reinvest keeps type 3")
    func linkedRowsAreLeftAlone() throws {
        let seeded = try seed()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        let securities = SecurityRepository(container: seeded.vault.container)
        let income = try securities.createSecurityIncome(
            accountId: seeded.accountId, symbol: "BBCA", amount: 5.00, date: "2026-08-10",
            offsetCategoryId: seeded.categoryId)
        // Make it look like Banktivity's own reinvested dividend: linked, type 3.
        let ctx = seeded.vault.container.newBackgroundContext()
        ctx.performAndWait {
            let rows = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))) ?? []
            if let tx = rows.first(where: { BaseRepository.extractPK(from: $0.objectID) == income.id }),
               let lines = tx.value(forKey: "lineItems") as? Set<NSManagedObject>,
               let sli = lines.compactMap({ $0.value(forKey: "pSecurityLineItem") as? NSManagedObject }).first {
                sli.setValue(Int16(3) as NSNumber, forKey: "pDistributionType")
                try? ctx.save()
            }
        }
        #expect(try securities.linkIncomeCategory(transactionId: income.id)["status"] == "already_linked")
        #expect(readLink(income.id, in: seeded.vault.container).distType == 3)

        // Pointing somewhere else is refused, not overwritten.
        ctx.performAndWait {
            let rows = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))) ?? []
            if let tx = rows.first(where: { BaseRepository.extractPK(from: $0.objectID) == income.id }),
               let lines = tx.value(forKey: "lineItems") as? Set<NSManagedObject>,
               let sli = lines.compactMap({ $0.value(forKey: "pSecurityLineItem") as? NSManagedObject }).first {
                sli.setValue("SOME-OTHER-LINE", forKey: "pIncomeCategoryLineItemID")
                try? ctx.save()
            }
        }
        #expect(throws: (any Error).self) { try securities.linkIncomeCategory(transactionId: income.id) }
        #expect(readLink(income.id, in: seeded.vault.container).linked == "SOME-OTHER-LINE")
    }
}
