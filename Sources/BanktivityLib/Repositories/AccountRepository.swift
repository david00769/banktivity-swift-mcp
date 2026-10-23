// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for account operations using Core Data
public final class AccountRepository: BaseRepository, @unchecked Sendable {
    /// Currency that converted aggregates (net worth, summary) are reported in.
    public let reportingCurrency: String
    private let reportingCurrencyWarning: String?

    /// - Parameter reportingCurrency: ISO code for converted totals. When nil,
    ///   read from `BANKTIVITY_REPORTING_CURRENCY`, falling back to EUR.
    public init(container: NSPersistentContainer, reportingCurrency: String? = nil) {
        if let reportingCurrency {
            self.reportingCurrency = ReportingCurrency.resolve(reportingCurrency)
            self.reportingCurrencyWarning = nil
        } else {
            let configured = ReportingCurrency.fromEnvironment()
            self.reportingCurrency = configured.code
            self.reportingCurrencyWarning = configured.warning
        }
        super.init(container: container)
    }

    /// List all accounts, optionally including hidden ones
    public func list(includeHidden: Bool = false) throws -> [AccountDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")

            if !includeHidden {
                request.predicate = NSPredicate(format: "pHidden == NO OR pHidden == nil")
            }

            request.sortDescriptors = [
                NSSortDescriptor(key: "pAccountClass", ascending: true),
                NSSortDescriptor(key: "pName", ascending: true),
            ]

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Get a single account by its primary key (Z_PK)
    public func get(accountId: Int) throws -> AccountDTO? {
        try performRead { [self] ctx in
            guard let object = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else { return nil }
            return self.mapToDTO(object)
        }
    }

    /// Find an account by name (case-insensitive, checks both pName and pFullName)
    public func findByName(_ name: String) throws -> AccountDTO? {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
            request.predicate = NSPredicate(
                format: "pName ==[cd] %@ OR pFullName ==[cd] %@", name, name
            )
            request.fetchLimit = 1

            guard let object = try ctx.fetch(request).first else { return nil }
            return self.mapToDTO(object)
        }
    }

    /// Get account balance using account-currency line item amounts
    public func getBalance(accountId: Int) throws -> Double {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            return try self.sumLineItemAmounts(predicate: NSPredicate(format: "pAccount == %@", account), in: ctx)
        }
    }

    /// Market value of an investment account's open security positions.
    ///
    /// For each security: shares held x latest close x the price multiplier of
    /// the most recent trade, summed in `Decimal`. The price multiplier is how
    /// Banktivity converts a security priced in another currency into the
    /// account's currency (1 when they match). A security with no price
    /// contributes 0.
    ///
    /// This is reported beside the cash balance and never folded into it:
    /// `getBalance` stays the sum of the account's cash lines. Returns nil for
    /// an account that is not an investment account.
    public func holdingsValue(accountId: Int) throws -> Double? {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            guard Self.isInvestmentAccountClass(Self.intValue(account, "pAccountClass")) else { return nil }
            return NSDecimalNumber(decimal: try self.holdingsValue(account: account, in: ctx)).doubleValue
        }
    }

    /// Get net worth using efficient aggregate queries
    public func getNetWorth() throws -> NetWorthDTO {
        try performRead { [self] ctx in
            let assets = try self.sumByAccountClasses(Array(assetClasses), in: ctx)
            let liabilities = try self.sumByAccountClasses(Array(liabilityClasses), in: ctx)

            let conversion = try self.convertedNetWorth(in: ctx)

            return NetWorthDTO(
                assets: assets,
                liabilities: liabilities,
                netWorth: assets + liabilities,
                formattedAssets: formatCurrency(assets),
                formattedLiabilities: formatCurrency(liabilities),
                formattedNetWorth: formatCurrency(assets + liabilities),
                reportingCurrency: self.reportingCurrency,
                converted: conversion.converted,
                currencyBreakdown: conversion.breakdown,
                warnings: conversion.warnings
            )
        }
    }

    /// Get spending or income by category using aggregate queries
    public func getCategoryAnalysis(
        type: String,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> [CategorySpendingDTO] {
        try performRead { [self] ctx in
            let accountClass = type == "income" ? AccountClass.income : AccountClass.expense

            let accountRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
            accountRequest.predicate = NSPredicate(format: "pAccountClass == %d", accountClass)
            let categoryAccounts = try ctx.fetch(accountRequest)

            var results: [CategorySpendingDTO] = []

            for account in categoryAccounts {
                let categoryName = Self.stringValue(account, "pName")

                // Build predicate for line items in this account with date filtering
                var predicates: [NSPredicate] = [
                    NSPredicate(format: "pAccount == %@", account)
                ]

                if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
                    predicates.append(NSPredicate(
                        format: "pTransaction.pDate >= %@", DateConversion.toDate(ts) as NSDate
                    ))
                }
                if let endDate = endDate, let ts = DateConversion.endOfDayExclusive(endDate) {
                    predicates.append(NSPredicate(
                        format: "pTransaction.pDate < %@", DateConversion.toDate(ts) as NSDate
                    ))
                }

                let compound = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

                let total = try self.sumLineItemAmounts(predicate: compound, in: ctx)
                let txCount = try self.countDistinctTransactions(predicate: compound, in: ctx)

                if txCount > 0 {
                    results.append(CategorySpendingDTO(
                        category: categoryName,
                        total: total,
                        transactionCount: txCount,
                        formattedTotal: formatCurrency(total)
                    ))
                }
            }

            results.sort { $0.total > $1.total }
            return results
        }
    }

    /// List accounts with balances, optionally filtering out categories
    public func listWithBalances(includeHidden: Bool = false, includeCategories: Bool = false) throws -> [AccountDTO] {
        var accountList = try list(includeHidden: includeHidden)
        if !includeCategories {
            accountList = accountList.filter { $0.accountClass < AccountClass.income }
        }
        return try accountList.map { account in
            let balance = try getBalance(accountId: account.id)
            let holdings = try holdingsValue(accountId: account.id)
            return AccountDTO(
                id: account.id,
                name: account.name,
                fullName: account.fullName,
                accountClass: account.accountClass,
                accountType: account.accountType,
                hidden: account.hidden,
                currency: account.currency,
                balance: balance,
                formattedBalance: formatCurrency(balance, currency: account.currency ?? "EUR"),
                holdingsValue: holdings,
                formattedHoldingsValue: holdings.map { formatCurrency($0, currency: account.currency ?? "EUR") }
            )
        }
    }

    /// Get a summary of the vault (account counts by type, category counts, tag count, net worth)
    public func getSummary(tagCount: Int) throws -> SummaryDTO {
        let allAccounts = try list(includeHidden: true)
        let netWorth = try getNetWorth()
        let bankAccounts = allAccounts.filter { $0.accountClass < AccountClass.income }
        let transactionCount = try count(entityName: "Transaction")

        return SummaryDTO(
            accounts: SummaryDTO.AccountSummary(
                total: bankAccounts.count,
                checking: bankAccounts.filter { $0.accountClass == AccountClass.checking }.count,
                savings: bankAccounts.filter { $0.accountClass == AccountClass.savings }.count,
                creditCards: bankAccounts.filter { $0.accountClass == AccountClass.creditCard }.count
            ),
            categories: SummaryDTO.CategorySummary(
                income: allAccounts.filter { $0.accountClass == AccountClass.income }.count,
                expense: allAccounts.filter { $0.accountClass == AccountClass.expense }.count
            ),
            transactions: transactionCount,
            tags: tagCount,
            netWorth: netWorth
        )
    }

    /// Resolve an account from either an ID or a name, preferring ID
    public func resolveAccountId(id: Int?, name: String?) throws -> Int {
        if let id = id {
            guard try get(accountId: id) != nil else {
                throw ToolError.notFound("Account not found: \(id)")
            }
            return id
        }
        if let name = name {
            if let account = try findByName(name) {
                return account.id
            }
            throw ToolError.notFound("Account not found: \(name)")
        }
        throw ToolError.missingParameter("Either account_id or account_name is required")
    }

    // MARK: - Write Operations

    /// Update mutable metadata on an existing bank or investment account:
    /// name, account class, or hidden flag. Categories are refused, both as the
    /// target and as the new class: they belong to `CategoryRepository`.
    /// Stamps `pModificationDate` in the same save, which is the whole upload
    /// signal under this package's sync model.
    public func update(
        accountId: Int,
        name: String? = nil,
        accountClass: Int? = nil,
        hidden: Bool? = nil
    ) throws -> AccountDTO {
        guard name != nil || accountClass != nil || hidden != nil else {
            throw ToolError.invalidInput("At least one field to update must be provided (name, accountClass, or hidden)")
        }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolError.invalidInput("Account name must not be empty")
        }
        if let cls = accountClass, cls >= AccountClass.income {
            throw ToolError.invalidInput("accountClass \(cls) is a category type; use CategoryRepository for income/expense categories")
        }

        try performWrite { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            guard Self.intValue(account, "pAccountClass") < AccountClass.income else {
                throw ToolError.invalidInput("Account \(accountId) is a category; use category tools to modify it")
            }

            if let name {
                account.setValue(name, forKey: "pName")
                account.setValue(name, forKey: "pFullName")
            }
            if let accountClass {
                account.setValue(accountClass as NSNumber, forKey: "pAccountClass")
            }
            if let hidden {
                account.setValue(hidden, forKey: "pHidden")
            }
            Self.setNow(account, "pModificationDate")
        }

        guard let result = try get(accountId: accountId) else {
            throw ToolError.notFound("Account not found after update: \(accountId)")
        }
        return result
    }

    /// Create a new bank account (checking, savings, etc.)
    public func create(
        name: String,
        accountClass: Int = AccountClass.savings,
        currencyCode: String = "EUR",
        hidden: Bool = false
    ) throws -> AccountDTO {
        guard accountClass < AccountClass.income else {
            throw ToolError.invalidInput("Use CategoryRepository to create income/expense categories")
        }

        try performWrite { ctx in
            let account = Self.createObject(entityName: "PrimaryAccount", in: ctx)
            account.setValue(name, forKey: "pName")
            account.setValue(name, forKey: "pFullName")
            account.setValue(accountClass, forKey: "pAccountClass")
            account.setValue(hidden, forKey: "pHidden")
            account.setValue(true, forKey: "pDebit")
            account.setValue(false, forKey: "pTaxable")
            account.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(account, "pCreationTime")
            Self.setNow(account, "pModificationDate")

            let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
            currRequest.predicate = NSPredicate(format: "pCode ==[cd] %@", currencyCode)
            currRequest.fetchLimit = 1
            if let currency = try ctx.fetch(currRequest).first {
                account.setValue(currency, forKey: "currency")
            }
        }

        if let result = try findByName(name) {
            return result
        }
        throw ToolError.notFound("Failed to retrieve created account")
    }

    // MARK: - Aggregate Helpers

    /// Sum account-currency amounts for LineItems matching a predicate
    private func sumLineItemAmounts(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate

        let lineItems = try ctx.fetch(request)
        var total = 0.0
        for lineItem in lineItems {
            let amount = Self.doubleValue(lineItem, "pTransactionAmount")
            total += amount * Self.effectiveExchangeRate(lineItem)
        }
        return total
    }

    /// One account's contribution to net worth, in its own currency.
    struct NetWorthAccountBalance: Sendable {
        let name: String
        let accountClass: Int
        let currency: String?
        let cash: Decimal
        let holdings: Decimal
    }

    struct NetWorthConversion: Sendable {
        let converted: ConvertedNetWorthDTO
        let breakdown: [String: CurrencyBreakdownDTO]
        let warnings: [String]
    }

    private func convertedNetWorth(in ctx: NSManagedObjectContext) throws -> NetWorthConversion {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
        let classes = assetClasses.union(liabilityClasses)
        var balances: [NetWorthAccountBalance] = []
        for account in try ctx.fetch(request) {
            let accountClass = Self.intValue(account, "pAccountClass")
            guard classes.contains(accountClass) else { continue }
            let cash = try sumLineItemAmounts(predicate: NSPredicate(format: "pAccount == %@", account), in: ctx)
            let holdings = Self.isInvestmentAccountClass(accountClass) ? try holdingsValue(account: account, in: ctx) : 0
            balances.append(NetWorthAccountBalance(
                name: Self.stringValue(account, "pName"),
                accountClass: accountClass,
                currency: Self.currencyCode(account),
                cash: Decimal(string: String(cash)) ?? 0,
                holdings: holdings
            ))
        }
        var conversion = Self.convertNetWorth(
            reportingCurrency: reportingCurrency,
            accounts: balances,
            rates: try ExchangeRateRepository.fetchRates(in: ctx)
        )
        if let warning = reportingCurrencyWarning {
            conversion = NetWorthConversion(
                converted: conversion.converted,
                breakdown: conversion.breakdown,
                warnings: [warning] + conversion.warnings
            )
        }
        return conversion
    }

    /// Convert each account's cash and holdings into the reporting currency.
    /// Ported from upstream #20's aggregation, without its change to how an
    /// account's cash is computed. An account with no usable rate is left out
    /// and named in a warning rather than added unconverted.
    static func convertNetWorth(
        reportingCurrency rawReportingCurrency: String,
        accounts: [NetWorthAccountBalance],
        rates: [ExchangeRateRecord],
        now: Date = Date()
    ) -> NetWorthConversion {
        let reportingCurrency = ReportingCurrency.resolve(rawReportingCurrency)
        struct Totals {
            var cash = Decimal(0)
            var holdings = Decimal(0)
            var lookup: ExchangeRateLookupResult
        }

        var byCurrency: [String: Totals] = [:]
        var assets = Decimal(0)
        var liabilities = Decimal(0)
        var holdings = Decimal(0)
        var warnings: [String] = []

        for account in accounts {
            // An account with no currency is read as already in the reporting currency.
            let currency = account.currency?.uppercased() ?? reportingCurrency
            guard let lookup = ExchangeRateRepository.resolve(from: currency, to: reportingCurrency, rates: rates) else {
                if account.cash != 0 || account.holdings != 0 {
                    warnings.append("Account \(account.name) (\(currency)) left out: no \(currency)->\(reportingCurrency) exchange rate in the vault")
                }
                continue
            }
            var totals = byCurrency[currency] ?? Totals(lookup: lookup)
            totals.cash += account.cash
            totals.holdings += account.holdings
            byCurrency[currency] = totals

            let convertedCash = account.cash * lookup.rate
            if assetClasses.contains(account.accountClass) {
                assets += convertedCash
            } else {
                liabilities += convertedCash
            }
            holdings += account.holdings * lookup.rate
        }

        var breakdown: [String: CurrencyBreakdownDTO] = [:]
        for (currency, totals) in byCurrency {
            let rateDate = totals.lookup.effectiveDate.map { DateConversion.toISO(DateConversion.fromDate($0)) }
            breakdown[currency] = CurrencyBreakdownDTO(
                cash: double(totals.cash),
                holdingsValue: double(totals.holdings),
                rate: double(totals.lookup.rate),
                rateDate: rateDate,
                convertedCash: double(totals.cash * totals.lookup.rate),
                convertedHoldingsValue: double(totals.holdings * totals.lookup.rate),
                hops: totals.lookup.hops,
                path: totals.lookup.path
            )
            if totals.lookup.hops > 0, let effective = totals.lookup.effectiveDate,
               let age = Calendar(identifier: .gregorian).dateComponents([.day], from: effective, to: now).day,
               age > 7 {
                warnings.append("Exchange rate \(totals.lookup.path.joined(separator: "->")) is \(age) days old (\(rateDate ?? "undated"))")
            }
        }

        return NetWorthConversion(
            converted: ConvertedNetWorthDTO(
                currency: reportingCurrency,
                assets: double(assets),
                liabilities: double(liabilities),
                holdingsValue: double(holdings)
            ),
            breakdown: breakdown,
            warnings: warnings.sorted()
        )
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    static func isInvestmentAccountClass(_ accountClass: Int) -> Bool {
        (AccountClass.investment...AccountClass.hsaInvestment).contains(accountClass)
    }

    /// Holdings market value for one account, in the account's currency.
    /// Ported from upstream #19's `holdingsValue` (also proposed in #33).
    private func holdingsValue(account: NSManagedObject, in ctx: NSManagedObjectContext) throws -> Decimal {
        struct Position {
            var shares = Decimal(0)
            var multiplier = Decimal(1)
            var multiplierDate = -Double.greatestFiniteMagnitude
            var security: NSManagedObject?
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        request.predicate = NSPredicate(format: "pLineItem.pAccount == %@ AND pShares != nil", account)

        var positions: [Int: Position] = [:]
        for sli in try ctx.fetch(request) {
            guard let security = Self.relatedObject(sli, "pSecurity") else { continue }
            let key = Self.extractPK(from: security.objectID)
            var position = positions[key] ?? Position()
            position.shares += Self.decimalValue(sli, "pShares")
            position.security = security

            // The multiplier of the most recent trade wins.
            let date = Self.relatedObject(sli, "pLineItem")
                .flatMap { Self.relatedObject($0, "pTransaction") }
                .flatMap { Self.dateValue($0, "pDate") } ?? -Double.greatestFiniteMagnitude
            if date >= position.multiplierDate {
                position.multiplierDate = date
                let multiplier = Self.decimalValue(sli, "pPriceMultiplier")
                position.multiplier = multiplier == 0 ? 1 : multiplier
            }
            positions[key] = position
        }

        var total = Decimal(0)
        for position in positions.values {
            guard position.shares != 0, let security = position.security,
                  let close = try latestClosePrice(for: security, in: ctx) else { continue }
            total += position.shares * close * position.multiplier
        }
        return total
    }

    private func latestClosePrice(for security: NSManagedObject, in ctx: NSManagedObjectContext) throws -> Decimal? {
        let priceItemRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        priceItemRequest.predicate = NSPredicate(format: "pSecurityID == %@", Self.stringValue(security, "pUniqueID"))
        priceItemRequest.fetchLimit = 1
        guard let priceItem = try ctx.fetch(priceItemRequest).first else { return nil }

        let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
        priceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
        priceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        priceRequest.fetchLimit = 1
        guard let price = try ctx.fetch(priceRequest).first else { return nil }
        return Self.decimalValue(price, "pClosePrice")
    }

    /// Count line items matching a predicate (used as a proxy for transaction count)
    private func countDistinctTransactions(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        return try ctx.count(for: request)
    }

    /// Sum line item amounts for accounts with the given account classes
    private func sumByAccountClasses(_ classes: [Int], in ctx: NSManagedObjectContext) throws -> Double {
        let predicates = classes.map { cls in
            NSPredicate(format: "pAccount.pAccountClass == %d", cls)
        }
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        return try sumLineItemAmounts(predicate: compound, in: ctx)
    }

    // MARK: - DTO Mapping

    public func mapToDTO(_ object: NSManagedObject) -> AccountDTO {
        let accountClass = Self.intValue(object, "pAccountClass")
        let pk = Self.extractPK(from: object.objectID)

        return AccountDTO(
            id: pk,
            name: Self.stringValue(object, "pName"),
            fullName: Self.stringValue(object, "pFullName"),
            accountClass: accountClass,
            accountType: accountTypeName(for: accountClass),
            hidden: Self.boolValue(object, "pHidden"),
            currency: Self.currencyCode(object),
            balance: nil,
            formattedBalance: nil
        )
    }
}
