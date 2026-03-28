// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Account operations",
        subcommands: [List.self, Balance.self, NetWorth.self, Spending.self, Income.self, Summary.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all accounts")

        @OptionGroup var parent: GlobalOptions

        @Flag(name: .long, help: "Include hidden accounts")
        var includeHidden = false

        @Flag(name: .long, help: "Include income/expense categories")
        var includeCategories = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let result = try accounts.listWithBalances(
                includeHidden: includeHidden,
                includeCategories: includeCategories
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Balance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get account balance")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let resolvedId = try accounts.resolveAccountId(id: accountId, name: accountName)
            let balance = try accounts.getBalance(accountId: resolvedId)
            let account = try accounts.get(accountId: resolvedId)

            try outputJSON([
                "accountId": resolvedId,
                "accountName": account?.name ?? "Unknown",
                "balance": balance,
                "formattedBalance": formatCurrency(balance, currency: account?.currency ?? "EUR"),
            ] as [String: Any], format: parent.format)
        }
    }

    struct NetWorth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Calculate net worth")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let netWorth = try accounts.getNetWorth()
            try outputJSON(netWorth, format: parent.format)
        }
    }

    struct Spending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get spending by category")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let spending = try accounts.getCategoryAnalysis(
                type: "expense", startDate: startDate, endDate: endDate
            )
            try outputJSON(spending, format: parent.format)
        }
    }

    struct Income: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get income by category")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let income = try accounts.getCategoryAnalysis(
                type: "income", startDate: startDate, endDate: endDate
            )
            try outputJSON(income, format: parent.format)
        }
    }

    struct Summary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get vault summary")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)
            let tags = TagRepository(container: container)

            let summary = try accounts.getSummary(tagCount: try tags.list().count)
            try outputJSON(summary, format: parent.format)
        }
    }
}
