// Copyright (c) 2026 Steve Flinter. MIT License.

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
}
