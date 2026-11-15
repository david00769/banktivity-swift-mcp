// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import CryptoKit
import Foundation

public final class StatementRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository

    public init(container: NSPersistentContainer, lineItemRepo: LineItemRepository) {
        self.lineItemRepo = lineItemRepo
        super.init(container: container)
    }

    // MARK: - Read Operations

    public func list(accountId: Int, includeInternal: Bool = false) throws -> [StatementSummaryDTO] {
        if includeInternal {
            return try listWithInternalDiagnostics(accountId: accountId).statements
        }
        return try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pStartDate", ascending: true),
                NSSortDescriptor(key: "pEndDate", ascending: true),
                NSSortDescriptor(key: "pUniqueID", ascending: true),
            ]

            let statements = try ctx.fetch(request)
            return statements
                .map { self.mapToSummaryDTO($0) }
        }
    }

    /// Includes every addressable statement in the requested account and an
    /// explicit record for every line-item statement reference that cannot be
    /// represented there.  This must remain read-only: it is evidence for
    /// planning, never a backdoor to an internal mutation.
    public func listWithInternalDiagnostics(accountId: Int) throws -> StatementInternalListingDTO {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pStartDate", ascending: true),
                NSSortDescriptor(key: "pEndDate", ascending: true),
                NSSortDescriptor(key: "pUniqueID", ascending: true),
            ]
            let statements = try ctx.fetch(request)
            let listedIDs = Set(statements.map { Self.extractPK(from: $0.objectID) })
            let lineRequest = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            lineRequest.predicate = NSPredicate(format: "pAccount == %@ AND pStatement != nil", account)
            let unaddressable = try ctx.fetch(lineRequest).compactMap { line -> StatementUnaddressableReferenceDTO? in
                guard let referenced = Self.relatedObject(line, "pStatement") else { return nil }
                let referencedID = Self.extractPK(from: referenced.objectID)
                guard let referencedAccount = Self.relatedObject(referenced, "pAccount"),
                      referencedAccount.objectID == account.objectID,
                      listedIDs.contains(referencedID) else {
                    return StatementUnaddressableReferenceDTO(
                        lineItemId: Self.extractPK(from: line.objectID),
                        referencedStatementId: referencedID,
                        requestedAccountId: accountId,
                        reason: "referenced_statement_is_not_addressable_in_requested_account"
                    )
                }
                return nil
            }.sorted { lhs, rhs in
                lhs.lineItemId == rhs.lineItemId
                    ? lhs.referencedStatementId < rhs.referencedStatementId
                    : lhs.lineItemId < rhs.lineItemId
            }
            return StatementInternalListingDTO(
                statements: statements.map { self.mapToSummaryDTO($0) },
                unaddressableReferences: unaddressable
            )
        }
    }

    public func warningsForStatementReads(accountId: Int) throws -> [String] {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            return Self.statementReadWarnings(accountClass: Self.intValue(account, "pAccountClass"))
        }
    }

    public func get(statementId: Int) throws -> StatementDTO? {
        try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                return nil
            }
            return self.mapToDTO(statement)
        }
    }

    /// Inspect a statement reference from the line-item side.  This is the
    /// authoritative diagnostic for hidden investment rows: callers get an
    /// explicit unaddressable record instead of silently losing the reference
    /// in a visible-only statement list.
    public func inspectMembership(lineItemId: Int) throws -> StatementMembershipInspectionDTO {
        try performRead { [self] ctx in
            guard let lineItem = try fetchByPK(entityName: "LineItem", pk: lineItemId, in: ctx) else {
                throw ToolError.notFound("Line item not found: \(lineItemId)")
            }
            guard let statement = Self.relatedObject(lineItem, "pStatement") else {
                return StatementMembershipInspectionDTO(
                    lineItemId: lineItemId, referencedStatementId: nil, stableIdentity: nil,
                    accountId: nil, accountName: nil, startDate: nil, endDate: nil,
                    beginningBalance: nil, endingBalance: nil, membershipLineItemIds: [], membershipCount: 0,
                    visibilityClassification: "unaddressable_reference", positionAnchors: [:],
                    statementPreimage: nil, lineItemMemberships: [], preimageSha256: nil,
                    membershipPreimageSha256: nil,
                    capabilityFlags: ["addressable": false, "reconcilable": false, "restorable": false]
                )
            }
            guard let account = Self.relatedObject(statement, "pAccount") else {
                return StatementMembershipInspectionDTO(
                    lineItemId: lineItemId, referencedStatementId: Self.extractPK(from: statement.objectID),
                    stableIdentity: Self.stringValue(statement, "pUniqueID"), accountId: nil, accountName: nil,
                    startDate: nil, endDate: nil, beginningBalance: nil, endingBalance: nil,
                    membershipLineItemIds: [], membershipCount: 0,
                    visibilityClassification: "unaddressable_reference", positionAnchors: [:],
                    statementPreimage: nil, lineItemMemberships: [], preimageSha256: nil,
                    membershipPreimageSha256: nil,
                    capabilityFlags: ["addressable": false, "reconcilable": false, "restorable": false]
                )
            }
            let statementId = Self.extractPK(from: statement.objectID)
            let accountId = Self.extractPK(from: account.objectID)
            let statementDTO = try self.preimageDTO(statement, in: ctx)
            let memberships = Self.relatedSet(statement, "pLineItems")
                .map {
                    StatementLineItemMembershipPreimageDTO(
                        lineItemId: Self.extractPK(from: $0.objectID), statementId: statementId,
                        cleared: $0.value(forKey: "pCleared") as? Bool ?? false
                    )
                }
                .sorted { $0.lineItemId < $1.lineItemId }
            let membershipIds = memberships.map(\.lineItemId)
            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pStartDate", ascending: true),
                NSSortDescriptor(key: "pEndDate", ascending: true),
                NSSortDescriptor(key: "pUniqueID", ascending: true),
            ]
            let ordered = try ctx.fetch(request)
            guard let index = ordered.firstIndex(where: { Self.extractPK(from: $0.objectID) == statementId }) else {
                throw ToolError.invalidInput("Statement \(statementId) is not addressable in its account chain")
            }
            let before = index > 0 ? Self.extractPK(from: ordered[index - 1].objectID) : nil
            let after = index + 1 < ordered.count ? Self.extractPK(from: ordered[index + 1].objectID) : nil
            let classification = Self.statementRowClassification(statement)
            let hasRestorablePreimage = !Self.stringValue(statement, "pUniqueID").isEmpty
                && !statementDTO.startDate.isEmpty && !statementDTO.endDate.isEmpty
            return StatementMembershipInspectionDTO(
                lineItemId: lineItemId, referencedStatementId: statementId,
                stableIdentity: Self.stringValue(statement, "pUniqueID"), accountId: accountId,
                accountName: Self.stringValue(account, "pName"), startDate: statementDTO.startDate,
                endDate: statementDTO.endDate, beginningBalance: statementDTO.beginningBalance,
                endingBalance: statementDTO.endingBalance, membershipLineItemIds: membershipIds,
                membershipCount: membershipIds.count, visibilityClassification: classification.kind,
                positionAnchors: ["statement_index": index, "before_statement_id": before, "after_statement_id": after],
                statementPreimage: statementDTO, lineItemMemberships: memberships,
                preimageSha256: Self.statementPreimageHash(statementDTO),
                membershipPreimageSha256: Self.membershipPreimageHash(memberships),
                capabilityFlags: [
                    "addressable": true,
                    // This means reconcilable by a typed, inspected route; it
                    // does not grant the generic visible-row reconcile command
                    // authority over an internal row.
                    "reconcilable": true,
                    "restorable": Self.isInvestmentStatement(statement) && hasRestorablePreimage,
                ]
            )
        }
    }

    public func visibleRowCorrectionPlan(statementId: Int? = nil, uiStart: Double, uiEnd: Double, uiMissing: Double, correctedStart: Double? = nil) -> VisibleRowCorrectionPlanDTO {
        VisibleRowCorrectionPlanDTO(
            statementId: statementId,
            uiStart: uiStart,
            uiEnd: uiEnd,
            uiMissing: uiMissing,
            correctedStart: correctedStart
        )
    }

    public func getAccountReconciliationStatus(accountId: Int) throws -> AccountReconciliationStatusDTO {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pEndDate", ascending: false),
                NSSortDescriptor(key: "pStartDate", ascending: false),
            ]

            let statements = try ctx.fetch(request)
            let lastStatement = statements.first
            let lastStatementId = lastStatement.map { Self.extractPK(from: $0.objectID) }
            let lastEndDate: String?
            if let lastStatement, let ts = Self.dateValue(lastStatement, "pEndDate") {
                lastEndDate = DateConversion.toISO(ts)
            } else {
                lastEndDate = nil
            }

            return AccountReconciliationStatusDTO(
                accountId: accountId,
                hasReconciledStatements: !statements.isEmpty,
                statementCount: statements.count,
                lastStatementId: lastStatementId,
                lastReconciledStatementEndDate: lastEndDate
            )
        }
    }

    /// Where an account's reconciliation stands: its statements, which of them
    /// don't add up, and how many line items are not on any statement.
    public func status(accountId: Int) throws -> AccountReconciliationStatusDTO {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [NSSortDescriptor(key: "pEndDate", ascending: true)]
            let statements = try ctx.fetch(request)
            let summaries = statements.map { self.mapToSummaryDTO($0) }
            let last = statements.last

            let unreconciled = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            unreconciled.predicate = NSPredicate(format: "pAccount == %@ AND pStatement == nil", account)
            let unreconciledCount = try ctx.count(for: unreconciled)
            var sinceLast = unreconciledCount
            if let lastEnd = last.flatMap({ Self.dateValue($0, "pEndDate") }) {
                unreconciled.predicate = NSPredicate(
                    format: "pAccount == %@ AND pStatement == nil AND pTransaction.pDate > %@",
                    account, DateConversion.toDate(lastEnd) as NSDate)
                sinceLast = try ctx.count(for: unreconciled)
            }

            return AccountReconciliationStatusDTO(
                accountId: accountId,
                accountName: Self.stringValue(account, "pName"),
                statementCount: statements.count,
                unbalancedStatementIds: summaries.filter { !$0.isBalanced }.map(\.id),
                lastStatementId: last.map { Self.extractPK(from: $0.objectID) },
                lastStatementEndDate: last.flatMap { Self.dateValue($0, "pEndDate") }.map { DateConversion.toISO($0) },
                lastStatementEndingBalance: last.map { Self.doubleValue($0, "pEndingBalance") },
                unreconciledLineItemCount: unreconciledCount,
                unreconciledSinceLastStatement: sinceLast
            )
        }
    }

    // MARK: - Write Operations

    public func create(
        accountId: Int,
        startDate: String,
        endDate: String,
        beginningBalance: Double,
        endingBalance: Double,
        name: String? = nil,
        note: String? = nil
    ) throws -> StatementDTO {
        guard let startTs = DateConversion.fromISO(startDate, timeZone: DateConversion.dateOnlyTimeZone) else {
            throw ToolError.invalidInput("Invalid start date: \(startDate)")
        }
        guard let endTs = DateConversion.fromISO(endDate, timeZone: DateConversion.dateOnlyTimeZone) else {
            throw ToolError.invalidInput("Invalid end date: \(endDate)")
        }
        guard endTs > startTs else {
            throw ToolError.invalidInput("End date must be after start date")
        }

        let pk: Int = try performWriteReturning { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            try validateNoOverlap(accountId: accountId, startTs: startTs, endTs: endTs, in: ctx)
            try validateBeginningBalance(accountId: accountId, startTs: startTs, beginningBalance: beginningBalance, in: ctx)

            let statement = Self.createObject(entityName: "Statement", in: ctx)
            statement.setValue(account, forKey: "pAccount")
            statement.setValue(DateConversion.toDate(startTs), forKey: "pStartDate")
            statement.setValue(DateConversion.toDate(endTs), forKey: "pEndDate")
            statement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance")
            statement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            statement.setValue(name, forKey: "pName")
            statement.setValue(note, forKey: "pNote")
            statement.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(statement, "pCreationTime")
            Self.setNow(statement, "pModificationDate")

            try ctx.obtainPermanentIDs(for: [statement])
            return Self.extractPK(from: statement.objectID)
        }

        guard let result = try get(statementId: pk) else {
            throw RepositoryError.unexpectedNilResult
        }
        return result
    }

    /// Creates a statement and reconciles `lineItemIds` into it in ONE save, so a
    /// failed reconcile leaves nothing behind (there is no create-then-delete rollback
    /// that could itself fail, and no window where the empty statement is committed).
    public func createReconciled(
        accountId: Int,
        startDate: String,
        endDate: String,
        beginningBalance: Double,
        endingBalance: Double,
        lineItemIds: [Int],
        name: String? = nil,
        note: String? = nil,
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        guard let startTs = DateConversion.fromISO(startDate, timeZone: DateConversion.dateOnlyTimeZone) else {
            throw ToolError.invalidInput("Invalid start date: \(startDate)")
        }
        guard let endTs = DateConversion.fromISO(endDate, timeZone: DateConversion.dateOnlyTimeZone) else {
            throw ToolError.invalidInput("Invalid end date: \(endDate)")
        }
        guard endTs > startTs else {
            throw ToolError.invalidInput("End date must be after start date")
        }

        let (pk, statementUUID, blobItems): (Int, String, [String: [String]]) = try performWriteReturning { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            try validateNoOverlap(accountId: accountId, startTs: startTs, endTs: endTs, in: ctx)
            try validateBeginningBalance(accountId: accountId, startTs: startTs, beginningBalance: beginningBalance, in: ctx)

            let statement = Self.createObject(entityName: "Statement", in: ctx)
            statement.setValue(account, forKey: "pAccount")
            statement.setValue(DateConversion.toDate(startTs), forKey: "pStartDate")
            statement.setValue(DateConversion.toDate(endTs), forKey: "pEndDate")
            statement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance")
            statement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            statement.setValue(name, forKey: "pName")
            statement.setValue(note, forKey: "pNote")
            statement.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(statement, "pCreationTime")
            Self.setNow(statement, "pModificationDate")
            try ctx.obtainPermanentIDs(for: [statement])
            let newId = Self.extractPK(from: statement.objectID)

            let blob = try attachLineItems(
                lineItemIds, to: statement, statementId: newId, statementAccountId: accountId,
                startTs: startTs, endTs: endTs, allowOutOfRange: false, in: ctx)
            return (newId, Self.stringValue(statement, "pUniqueID"), blob)
        }

        guard let result = try get(statementId: pk) else { throw RepositoryError.unexpectedNilResult }
        return result
    }

    public func delete(statementId: Int, allowInternal: Bool = false) throws -> Bool {
        // One save: unreconcile the members, mark their transactions modified,
        // mark the statement's sync record deleted, delete the row.
        let txLineItems: [String: [String]]? = try performWriteReturning { [self] ctx -> [String: [String]]? in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else { return nil }
            var members: [String: [String]] = [:]
            for li in Self.relatedSet(statement, "pLineItems") {
                // Leaving a statement does not un-tick the line: cleared is kept.
                li.setValue(nil, forKey: "pStatement")
                // Membership travels inside the Transaction's sync record.
                if let tx = Self.relatedObject(li, "pTransaction") {
                    Self.setNow(tx, "pModificationDate")
                    members[Self.stringValue(tx, "pUniqueID"), default: []].append(Self.stringValue(li, "pUniqueID"))
                }
            }
            try SyncRecords.markDeletedIfPresent(
                entityUUID: Self.stringValue(statement, "pUniqueID"), in: ctx
            )
            ctx.delete(statement)
            return members
        }
        guard let txLineItems else { return false }
        return true
    }

    public func reconcileLineItems(
        statementId: Int,
        lineItemIds: [Int],
        allowOutOfRange: Bool = false,
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        struct StatementInfo: Sendable {
            let accountId: Int
            let startTs: Double?
            let endTs: Double?
        }
        let info: StatementInfo = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            guard let account = Self.relatedObject(statement, "pAccount") else {
                throw ToolError.invalidInput("Statement has no associated account")
            }
            return StatementInfo(
                accountId: Self.extractPK(from: account.objectID),
                startTs: Self.dateValue(statement, "pStartDate"),
                endTs: Self.dateValue(statement, "pEndDate")
            )
        }

        let statementAccountId = info.accountId
        let startTs = info.startTs
        let endTs = info.endTs

        let txLineItems: [String: [String]] = try performWriteReturning { [self] ctx in
            var blobItems: [String: [String]] = [:]
            guard let stmtInCtx = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }

            blobItems = try attachLineItems(
                lineItemIds, to: stmtInCtx, statementId: statementId,
                statementAccountId: statementAccountId, startTs: startTs, endTs: endTs,
                allowOutOfRange: allowOutOfRange, in: ctx)

            if !lineItemIds.isEmpty {
                Self.setNow(stmtInCtx, "pModificationDate")
            }
            return blobItems
        }


        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after reconciliation: \(statementId)")
        }
        return result
    }

    /// Validates and attaches line items to a statement inside an open write, marking
    /// them cleared and their transactions modified. Returns the sync-blob membership
    /// to patch after the save.
    private func attachLineItems(
        _ lineItemIds: [Int],
        to stmtInCtx: NSManagedObject,
        statementId: Int,
        statementAccountId: Int,
        startTs: Double?,
        endTs: Double?,
        allowOutOfRange: Bool,
        in ctx: NSManagedObjectContext
    ) throws -> [String: [String]] {
        var blobItems: [String: [String]] = [:]
        for liId in lineItemIds {
            guard let li = try fetchByPK(entityName: "LineItem", pk: liId, in: ctx) else {
                throw ToolError.notFound("Line item not found: \(liId)")
            }

            // Validate account ownership
            if let liAccount = Self.relatedObject(li, "pAccount") {
                let liAccountId = Self.extractPK(from: liAccount.objectID)
                guard liAccountId == statementAccountId else {
                    throw ToolError.invalidInput("Line item \(liId) belongs to account \(liAccountId), not statement's account \(statementAccountId)")
                }
            } else {
                throw ToolError.invalidInput("Line item \(liId) has no account")
            }

            // Validate no double-assignment to a different statement
            if let existingStatement = Self.relatedObject(li, "pStatement") {
                let existingId = Self.extractPK(from: existingStatement.objectID)
                guard existingId == statementId else {
                    throw ToolError.invalidInput("Line item \(liId) is already assigned to statement \(existingId)")
                }
                continue // already assigned to this statement
            }

            // Validate date range (allow 2-day buffer before start for credit card timing)
            if !allowOutOfRange, let startTs = startTs, let endTs = endTs,
               let tx = Self.relatedObject(li, "pTransaction"),
               let txDate = Self.dateValue(tx, "pDate") {
                let bufferSeconds: Double = 2 * 86400
                guard txDate >= (startTs - bufferSeconds) && txDate <= endTs else {
                    let dateStr = DateConversion.toISO(txDate)
                    throw ToolError.invalidInput("Line item \(liId) transaction date \(dateStr) is outside statement date range (pass allowOutOfRange / --allow-out-of-range to override)")
                }
            }

            li.setValue(stmtInCtx, forKey: "pStatement")
            li.setValue(true, forKey: "pCleared")

            // Membership travels inside the Transaction's sync record
            if let tx = Self.relatedObject(li, "pTransaction") {
                Self.setNow(tx, "pModificationDate")
                blobItems[Self.stringValue(tx, "pUniqueID"), default: []].append(Self.stringValue(li, "pUniqueID"))
            }
        }
        return blobItems
    }

    public func previewReconcileLineItems(
        statementId: Int,
        lineItemIds: [Int],
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            guard let account = Self.relatedObject(statement, "pAccount") else {
                throw ToolError.invalidInput("Statement has no associated account")
            }
            let statementAccountId = Self.extractPK(from: account.objectID)
            var previewLineItems = Array(Self.relatedSet(statement, "pLineItems"))
            var seen = Set(previewLineItems.map { Self.extractPK(from: $0.objectID) })

            for liId in lineItemIds {
                guard let li = try fetchByPK(entityName: "LineItem", pk: liId, in: ctx) else {
                    throw ToolError.notFound("Line item not found: \(liId)")
                }
                guard let liAccount = Self.relatedObject(li, "pAccount") else {
                    throw ToolError.invalidInput("Line item \(liId) has no account")
                }
                let liAccountId = Self.extractPK(from: liAccount.objectID)
                guard liAccountId == statementAccountId else {
                    throw ToolError.invalidInput("Line item \(liId) belongs to account \(liAccountId), not statement's account \(statementAccountId)")
                }
                if let existingStatement = Self.relatedObject(li, "pStatement") {
                    let existingId = Self.extractPK(from: existingStatement.objectID)
                    guard existingId == statementId else {
                        throw ToolError.invalidInput("Line item \(liId) is already assigned to statement \(existingId)")
                    }
                }
                if !seen.contains(liId) {
                    previewLineItems.append(li)
                    seen.insert(liId)
                }
            }

            return self.mapToDTO(statement, lineItemsOverride: previewLineItems)
        }
    }

    public func unreconcileLineItems(
        statementId: Int,
        lineItemIds: [Int],
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO? {
        let exists: Bool = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                return false
            }
            return true
        }
        guard exists else {
            throw ToolError.notFound("Statement not found: \(statementId)")
        }

        let txLineItems: [String: [String]] = try performWriteReturning { [self] ctx in
            var blobItems: [String: [String]] = [:]
            for liId in lineItemIds {
                guard let li = try fetchByPK(entityName: "LineItem", pk: liId, in: ctx) else {
                    throw ToolError.notFound("Line item not found: \(liId)")
                }

                // Verify line item belongs to this statement
                if let existingStatement = Self.relatedObject(li, "pStatement") {
                    let existingId = Self.extractPK(from: existingStatement.objectID)
                    guard existingId == statementId else {
                        throw ToolError.invalidInput("Line item \(liId) belongs to statement \(existingId), not \(statementId)")
                    }
                } else {
                    continue // not assigned to any statement
                }

                // Membership travels inside the Transaction's sync record
                if let tx = Self.relatedObject(li, "pTransaction") {
                    Self.setNow(tx, "pModificationDate")
                    blobItems[Self.stringValue(tx, "pUniqueID"), default: []].append(Self.stringValue(li, "pUniqueID"))
                }

                // Leaving a statement does not un-tick the line: cleared is kept.
                // The save hook marks the line's transaction modified.
                li.setValue(nil, forKey: "pStatement")
                if let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) {
                    Self.setNow(statement, "pModificationDate")
                }
            }
            return blobItems
        }


        return try get(statementId: statementId)
    }

    public func update(
        statementId: Int,
        endingBalance: Double? = nil,
        beginningBalance: Double? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        name: String? = nil,
        allowInternal: Bool = false,
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        // A name is display metadata: trimmed, never blank. Naming a row does not
        // lift the unnamed-investment gate for the very write that names it.
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, trimmedName.isEmpty {
            throw ToolError.invalidInput("Statement name must not be empty")
        }
        guard endingBalance != nil || beginningBalance != nil || startDate != nil
            || endDate != nil || trimmedName != nil else {
            throw ToolError.invalidInput("Statement update requires at least one field to change")
        }
        let statementUUID: String = try performWriteReturning { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            if let beginningBalance {
                statement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance")
            }
            if startDate != nil || endDate != nil {
                guard let account = Self.relatedObject(statement, "pAccount") else {
                    throw ToolError.invalidInput("Statement \(statementId) is missing an account")
                }
                let accountId = Self.extractPK(from: account.objectID)
                let currentStart = Self.dateValue(statement, "pStartDate")
                let currentEnd = Self.dateValue(statement, "pEndDate")
                let startTs: Double
                if let startDate {
                    guard let parsed = DateConversion.fromISO(startDate, timeZone: DateConversion.dateOnlyTimeZone) else {
                        throw ToolError.invalidInput("Invalid start date: \(startDate)")
                    }
                    startTs = parsed
                } else if let currentStart {
                    startTs = currentStart
                } else {
                    throw ToolError.invalidInput("Statement \(statementId) is missing a start date")
                }
                let endTs: Double
                if let endDate {
                    guard let parsed = DateConversion.fromISO(endDate, timeZone: DateConversion.dateOnlyTimeZone) else {
                        throw ToolError.invalidInput("Invalid end date: \(endDate)")
                    }
                    endTs = parsed
                } else if let currentEnd {
                    endTs = currentEnd
                } else {
                    throw ToolError.invalidInput("Statement \(statementId) is missing an end date")
                }
                guard endTs > startTs else {
                    throw ToolError.invalidInput("End date must be after start date")
                }
                try validateNoOverlap(accountId: accountId, startTs: startTs, endTs: endTs, ignoringStatementId: statementId, in: ctx)
                if startDate != nil {
                    statement.setValue(DateConversion.toDate(startTs), forKey: "pStartDate")
                }
                if endDate != nil {
                    statement.setValue(DateConversion.toDate(endTs), forKey: "pEndDate")
                }
            }
            if let endingBalance {
                statement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            }
            if let trimmedName {
                statement.setValue(trimmedName, forKey: "pName")
            }
            Self.setNow(statement, "pModificationDate")
            return Self.stringValue(statement, "pUniqueID")
        }

        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after update: \(statementId)")
        }
        return result
    }

    /// Upstream's argument order (beginning before ending), both required so it
    /// never competes with the fork's `update` when only one is given.
    public func update(statementId: Int, beginningBalance: Double?, endingBalance: Double?) throws -> StatementDTO {
        guard beginningBalance != nil || endingBalance != nil else {
            throw ToolError.missingParameter("Give a beginning balance, an ending balance, or both")
        }
        return try update(statementId: statementId, endingBalance: endingBalance, beginningBalance: beginningBalance)
    }

    public func getUnreconciledLineItems(accountId: Int, startDate: String? = nil, endDate: String? = nil) throws -> [LineItemDTO] {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "pAccount == %@", account),
                NSPredicate(format: "pStatement == nil"),
            ]

            if let start = startDate, let startTs = DateConversion.fromISO(start) {
                predicates.append(NSPredicate(format: "pTransaction.pDate >= %@", DateConversion.toDate(startTs) as NSDate))
            }
            if let end = endDate, let endTs = DateConversion.endOfDayExclusive(end) {
                predicates.append(NSPredicate(format: "pTransaction.pDate < %@", DateConversion.toDate(endTs) as NSDate))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pTransaction.pDate", ascending: true),
            ]

            let lineItems = try ctx.fetch(request)
            return lineItems.map { self.lineItemRepo.mapToDTO($0) }
        }
    }

    // MARK: - Validation

    private func validateBeginningBalance(accountId: Int, startTs: Double, beginningBalance: Double, in ctx: NSManagedObjectContext) throws {
        guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
            return
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pEndDate <= %@", DateConversion.toDate(startTs) as NSDate),
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "pEndDate", ascending: false)]
        request.fetchLimit = 1
        let previous = try ctx.fetch(request)
        guard let prev = previous.first else { return }
        let prevEndingBalance = Self.doubleValue(prev, "pEndingBalance")
        guard abs(prevEndingBalance - beginningBalance) < 0.005 else {
            throw ToolError.invalidInput("Beginning balance \(beginningBalance) doesn't match previous statement's ending balance \(prevEndingBalance)")
        }
    }

    private func validateNoOverlap(
        accountId: Int,
        startTs: Double,
        endTs: Double,
        ignoringStatementId: Int? = nil,
        in ctx: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        // Look up account using fetchByPK which handles entity inheritance
        guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
            return
        }

        // Overlapping: existing.start < newEnd AND existing.end > newStart
        var predicates: [NSPredicate] = [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pStartDate < %@", DateConversion.toDate(endTs) as NSDate),
            NSPredicate(format: "pEndDate > %@", DateConversion.toDate(startTs) as NSDate),
        ]
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        let count: Int
        if let ignoringStatementId {
            count = try ctx.fetch(request).filter { Self.extractPK(from: $0.objectID) != ignoringStatementId }.count
        } else {
            count = try ctx.count(for: request)
        }
        guard count == 0 else {
            throw ToolError.invalidInput("Date range overlaps with an existing statement for this account")
        }
    }

    // MARK: - DTO Mapping

    /// The DTO a hash-bound preimage is taken over: `mapToDTO` plus the sync
    /// record's `pSyncedModificationDate`, so a restore can put it back exactly.
    private func preimageDTO(_ statement: NSManagedObject, in ctx: NSManagedObjectContext) throws -> StatementDTO {
        var dto = mapToDTO(statement)
        dto.syncedModificationTimestamp = try SyncRecords.syncedModificationDate(
            entityUUID: Self.stringValue(statement, "pUniqueID"), in: ctx
        )?.timeIntervalSinceReferenceDate
        return dto
    }

    private func mapToDTO(_ object: NSManagedObject, lineItemsOverride: [NSManagedObject]? = nil) -> StatementDTO {
        let pk = Self.extractPK(from: object.objectID)

        let accountId: Int
        let accountName: String
        let accountClass: Int
        let accountType: String
        if let account = Self.relatedObject(object, "pAccount") {
            accountId = Self.extractPK(from: account.objectID)
            accountName = Self.stringValue(account, "pName")
            accountClass = Self.intValue(account, "pAccountClass")
            accountType = accountTypeName(for: accountClass)
        } else {
            accountId = 0
            accountName = "Unknown"
            accountClass = 0
            accountType = "Unknown"
        }

        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        // ``pLineItems`` is a Core Data set.  The statement preimage includes
        // the derived balance fields below, so calculate them from the same
        // canonical order used by the DTO.  Otherwise an inspect in a read
        // context can hash a different floating-point accumulation from the
        // subsequent write context even when the membership is unchanged.
        let lineItems = (lineItemsOverride ?? Array(Self.relatedSet(object, "pLineItems")))
            .sorted { lhs, rhs in
                let lhsTransaction = Self.relatedObject(lhs, "pTransaction")
                let rhsTransaction = Self.relatedObject(rhs, "pTransaction")
                let lhsDate = lhsTransaction.flatMap { Self.dateValue($0, "pDate") } ?? 0
                let rhsDate = rhsTransaction.flatMap { Self.dateValue($0, "pDate") } ?? 0
                if lhsDate != rhsDate { return lhsDate < rhsDate }

                let lhsTransactionId = lhsTransaction.map { Self.extractPK(from: $0.objectID) } ?? 0
                let rhsTransactionId = rhsTransaction.map { Self.extractPK(from: $0.objectID) } ?? 0
                if lhsTransactionId != rhsTransactionId { return lhsTransactionId < rhsTransactionId }

                return Self.extractPK(from: lhs.objectID) < Self.extractPK(from: rhs.objectID)
            }
        let reconciledBalance = lineItems.reduce(0.0) { sum, li in
            sum + Self.statementBalanceAmount(for: li)
        }
        let expectedChange = endingBalance - beginningBalance
        let difference = expectedChange - reconciledBalance

        let startDate: String
        if let ts = Self.dateValue(object, "pStartDate") {
            startDate = DateConversion.toISO(ts)
        } else {
            startDate = ""
        }

        let endDate: String
        if let ts = Self.dateValue(object, "pEndDate") {
            endDate = DateConversion.toISO(ts)
        } else {
            endDate = ""
        }

        let createdAt: String?
        if let ts = Self.dateValue(object, "pCreationTime") {
            createdAt = DateConversion.toISODateTime(ts)
        } else {
            createdAt = nil
        }

        let modifiedAt: String?
        if let ts = Self.dateValue(object, "pModificationDate") {
            modifiedAt = DateConversion.toISODateTime(ts)
        } else {
            modifiedAt = nil
        }

        let lineItemDTOs = lineItems.map { lineItemRepo.mapToDTO($0) }
        let rowClassification = Self.statementRowClassification(object)

        return StatementDTO(
            id: pk,
            accountId: accountId,
            accountName: accountName,
            accountClass: accountClass,
            accountType: accountType,
            uniqueId: Self.stringValue(object, "pUniqueID"),
            rowKind: rowClassification.kind,
            isVisibleNamedRow: rowClassification.isVisibleNamedRow,
            isUnnamedInvestmentRow: rowClassification.isUnnamedInvestmentRow,
            isInternalRowCandidate: rowClassification.isInternalRowCandidate,
            operatorConfirmedVisibleRequired: rowClassification.operatorConfirmedVisibleRequired,
            name: Self.string(object, "pName"),
            note: Self.string(object, "pNote"),
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: lineItems.count,
            reconciledBalance: reconciledBalance,
            difference: difference,
            cashLineBalanced: abs(difference) < 0.005,
            isBalancedAdvisory: abs(difference) < 0.005,
            uiVerificationRequired: Self.isInvestmentAccountClass(accountClass),
            warnings: Self.statementReadWarnings(accountClass: accountClass),
            lineItems: lineItemDTOs,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private func mapToSummaryDTO(_ object: NSManagedObject) -> StatementSummaryDTO {
        let pk = Self.extractPK(from: object.objectID)
        let accountClass: Int
        if let account = Self.relatedObject(object, "pAccount") {
            accountClass = Self.intValue(account, "pAccountClass")
        } else {
            accountClass = 0
        }
        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        let lineItems = Self.relatedSet(object, "pLineItems")
        let reconciledBalance = lineItems.reduce(0.0) { sum, li in
            sum + Self.statementBalanceAmount(for: li)
        }
        let expectedChange = endingBalance - beginningBalance
        let difference = expectedChange - reconciledBalance

        let startDate: String
        if let ts = Self.dateValue(object, "pStartDate") {
            startDate = DateConversion.toISO(ts)
        } else {
            startDate = ""
        }

        let endDate: String
        if let ts = Self.dateValue(object, "pEndDate") {
            endDate = DateConversion.toISO(ts)
        } else {
            endDate = ""
        }

        let rowClassification = Self.statementRowClassification(object)

        return StatementSummaryDTO(
            id: pk,
            name: Self.string(object, "pName"),
            rowKind: rowClassification.kind,
            isVisibleNamedRow: rowClassification.isVisibleNamedRow,
            isUnnamedInvestmentRow: rowClassification.isUnnamedInvestmentRow,
            isInternalRowCandidate: rowClassification.isInternalRowCandidate,
            operatorConfirmedVisibleRequired: rowClassification.operatorConfirmedVisibleRequired,
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: lineItems.count,
            cashLineBalanced: abs(difference) < 0.005,
            isBalancedAdvisory: abs(difference) < 0.005,
            uiVerificationRequired: Self.isInvestmentAccountClass(accountClass),
            warnings: Self.statementReadWarnings(accountClass: accountClass)
        )
    }

    private static func statementBalanceAmount(for lineItem: NSManagedObject) -> Double {
        let cashAmount = doubleValue(lineItem, "pTransactionAmount") * effectiveExchangeRate(lineItem)
        if let securityLineItem = relatedObject(lineItem, "pSecurityLineItem") {
            if abs(cashAmount) >= 0.005 {
                return cashAmount
            }
            if abs(cashAmount) < 0.005,
               let transaction = relatedObject(lineItem, "pTransaction"),
               stringValue(transaction, "pNote").localizedCaseInsensitiveContains("SECURITY ADJUSTMENT") {
                return cashAmount
            }
            return cashAmount + doubleValue(securityLineItem, "pAmount")
        }
        return cashAmount
    }

    private static func isInvestmentAccountClass(_ accountClass: Int) -> Bool {
        (2000...2010).contains(accountClass)
    }

    private static func statementReadWarnings(accountClass: Int) -> [String] {
        guard isInvestmentAccountClass(accountClass) else { return [] }
        return [
            "Investment statement balance fields are advisory cash-line checks only; Banktivity Statements UI verification is required before marking the statement complete."
        ]
    }

    private struct StatementRowClassification {
        let kind: String
        let isVisibleNamedRow: Bool
        let isUnnamedInvestmentRow: Bool
        let isInternalRowCandidate: Bool
        let operatorConfirmedVisibleRequired: Bool
    }

    private static func isInvestmentStatement(_ statement: NSManagedObject) -> Bool {
        relatedObject(statement, "pAccount")
            .map { isInvestmentAccountClass(intValue($0, "pAccountClass")) } ?? false
    }

    private static func statementRowClassification(_ statement: NSManagedObject) -> StatementRowClassification {
        let isInvestment = isInvestmentStatement(statement)
        let hasDisplayName = !(string(statement, "pName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            || !(string(statement, "pNote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let kind = (hasDisplayName ? "visible_named" : "visible_unnamed") + (isInvestment ? "_investment" : "")
        return StatementRowClassification(
            kind: kind,
            isVisibleNamedRow: hasDisplayName,
            isUnnamedInvestmentRow: isInvestment && !hasDisplayName,
            isInternalRowCandidate: false,
            operatorConfirmedVisibleRequired: false
        )
    }

    private static func statementPreimageHash(_ statement: StatementDTO) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(statement) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Internal for focused repository tests which prove a rejected restore
    // leaves the replacement row intact.  It is not exposed through the CLI.
    static func membershipPreimageHash(_ memberships: [StatementLineItemMembershipPreimageDTO]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(memberships.sorted { $0.lineItemId < $1.lineItemId }) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256JSONString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateStatementPosition(_ statement: NSManagedObject, account: NSManagedObject, expectedIndex: Int, beforeStatementId: Int?, afterStatementId: Int?, in ctx: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        request.predicate = NSPredicate(format: "pAccount == %@", account)
        request.sortDescriptors = [
            NSSortDescriptor(key: "pStartDate", ascending: true),
            NSSortDescriptor(key: "pEndDate", ascending: true),
            NSSortDescriptor(key: "pUniqueID", ascending: true),
        ]
        let rows = try ctx.fetch(request)
        guard let index = rows.firstIndex(where: { $0.objectID == statement.objectID }), index == expectedIndex else {
            throw ToolError.invalidInput("Statement position anchor index does not match")
        }
        let actualBefore = index > 0 ? Self.extractPK(from: rows[index - 1].objectID) : nil
        let actualAfter = index + 1 < rows.count ? Self.extractPK(from: rows[index + 1].objectID) : nil
        guard actualBefore == beforeStatementId && actualAfter == afterStatementId else {
            throw ToolError.invalidInput("Statement position anchors do not match")
        }
    }
}
