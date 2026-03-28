// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("TurtleSerializer")
struct TurtleSerializerTests {

    private func emptyData() -> VaultExportData {
        VaultExportData(
            vaultName: "Test",
            accounts: [],
            transactions: [],
            categories: [],
            tags: [],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [],
            securities: [],
            holdings: [],
            trades: [],
            income: [],
            prices: [:]
        )
    }

    @Test("empty vault produces valid turtle with only prefixes")
    func emptyVault() {
        let serializer = TurtleSerializer()
        let output = serializer.serialize(emptyData())
        #expect(output.contains("@prefix schema:"))
        #expect(output.contains("@prefix pfo:"))
        #expect(!output.contains("urn:banktivity:"))
    }

    @Test("account serialization with schema.org types")
    func accounts() {
        var data = emptyData()
        data = VaultExportData(
            vaultName: "Test",
            accounts: [
                AccountDTO(id: 1, name: "Checking", fullName: "Checking", accountClass: 1001, accountType: "Checking", hidden: false, currency: "EUR", balance: 1234.56, formattedBalance: nil),
                AccountDTO(id: 2, name: "Visa", fullName: "Visa", accountClass: 5001, accountType: "Credit Card", hidden: false, currency: "EUR", balance: -500.0, formattedBalance: nil),
            ],
            transactions: [],
            categories: [],
            tags: [],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [],
            securities: [],
            holdings: [],
            trades: [],
            income: [],
            prices: [:]
        )
        let output = TurtleSerializer().serialize(data)
        #expect(output.contains("<urn:banktivity:account:1> a schema:BankAccount"))
        #expect(output.contains("<urn:banktivity:account:2> a schema:CreditCard"))
        #expect(output.contains("schema:name \"Checking\""))
        #expect(output.contains("schema:currency \"EUR\""))
        #expect(output.contains("pfo:balance \"1234.56\"^^xsd:decimal"))
    }

    @Test("category hierarchy with skos:broader")
    func categories() {
        let data = VaultExportData(
            vaultName: "Test",
            accounts: [],
            transactions: [],
            categories: [
                CategoryDTO(id: 100, name: "Food", fullName: "Food", type: "expense", accountClass: 7000, parentId: nil, hidden: false, uniqueId: "u1", currency: "EUR"),
                CategoryDTO(id: 101, name: "Groceries", fullName: "Food:Groceries", type: "expense", accountClass: 7000, parentId: 100, hidden: false, uniqueId: "u2", currency: "EUR"),
            ],
            tags: [],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [],
            securities: [],
            holdings: [],
            trades: [],
            income: [],
            prices: [:]
        )
        let output = TurtleSerializer().serialize(data)
        #expect(output.contains("<urn:banktivity:category:100> a pfo:ExpenseCategory"))
        #expect(output.contains("<urn:banktivity:category:101> a pfo:ExpenseCategory"))
        #expect(output.contains("skos:broader <urn:banktivity:category:100>"))
        #expect(output.contains("pfo:fullName \"Food:Groceries\""))
    }

    @Test("transaction with line items and tags")
    func transactionWithLineItems() {
        let data = VaultExportData(
            vaultName: "Test",
            accounts: [],
            transactions: [
                TransactionDTO(
                    id: 500,
                    date: "2026-03-15",
                    title: "Albert Heijn",
                    note: "Weekly shop",
                    cleared: true,
                    voided: false,
                    transactionType: "withdrawal",
                    lineItems: [
                        LineItemDTO(id: 1001, accountId: 1, accountName: "Checking", amount: -45.50, memo: nil, runningBalance: nil, cleared: true, statementId: 10, tags: [TagDTO(id: 5, name: "Groceries")]),
                        LineItemDTO(id: 1002, accountId: 100, accountName: "Food", amount: 45.50, memo: nil, runningBalance: nil),
                    ]
                )
            ],
            categories: [],
            tags: [],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [],
            securities: [],
            holdings: [],
            trades: [],
            income: [],
            prices: [:]
        )
        let output = TurtleSerializer().serialize(data)
        #expect(output.contains("<urn:banktivity:transaction:500> a pfo:Transaction"))
        #expect(output.contains("schema:dateCreated \"2026-03-15\"^^xsd:date"))
        #expect(output.contains("schema:description \"Weekly shop\""))
        #expect(output.contains("pfo:transactionType \"withdrawal\""))
        #expect(output.contains("pfo:lineItem <urn:banktivity:lineitem:1001>"))
        #expect(output.contains("<urn:banktivity:lineitem:1001> a pfo:LineItem"))
        #expect(output.contains("pfo:account <urn:banktivity:account:1>"))
        #expect(output.contains("schema:amount \"-45.5\"^^xsd:decimal"))
        #expect(output.contains("pfo:statement <urn:banktivity:statement:10>"))
        #expect(output.contains("pfo:tag <urn:banktivity:tag:5>"))
    }

    @Test("security with prices")
    func securityWithPrices() {
        let data = VaultExportData(
            vaultName: "Test",
            accounts: [],
            transactions: [],
            categories: [],
            tags: [],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [],
            securities: [
                SecurityDTO(id: 10, name: "Apple Inc", symbol: "AAPL", uniqueId: "sec1", currency: "USD", securityType: 1),
            ],
            holdings: [],
            trades: [
                SecurityTradeDTO(id: 200, date: "2026-01-10", type: "buy", symbol: "AAPL", securityName: "Apple Inc", shares: 10.0, pricePerShare: 150.0, amount: 1500.0, commission: 9.99, accountName: "Brokerage", accountId: 5),
            ],
            income: [],
            prices: [
                "AAPL": [
                    SecurityPriceDTO(id: 300, date: "2026-03-15", closePrice: 175.0, adjustedClosePrice: 175.0, openPrice: 173.0, highPrice: 176.0, lowPrice: 172.0, volume: 1000000, dataSource: 1),
                ]
            ]
        )
        let output = TurtleSerializer().serialize(data)
        #expect(output.contains("<urn:banktivity:security:10> a schema:FinancialProduct"))
        #expect(output.contains("schema:tickerSymbol \"AAPL\""))
        #expect(output.contains("<urn:banktivity:trade:200> a schema:TradeAction"))
        #expect(output.contains("pfo:shares \"10.0\"^^xsd:decimal"))
        #expect(output.contains("schema:price \"150.0\"^^xsd:decimal"))
        #expect(output.contains("pfo:commission \"9.99\"^^xsd:decimal"))
        #expect(output.contains("<urn:banktivity:price:300> a pfo:SecurityPrice"))
        #expect(output.contains("pfo:closePrice \"175.0\"^^xsd:decimal"))
        #expect(output.contains("pfo:openPrice \"173.0\"^^xsd:decimal"))
    }

    @Test("statement serialization")
    func statements() {
        let data = VaultExportData(
            vaultName: "Test",
            accounts: [],
            transactions: [],
            categories: [],
            tags: [],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [
                ExportStatementDTO(accountId: 1, accountName: "Checking", summary: StatementSummaryDTO(id: 50, name: "March 2026", startDate: "2026-03-01", endDate: "2026-03-31", beginningBalance: 1000.0, endingBalance: 1200.0, reconciledLineItemCount: 15, isBalanced: true)),
            ],
            securities: [],
            holdings: [],
            trades: [],
            income: [],
            prices: [:]
        )
        let output = TurtleSerializer().serialize(data)
        #expect(output.contains("<urn:banktivity:statement:50> a pfo:BankStatement"))
        #expect(output.contains("pfo:account <urn:banktivity:account:1>"))
        #expect(output.contains("schema:startDate \"2026-03-01\"^^xsd:date"))
        #expect(output.contains("pfo:beginningBalance \"1000.0\"^^xsd:decimal"))
        #expect(output.contains("pfo:isBalanced true"))
    }

    @Test("tags serialized as schema:DefinedTerm")
    func tags() {
        let data = VaultExportData(
            vaultName: "Test",
            accounts: [],
            transactions: [],
            categories: [],
            tags: [
                TagDTO(id: 1, name: "Vacation"),
                TagDTO(id: 2, name: "Tax Deductible"),
            ],
            templates: [],
            importRules: [],
            scheduled: [],
            statements: [],
            securities: [],
            holdings: [],
            trades: [],
            income: [],
            prices: [:]
        )
        let output = TurtleSerializer().serialize(data)
        #expect(output.contains("<urn:banktivity:tag:1> a schema:DefinedTerm"))
        #expect(output.contains("schema:name \"Vacation\""))
        #expect(output.contains("schema:name \"Tax Deductible\""))
    }
}
