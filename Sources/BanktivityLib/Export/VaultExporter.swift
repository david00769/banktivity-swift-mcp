// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public struct VaultExporter: Sendable {

    public static func collectData(
        container: NSPersistentContainer,
        vaultName: String
    ) throws -> VaultExportData {
        let lineItemRepo = LineItemRepository(container: container)
        let accountRepo = AccountRepository(container: container)
        let categoryRepo = CategoryRepository(container: container)
        let tagRepo = TagRepository(container: container)
        let txRepo = TransactionRepository(container: container, lineItemRepo: lineItemRepo)
        let templateRepo = TemplateRepository(container: container)
        let importRuleRepo = ImportRuleRepository(container: container)
        let scheduledRepo = ScheduledTransactionRepository(container: container)
        let statementRepo = StatementRepository(container: container, lineItemRepo: lineItemRepo)
        let securityRepo = SecurityRepository(container: container)

        let accounts = try accountRepo.list(includeHidden: true)
        let categories = try categoryRepo.list(includeHidden: true)
        let tags = try tagRepo.list()
        let transactions = try txRepo.list()
        let templates = try templateRepo.list()
        let importRules = try importRuleRepo.list()
        let scheduled = try scheduledRepo.list()

        var statements: [ExportStatementDTO] = []
        for account in accounts where account.accountClass < AccountClass.income {
            let summaries = try statementRepo.list(accountId: account.id)
            for summary in summaries {
                statements.append(ExportStatementDTO(
                    accountId: account.id,
                    accountName: account.name,
                    summary: summary
                ))
            }
        }

        let securities = try securityRepo.listSecurities()
        let holdings = try securityRepo.getHoldings()
        let trades = try securityRepo.getTrades()
        let income = try securityRepo.getIncome()

        var prices: [String: [SecurityPriceDTO]] = [:]
        for security in securities {
            do {
                let secPrices = try securityRepo.getPrices(id: security.id)
                if !secPrices.isEmpty {
                    prices[security.symbol] = secPrices
                }
            } catch {
                // Skip securities without price data
            }
        }

        return VaultExportData(
            vaultName: vaultName,
            accounts: accounts,
            transactions: transactions,
            categories: categories,
            tags: tags,
            templates: templates,
            importRules: importRules,
            scheduled: scheduled,
            statements: statements,
            securities: securities,
            holdings: holdings,
            trades: trades,
            income: income,
            prices: prices
        )
    }
}
