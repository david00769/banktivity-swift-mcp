// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Reporting currency and exchange rates")
struct ReportingCurrencyTests {

    @Test("Reporting currency codes are validated, with EUR as the fallback")
    func validatesCodes() {
        #expect(ReportingCurrency.resolve(nil) == "EUR")
        #expect(ReportingCurrency.resolve("") == "EUR")
        #expect(ReportingCurrency.resolve(" usd ") == "USD")
        #expect(ReportingCurrency.resolve("ZZZ") == "EUR")

        #expect(ReportingCurrency.fromEnvironment([:]) == ("EUR", nil))
        #expect(ReportingCurrency.fromEnvironment(["BANKTIVITY_REPORTING_CURRENCY": "aud"]) == ("AUD", nil))
        let unknown = ReportingCurrency.fromEnvironment(["BANKTIVITY_REPORTING_CURRENCY": "ZZZ"])
        #expect(unknown.code == "EUR")
        #expect(unknown.warning?.contains("ZZZ") == true)
    }

    @Test("Rate lookup: latest direct, then inverse of reverse, then through USD")
    func rateLookup() {
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        let direct = ExchangeRateRepository.resolve(from: "AUD", to: "USD", rates: [
            ExchangeRateRecord(source: "AUD", destination: "USD", rate: Decimal(string: "0.60")!, effectiveDate: older),
            ExchangeRateRecord(source: "AUD", destination: "USD", rate: Decimal(string: "0.65")!, effectiveDate: newer),
        ])
        #expect(direct?.rate == Decimal(string: "0.65")!)
        #expect(direct?.hops == 1)

        let reverse = ExchangeRateRepository.resolve(from: "USD", to: "AUD", rates: [
            ExchangeRateRecord(source: "AUD", destination: "USD", rate: Decimal(string: "0.5")!, effectiveDate: newer),
        ])
        #expect(reverse?.rate == Decimal(2))

        let pivot = ExchangeRateRepository.resolve(from: "EUR", to: "AUD", rates: [
            ExchangeRateRecord(source: "EUR", destination: "USD", rate: Decimal(string: "1.2")!, effectiveDate: older),
            ExchangeRateRecord(source: "USD", destination: "AUD", rate: Decimal(string: "1.5")!, effectiveDate: newer),
        ])
        #expect(pivot?.rate == Decimal(string: "1.8")!)
        #expect(pivot?.hops == 2)
        #expect(pivot?.effectiveDate == older)
        #expect(pivot?.path == ["EUR", "USD", "AUD"])

        #expect(ExchangeRateRepository.resolve(from: "GBP", to: "AUD", rates: []) == nil)
        #expect(ExchangeRateRepository.resolve(from: "AUD", to: "AUD", rates: [])?.rate == 1)
        // A zero rate is never used.
        #expect(ExchangeRateRepository.resolve(from: "AUD", to: "USD", rates: [
            ExchangeRateRecord(source: "AUD", destination: "USD", rate: 0, effectiveDate: newer),
        ]) == nil)
    }

    @Test("Converted net worth: cash and holdings converted, an account with no rate left out and named")
    func convertNetWorth() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rates = [ExchangeRateRecord(source: "AUD", destination: "USD", rate: Decimal(string: "0.5")!, effectiveDate: now)]
        let result = AccountRepository.convertNetWorth(
            reportingCurrency: "USD",
            accounts: [
                .init(name: "US Checking", accountClass: AccountClass.checking, currency: "USD", cash: 1000, holdings: 0),
                .init(name: "AU Broker", accountClass: AccountClass.investment, currency: "AUD", cash: 200, holdings: 4000),
                .init(name: "US Card", accountClass: AccountClass.creditCard, currency: "USD", cash: -300, holdings: 0),
                .init(name: "UK Savings", accountClass: AccountClass.savings, currency: "GBP", cash: 50, holdings: 0),
            ],
            rates: rates,
            now: now
        )
        #expect(result.converted.currency == "USD")
        #expect(result.converted.assets == 1100)        // 1000 + 200 x 0.5
        #expect(result.converted.liabilities == -300)
        #expect(result.converted.netWorth == 800)
        #expect(result.converted.holdingsValue == 2000) // 4000 x 0.5
        #expect(result.converted.netWorthWithHoldings == 2800)
        #expect(result.breakdown["AUD"]?.cash == 200)
        #expect(result.breakdown["AUD"]?.convertedHoldingsValue == 2000)
        #expect(result.breakdown["GBP"] == nil)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("UK Savings") == true)
    }
}

@Suite("Net worth with a reporting currency", .serialized)
@MainActor
struct NetWorthReportingCurrencyTests {

    @Test("Existing net worth fields are unchanged; converted totals are added beside them")
    func existingFieldsUnchanged() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container, reportingCurrency: "USD")
        let usAccount = try accounts.create(name: "US Checking", accountClass: AccountClass.checking, currencyCode: "USD")
        let euAccount = try accounts.create(name: "EU Savings", accountClass: AccountClass.savings, currencyCode: "EUR")

        // Written through a background context, like the repositories do,
        // rather than the view context (see TestVaultHelper).
        let usdID = usd.objectID, eurID = eur.objectID
        let usPK = usAccount.id, euPK = euAccount.id
        let base = BaseRepository(container: vault.container)
        try base.performWrite { ctx in
            for (pk, amount) in [(usPK, 1000.0), (euPK, 500.0)] {
                guard let account = try base.fetchByPK(entityName: "Account", pk: pk, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(pk)")
                }
                let line = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
                line.setValue(NSDecimalNumber(value: amount), forKey: "pTransactionAmount")
                line.setValue(NSDecimalNumber.one, forKey: "pExchangeRate")
                line.setValue(UUID().uuidString, forKey: "pUniqueID")
                line.setValue(false, forKey: "pCleared")
                BaseRepository.setNow(line, "pCreationTime")
                line.setValue(account, forKey: "pAccount")
            }
            // The vault stores currencies by unique ID; 1 EUR = 1.1 USD.
            let usd = try ctx.existingObject(with: usdID)
            let eur = try ctx.existingObject(with: eurID)
            let rate = NSEntityDescription.insertNewObject(forEntityName: "ExchangeRate", into: ctx)
            rate.setValue(eur.value(forKey: "pUniqueID"), forKey: "pSourceCurrencyID")
            rate.setValue(usd.value(forKey: "pUniqueID"), forKey: "pDestinationCurrencyID")
            rate.setValue(NSDecimalNumber(string: "1.1"), forKey: "pExchangeRate")
            rate.setValue(Date(), forKey: "pEffectiveDate")
            rate.setValue(Date(), forKey: "pCreationTime")
            rate.setValue(Date(), forKey: "pModificationDate")
        }

        let netWorth = try accounts.getNetWorth()
        // Unchanged: the plain sum of both accounts, labelled as before.
        #expect(abs(netWorth.assets - 1500) < 0.000001)
        #expect(abs(netWorth.netWorth - 1500) < 0.000001)
        #expect(netWorth.formattedNetWorth == formatCurrency(1500))
        // Added: converted into USD.
        #expect(netWorth.reportingCurrency == "USD")
        let converted = try #require(netWorth.converted)
        #expect(abs(converted.assets - 1550) < 0.000001)
        #expect(abs(converted.netWorth - 1550) < 0.000001)
        #expect(netWorth.currencyBreakdown?["EUR"]?.rate == 1.1)
        #expect(netWorth.warnings == [])

        // The summary carries the same net worth.
        let summary = try accounts.getSummary(tagCount: 0)
        #expect(summary.netWorth.netWorth == netWorth.netWorth)
        #expect(summary.netWorth.converted?.netWorth == converted.netWorth)
    }
}
