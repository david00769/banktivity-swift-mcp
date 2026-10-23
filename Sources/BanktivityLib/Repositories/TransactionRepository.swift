// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for transaction operations using Core Data
public final class TransactionRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository

    public init(container: NSPersistentContainer, lineItemRepo: LineItemRepository) {
        self.lineItemRepo = lineItemRepo
        super.init(container: container)
    }

    /// List transactions with optional filtering
    public func list(
        accountId: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> [TransactionDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")

            var predicates: [NSPredicate] = []

            if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
                predicates.append(NSPredicate(
                    format: "pDate >= %@", DateConversion.toDate(ts) as NSDate
                ))
            }

            if let endDate = endDate, let ts = DateConversion.endOfDayExclusive(endDate) {
                predicates.append(NSPredicate(
                    format: "pDate < %@", DateConversion.toDate(ts) as NSDate
                ))
            }

            if let accountId = accountId {
                // Filter transactions that have at least one line item in this account
                guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(accountId)")
                }
                predicates.append(NSPredicate(
                    format: "ANY lineItems.pAccount == %@", account
                ))
            }

            if !predicates.isEmpty {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }

            request.sortDescriptors = [
                NSSortDescriptor(key: "pDate", ascending: false)
            ]

            if let limit = limit {
                request.fetchLimit = limit
            }

            if let offset = offset {
                request.fetchOffset = offset
            }

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Search transactions by title or note (case-insensitive LIKE)
    public func search(query: String, limit: Int = 50) throws -> [TransactionDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            let pattern = "*\(query)*"
            request.predicate = NSPredicate(
                format: "pTitle LIKE[cd] %@ OR pNote LIKE[cd] %@", pattern, pattern
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "pDate", ascending: false)
            ]
            request.fetchLimit = limit

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Get a single transaction by primary key
    public func get(transactionId: Int) throws -> TransactionDTO? {
        try performRead { [self] ctx in
            guard let object = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                return nil
            }
            return self.mapToDTO(object)
        }
    }

    private func get(uniqueID: String) throws -> TransactionDTO? {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            request.predicate = NSPredicate(format: "pUniqueID == %@", uniqueID)
            request.fetchLimit = 1
            return try ctx.fetch(request).first.map { self.mapToDTO($0) }
        }
    }

    /// Get total transaction count
    public func count() throws -> Int {
        try count(entityName: "Transaction")
    }

    // MARK: - Write Operations

    /// Create a new transaction with line items
    public func create(
        date: String,
        title: String,
        note: String? = nil,
        lineItems: [(accountId: Int, amount: Double, memo: String?)],
        transactionType: String? = nil
    ) throws -> TransactionDTO {
        // Create the transaction and line items in a background context.
        // `pCreationTime` and `pModificationDate` = now are the whole upload
        // signal: Banktivity inserts its own SyncedHostedEntity when it
        // uploads the new row.
        let txUUID: String = try performWriteReturning { [self] ctx in
            let tx = Self.createObject(entityName: "Transaction", in: ctx)
            let txUUID = Self.generateUUID()
            tx.setValue(title, forKey: "pTitle")
            tx.setValue(note, forKey: "pNote")
            tx.setValue(txUUID, forKey: "pUniqueID")
            tx.setValue(false, forKey: "pCleared")
            tx.setValue(false, forKey: "pVoid")
            tx.setValue(false, forKey: "pAdjustment")
            Self.setNow(tx, "pCreationTime")
            Self.setNow(tx, "pModificationDate")
            Self.setDate(tx, "pDate", isoString: date)

            // Create line items
            var currencySet = false

            var totalAmount = 0.0
            var bankNet = 0.0
            var bankAccountIds = Set<Int>()

            for liInput in lineItems {
                guard let account = try fetchByPK(entityName: "Account", pk: liInput.accountId, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(liInput.accountId)")
                }

                let accountClass = Self.intValue(account, "pAccountClass")
                if assetClasses.contains(accountClass) || liabilityClasses.contains(accountClass) {
                    bankNet += liInput.amount
                    bankAccountIds.insert(liInput.accountId)
                }

                // Use the first account's currency for the transaction
                if !currencySet, let currency = Self.relatedObject(account, "currency") {
                    tx.setValue(currency, forKey: "pCurrency")
                    currencySet = true
                }

                let li = Self.createObject(entityName: "LineItem", in: ctx)
                li.setValue(liInput.amount as NSNumber, forKey: "pTransactionAmount")
                li.setValue(liInput.memo, forKey: "pMemo")
                li.setValue(Self.generateUUID(), forKey: "pUniqueID")
                li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
                li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
                li.setValue(false, forKey: "pCleared")
                Self.setNow(li, "pCreationTime")
                li.setValue(account, forKey: "pAccount")
                li.setValue(tx, forKey: "pTransaction")

                totalAmount += liInput.amount
            }

            // Create balancing offset line item if the explicit line items don't sum to zero.
            // Banktivity requires every transaction to have a balancing offset — without it,
            // the transaction won't affect the account's running cash balance.
            if abs(totalAmount) > 0.001 {
                let offsetLi = Self.createObject(entityName: "LineItem", in: ctx)
                offsetLi.setValue(-totalAmount as NSNumber, forKey: "pTransactionAmount")
                offsetLi.setValue(Self.generateUUID(), forKey: "pUniqueID")
                offsetLi.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
                offsetLi.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
                offsetLi.setValue(false, forKey: "pCleared")
                Self.setNow(offsetLi, "pCreationTime")
                // No pAccount — this is an uncategorized offset
                offsetLi.setValue(tx, forKey: "pTransaction")
            }

            // An explicit type must exist; an omitted one is inferred from the bank
            // legs. This used to take whichever TransactionType row Core Data
            // returned first, which on a real vault is often Return Of Capital.
            let resolvedType: NSManagedObject?
            if let transactionType {
                // An unknown slug gets requireTransactionType's own error below.
                guard Self.transactionTypeBaseTypeCode(transactionType) == nil
                    || Self.cashTransactionTypeNames.contains(transactionType.lowercased()) else {
                    throw ToolError.invalidInput("transactions create takes a cash type (\(Self.cashTransactionTypeList)), not \(transactionType). Investment rows need a security leg: use securities create-trade or create-income.")
                }
                resolvedType = try Self.requireTransactionType(named: transactionType, in: ctx)
            } else {
                let inferred = Self.inferredTransactionTypeName(
                    bankNet: bankNet, distinctBankAccountCount: bankAccountIds.count
                )
                resolvedType = try Self.fetchTransactionType(named: inferred, in: ctx)
                    ?? Self.fetchTransactionType(named: "deposit", in: ctx)
                    ?? Self.fetchAnyTransactionType(in: ctx)
            }
            if let resolvedType {
                tx.setValue(resolvedType, forKey: "pTransactionType")
            }

            return txUUID
        }

        // Recalculate running balances for all affected accounts
        let affectedAccountIds = Set(lineItems.map(\.accountId))
        for accountId in affectedAccountIds {
            try lineItemRepo.recalculateRunningBalances(accountId: accountId)
        }

        guard let created = try get(uniqueID: txUUID) else {
            throw ToolError.notFound("Failed to retrieve created transaction")
        }
        return created
    }

    /// Update an existing transaction
    public func update(transactionId: Int, title: String? = nil, note: String? = nil, date: String? = nil, cleared: Bool? = nil, transactionType: String? = nil) throws -> TransactionDTO? {
        let dateChanged: Bool = try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }

            var dateChanged = false

            if let title = title { tx.setValue(title, forKey: "pTitle") }
            if let note = note { tx.setValue(note, forKey: "pNote") }
            if let date = date {
                Self.setDate(tx, "pDate", isoString: date)
                dateChanged = true
            }
            if let cleared = cleared { tx.setValue(cleared, forKey: "pCleared") }
            if let transactionType = transactionType {
                tx.setValue(try Self.requireTransactionType(named: transactionType, in: ctx), forKey: "pTransactionType")
            }
            Self.setNow(tx, "pModificationDate")

            return dateChanged
        }

        // If date changed, recalculate running balances for affected accounts
        if dateChanged {
            if let lineItems = try? lineItemRepo.getForTransactionPK(transactionId) {
                let accountIds = Set(lineItems.map(\.accountId))
                for accountId in accountIds {
                    try lineItemRepo.recalculateRunningBalances(accountId: accountId)
                }
            }
        }


        return try get(transactionId: transactionId)
    }

    public func repairForexTransfer(
        transactionId: Int,
        sourceAccountId: Int,
        targetAccountId: Int,
        feeCategoryId: Int,
        grossSourceAmount: Double,
        sourceFeeAmount: Double,
        targetAmount: Double,
        exchangeRate: Double,
        title: String? = nil,
        note: String? = nil,
        date: String? = nil,
        sourceMemo: String? = nil,
        targetMemo: String? = nil,
        feeMemo: String? = nil
    ) throws -> TransactionDTO? {
        guard grossSourceAmount > 0 else {
            throw ToolError.invalidInput("grossSourceAmount must be positive")
        }
        guard sourceFeeAmount >= 0 && sourceFeeAmount < grossSourceAmount else {
            throw ToolError.invalidInput("sourceFeeAmount must be non-negative and less than grossSourceAmount")
        }
        guard targetAmount > 0 && exchangeRate > 0 else {
            throw ToolError.invalidInput("targetAmount and exchangeRate must be positive")
        }

        let sourceAfterFee = grossSourceAmount - sourceFeeAmount
        let computedTarget = sourceAfterFee * exchangeRate
        guard abs(computedTarget - targetAmount) <= 0.02 else {
            throw ToolError.invalidInput(
                "targetAmount does not match source-after-fee times exchangeRate: \(computedTarget) vs \(targetAmount)"
            )
        }

        let affectedAccountIds = try performWriteReturning { [self] ctx -> [Int] in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            guard let sourceAccount = try fetchByPK(entityName: "Account", pk: sourceAccountId, in: ctx) else {
                throw ToolError.notFound("Source account not found: \(sourceAccountId)")
            }
            guard let targetAccount = try fetchByPK(entityName: "Account", pk: targetAccountId, in: ctx) else {
                throw ToolError.notFound("Target account not found: \(targetAccountId)")
            }
            guard let feeCategory = try fetchByPK(entityName: "Account", pk: feeCategoryId, in: ctx) else {
                throw ToolError.notFound("Fee category not found: \(feeCategoryId)")
            }


            if let title = title { tx.setValue(title, forKey: "pTitle") }
            if let note = note { tx.setValue(note, forKey: "pNote") }
            if let date = date { Self.setDate(tx, "pDate", isoString: date) }
            if let currency = Self.relatedObject(sourceAccount, "currency") {
                tx.setValue(currency, forKey: "pCurrency")
            }

            if let transferType = try Self.fetchTransactionType(named: "transfer", in: ctx) {
                tx.setValue(transferType, forKey: "pTransactionType")
            }
            Self.setNow(tx, "pModificationDate")

            let existing = Self.relatedSet(tx, "lineItems")
            func lineItem(accountId: Int) -> NSManagedObject? {
                existing.first { li in
                    guard let account = Self.relatedObject(li, "pAccount") else { return false }
                    return Self.extractPK(from: account.objectID) == accountId
                }
            }

            let sourceLine = lineItem(accountId: sourceAccountId) ?? Self.createObject(entityName: "LineItem", in: ctx)
            let targetLine = lineItem(accountId: targetAccountId) ?? Self.createObject(entityName: "LineItem", in: ctx)
            let feeLine = lineItem(accountId: feeCategoryId) ?? Self.createObject(entityName: "LineItem", in: ctx)
            let managedLines = Set([sourceLine, targetLine, feeLine])

            let extras = existing.filter { !managedLines.contains($0) }
            guard extras.isEmpty else {
                let ids = extras.map { Self.extractPK(from: $0.objectID) }.sorted()
                throw ToolError.invalidInput("Transaction has unmanaged extra line items: \(ids)")
            }

            func ensureUUID(_ line: NSManagedObject) {
                guard Self.stringValue(line, "pUniqueID").isEmpty else { return }
                line.setValue(Self.generateUUID(), forKey: "pUniqueID")
                Self.setNow(line, "pCreationTime")
            }

            func configure(
                _ line: NSManagedObject,
                account: NSManagedObject,
                amount: Double,
                rate: Double,
                memo: String?,
                sortIndex: Int16,
                defaultCleared: Bool
            ) {
                ensureUUID(line)
                line.setValue(account, forKey: "pAccount")
                line.setValue(tx, forKey: "pTransaction")
                line.setValue(amount as NSNumber, forKey: "pTransactionAmount")
                line.setValue(rate as NSNumber, forKey: "pExchangeRate")
                line.setValue(memo, forKey: "pMemo")
                line.setValue(sortIndex, forKey: "pIntraDaySortIndex")
                if line.value(forKey: "pCleared") == nil {
                    line.setValue(defaultCleared, forKey: "pCleared")
                }
            }

            configure(
                sourceLine, account: sourceAccount, amount: -grossSourceAmount,
                rate: 1.0, memo: sourceMemo, sortIndex: 0, defaultCleared: false
            )
            configure(
                targetLine, account: targetAccount, amount: sourceAfterFee,
                rate: exchangeRate, memo: targetMemo, sortIndex: 1, defaultCleared: false
            )
            configure(
                feeLine, account: feeCategory, amount: sourceFeeAmount,
                rate: 1.0, memo: feeMemo, sortIndex: 2, defaultCleared: false
            )

            return [sourceAccountId, targetAccountId, feeCategoryId]
        }

        for accountId in affectedAccountIds {
            try lineItemRepo.recalculateRunningBalances(accountId: accountId)
        }

        context.refreshAllObjects()
        return try get(transactionId: transactionId)
    }

    /// Delete a transaction and its line items
    public func delete(transactionId: Int) throws -> Bool {
        let lineItems = try lineItemRepo.getForTransactionPK(transactionId)
        let affectedAccountIds = Set(lineItems.map(\.accountId))

        let deleted = try performWriteReturning { [self] ctx -> Bool in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                return false
            }

            // Delete all line items first (Core Data may not cascade automatically for unowned models)
            let txLineItems = Self.relatedSet(tx, "lineItems")
            for li in txLineItems {
                ctx.delete(li)
            }

            // Banktivity's pending-delete mark, in the same save as the delete.
            try SyncRecords.markDeletedIfPresent(
                entityUUID: Self.stringValue(tx, "pUniqueID"), in: ctx
            )
            ctx.delete(tx)
            return true
        }

        // Recalculate running balances for affected accounts
        if deleted {
            for accountId in affectedAccountIds {
                try lineItemRepo.recalculateRunningBalances(accountId: accountId)
            }
        }

        return deleted
    }

    // MARK: - DTO Mapping

    public func mapToDTO(_ object: NSManagedObject) -> TransactionDTO {
        let pk = Self.extractPK(from: object.objectID)

        var transactionTypeName: String? = nil
        if let txType = Self.relatedObject(object, "pTransactionType") {
            transactionTypeName = Self.string(txType, "pName")
        }

        let dateStr: String
        if let dateVal = Self.dateValue(object, "pDate") {
            dateStr = DateConversion.toISO(dateVal)
        } else {
            dateStr = "unknown"
        }

        let lineItems = lineItemRepo.getForTransaction(object)

        return TransactionDTO(
            id: pk,
            date: dateStr,
            title: Self.stringValue(object, "pTitle"),
            note: Self.string(object, "pNote"),
            cleared: Self.boolValue(object, "pCleared"),
            voided: Self.boolValue(object, "pVoid"),
            transactionType: transactionTypeName,
            lineItems: lineItems
        )
    }

    // MARK: - Transaction Type Mapping

    /// The types `create` accepts by name. A plain transaction has no security
    /// leg, so an investment type on it is a row Banktivity cannot render
    /// consistently; those rows come from `securities create-trade` and
    /// `create-income`.
    public static let cashTransactionTypeNames = ["check", "deposit", "transfer", "withdrawal"]
    public static var cashTransactionTypeList: String { cashTransactionTypeNames.joined(separator: ", ") }

    /// Infer deposit / withdrawal / transfer from asset/liability line items.
    /// Income and expense category lines are ignored. Transfer is inferred whenever
    /// two or more distinct bank accounts are involved (including fee and FX
    /// transfers that do not net to zero). Deposit and withdrawal are used only
    /// when a single distinct bank account is present. Investment types are never
    /// inferred; a caller that means one must name it.
    static func inferredTransactionTypeName(bankNet: Double, distinctBankAccountCount: Int) -> String {
        if distinctBankAccountCount >= 2 {
            return "transfer"
        }
        if bankNet < -0.001 {
            return "withdrawal"
        }
        return "deposit"
    }

    /// The vault's TransactionType row for a slug, refusing an unknown slug or a
    /// vault that lacks the row.
    static func requireTransactionType(named name: String, in ctx: NSManagedObjectContext) throws -> NSManagedObject {
        guard let baseType = transactionTypeBaseTypeCode(name) else {
            throw ToolError.invalidInput("Unknown transaction type: \(name). Valid types: \(transactionTypeNames)")
        }
        guard let txType = try fetchTransactionType(named: name, in: ctx) else {
            throw ToolError.notFound("TransactionType entity not found for base type \(baseType)")
        }
        return txType
    }

    static func fetchTransactionType(named name: String, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        guard let baseType = transactionTypeBaseTypeCode(name) else { return nil }
        let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
        typeRequest.predicate = NSPredicate(format: "pBaseType == %d", baseType)
        typeRequest.fetchLimit = 1
        return try ctx.fetch(typeRequest).first
    }

    /// Last-resort lookup when neither the inferred type nor Deposit exists.
    /// Sorted by `pBaseType` so Deposit (1) wins over later types such as
    /// Return Of Capital (310) instead of picking an arbitrary first row.
    static func fetchAnyTransactionType(in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
        typeRequest.sortDescriptors = [NSSortDescriptor(key: "pBaseType", ascending: true)]
        typeRequest.fetchLimit = 1
        return try ctx.fetch(typeRequest).first
    }

    /// Slug -> Core Data base type, and the ONLY statement of what
    /// `--transaction-type` accepts.
    ///
    /// This was a `switch` with the accepted set restated by hand in the
    /// caller's error message, and the two had drifted badly in both
    /// directions: the message omitted `split-shares`, `transfer-shares`,
    /// `dividend` and `transfer`, all of which worked, while advertising
    /// `short-sell` and `buy-to-cover`, which were never accepted at all.
    ///
    /// The cost of a wrong error message is not a typo. Downstream, an agent
    /// read the advertised list, concluded that retyping ~51 corporate-action
    /// rows was impossible without changing this repository, and planned around
    /// a limitation that did not exist. A capability nobody can discover is
    /// indistinguishable from one that is missing.
    public static let transactionTypeBaseTypes: [String: Int] = [
        "deposit": 1,
        "withdrawal": 2,
        "transfer": 3,
        "check": 4,
        "buy": 100,
        "sell": 101,
        "buy-to-open": 102,
        "buy-to-close": 103,
        "sell-to-open": 104,
        "sell-to-close": 105,
        "move-shares-in": 210,
        "move-shares-out": 211,
        "transfer-shares": 212,
        "split-shares": 250,
        "investment-income": 300,
        "dividend": 301,
        "capital-gains-short": 302,
        "capital-gains-long": 303,
        "interest": 304,
        // `transactionTypeBaseTypeName` renders 302, 303 and 304 as
        // `cap-gains-short`, `cap-gains-long` and `interest-income`, while
        // `SecurityRepository.incomeBaseTypes` spells them out in full. A value
        // read back from one therefore could not be written through the other:
        // read-then-write, the most ordinary thing a caller does, was refused.
        // Both spellings are accepted rather than picking a winner, because
        // changing what a read RETURNS would break consumers that store it.
        "cap-gains-short": 302,
        "cap-gains-long": 303,
        "interest-income": 304,
        // A spin-off apportions basis by releasing it through Return of
        // Capital and spending it on the child. Without this the second leg
        // cannot be written at all, so the apportionment cannot be recorded.
        "return-of-capital": 310,
    ]

    /// The accepted slugs, sorted, for error messages. Derived rather than
    /// restated so it cannot drift from what is actually accepted.
    public static var transactionTypeNames: String {
        transactionTypeBaseTypes.keys.sorted().joined(separator: ", ")
    }

    static func transactionTypeBaseTypeCode(_ name: String) -> Int? {
        transactionTypeBaseTypes[name.lowercased()]
    }

    static func transactionTypeBaseTypeName(_ code: Int) -> String {
        switch code {
        case 1: return "deposit"
        case 2: return "withdrawal"
        case 3: return "transfer"
        case 4: return "check"
        case 100: return "buy"
        case 101: return "sell"
        case 102: return "buy-to-open"
        case 103: return "buy-to-close"
        case 104: return "sell-to-open"
        case 105: return "sell-to-close"
        case 210: return "move-shares-in"
        case 211: return "move-shares-out"
        case 212: return "transfer-shares"
        case 250: return "split-shares"
        case 300: return "investment-income"
        case 301: return "dividend"
        case 302: return "cap-gains-short"
        case 303: return "cap-gains-long"
        case 304: return "interest-income"
        case 310: return "return-of-capital"
        default: return "deposit"
        }
    }
}
