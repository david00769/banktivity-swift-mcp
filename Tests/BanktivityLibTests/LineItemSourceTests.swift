// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("Line item source", .serialized)
@MainActor
struct LineItemSourceTests {

    @Test("An imported line item returns its raw import record; a manual one returns none")
    func sourcesForImportedAndManualLineItems() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)
        let accounts = AccountRepository(container: vault.container)
        let checking = try accounts.create(name: "Checking", accountClass: AccountClass.checking, currencyCode: "USD")
        let imported = try transactions.create(
            date: "2026-10-01", title: "COFFEE SHOP",
            lineItems: [(accountId: checking.id, amount: -4.5, memo: nil)]
        )
        let manual = try transactions.create(
            date: "2026-10-02", title: "Cash",
            lineItems: [(accountId: checking.id, amount: -20, memo: nil)]
        )
        let importedLineId = try #require(imported.lineItems.first { $0.accountId == checking.id }?.id)
        let manualLineId = try #require(manual.lineItems.first { $0.accountId == checking.id }?.id)

        let base = BaseRepository(container: vault.container)
        try base.performWrite { ctx in
            guard let lineItem = try base.fetchByPK(entityName: "LineItem", pk: importedLineId, in: ctx) else {
                throw ToolError.notFound("Line item not found: \(importedLineId)")
            }
            let source = BaseRepository.createObject(entityName: "LineItemSource", in: ctx)
            source.setValue("SQ *COFFEE SHOP 1234", forKey: "pDetails")
            source.setValue("plaid", forKey: "pSourceType")
            source.setValue("txn-abc", forKey: "pSourceIdentifier")
            source.setValue(true, forKey: "pMatched")
            source.setValue(NSDecimalNumber(string: "-4.50"), forKey: "pAmount")
            BaseRepository.setDate(source, "pDate", isoString: "2026-10-01")
            source.setValue(lineItem, forKey: "pLineItem")
        }

        let sources = try lineItems.getSources(lineItemId: importedLineId)
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.details == "SQ *COFFEE SHOP 1234")
        #expect(source.sourceType == "plaid")
        #expect(source.sourceIdentifier == "txn-abc")
        #expect(source.matched)
        #expect(abs(source.amount - -4.5) < 0.0001)
        #expect(source.date == "2026-10-01")

        #expect(try lineItems.getSources(lineItemId: manualLineId).isEmpty)
    }

    @Test("An unknown line item is not found rather than an empty list")
    func unknownLineItemIsNotFound() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let lineItems = LineItemRepository(container: vault.container)
        #expect(throws: ToolError.self) {
            _ = try lineItems.getSources(lineItemId: 999_999)
        }
    }
}
