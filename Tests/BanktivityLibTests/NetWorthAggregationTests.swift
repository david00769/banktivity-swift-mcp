// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

struct NetWorthAggregationTests {
    @Test func missingExchangeRateExcludesAccountAndWarns() {
        let result = AccountRepository.convertNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                AccountRepository.NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", cash: 100, holdings: 0),
                AccountRepository.NetWorthAccountBalance(name: "Foreign Asset", accountClass: AccountClass.cash, currency: "GBP", cash: 50, holdings: 0),
            ],
            rates: []
        )

        #expect(result.converted.assets == 100)
        #expect(result.converted.netWorth == 100)
        #expect(result.breakdown["GBP"] == nil)
        #expect(result.warnings.contains("Account Foreign Asset (GBP) left out: no GBP->KZT exchange rate in the vault"))
    }

    @Test func reportingCurrencyAccountUsesIdentityRateWithoutWarning() {
        let result = AccountRepository.convertNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                AccountRepository.NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", cash: 100, holdings: 0),
            ],
            rates: []
        )

        #expect(result.converted.assets == 100)
        #expect(result.breakdown["KZT"]?.rate == 1)
        #expect(result.breakdown["KZT"]?.hops == 0)
        #expect(result.warnings.isEmpty)
    }

    @Test func missingRateAccountIsListedAndMarksResultIncomplete() {
        let result = AccountRepository.convertNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                AccountRepository.NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", cash: 100, holdings: 0),
                AccountRepository.NetWorthAccountBalance(id: 7, name: "Foreign Asset", accountClass: AccountClass.cash, currency: "GBP", cash: 50, holdings: 3),
            ],
            rates: []
        )
        #expect(result.excluded.count == 1)
        let excluded = result.excluded[0]
        #expect(excluded.accountId == 7 && excluded.name == "Foreign Asset" && excluded.currency == "GBP")
        #expect(excluded.cash == 50 && excluded.holdings == 3)
        #expect(excluded.reason.contains("GBP->KZT"))
    }

    @Test func fullyConvertibleVaultIsComplete() {
        let result = AccountRepository.convertNetWorth(
            reportingCurrency: "KZT",
            accounts: [AccountRepository.NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", cash: 100, holdings: 0)],
            rates: []
        )
        #expect(result.excluded.isEmpty)
        let dto = NetWorthDTO(assets: 0, liabilities: 0, netWorth: 0, formattedAssets: nil, formattedLiabilities: nil,
                              formattedNetWorth: nil, excludedAccounts: result.excluded)
        #expect(dto.complete)
        let missing = NetWorthDTO(assets: 0, liabilities: 0, netWorth: 0, formattedAssets: nil, formattedLiabilities: nil,
                                  formattedNetWorth: nil, excludedAccounts: [ExcludedNetWorthAccountDTO(
                                    accountId: 1, name: "x", currency: "GBP", cash: 1, holdings: 0, reason: "r")])
        #expect(!missing.complete)
    }
}

@Suite("Net worth with duplicate currency rows", .serialized)
@MainActor
struct NetWorthDuplicateCurrencyTests {
    @Test func duplicateCurrencyUniqueIdDoesNotCrash() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let ctx = vault.container.viewContext
        let dup = NSEntityDescription.insertNewObject(forEntityName: "Currency", into: ctx)
        dup.setValue("USX", forKey: "pCode")
        dup.setValue("Duplicate", forKey: "pName")
        dup.setValue(usd.value(forKey: "pUniqueID"), forKey: "pUniqueID")
        dup.setValue(Date(), forKey: "pCreationTime")
        dup.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()

        let codes = try ExchangeRateRepository.currencyCodesByUniqueId(in: ctx)
        #expect(codes[usd.value(forKey: "pUniqueID") as! String] == "USD")
        _ = try AccountRepository(container: vault.container).getNetWorth()
    }
}
