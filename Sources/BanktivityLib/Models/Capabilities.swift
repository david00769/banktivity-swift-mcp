// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

public struct CapabilityReportDTO: Codable, Sendable {
    public let schemaVersion: Int
    public let packageVersion: String
    public let commands: [CommandCapabilityDTO]
    public let tools: [CommandCapabilityDTO]

    public init(
        schemaVersion: Int = 1,
        packageVersion: String = version,
        commands: [CommandCapabilityDTO],
        tools: [CommandCapabilityDTO]
    ) {
        self.schemaVersion = schemaVersion
        self.packageVersion = packageVersion
        self.commands = commands
        self.tools = tools
    }
}

public struct CommandCapabilityDTO: Codable, Sendable {
    public let name: String
    public let surface: String
    public let access: String
    public let requiresWriteMode: Bool
    public let requiredConfirmations: [String]
    public let supportsDryRun: Bool
    public let uiVerificationRequired: Bool
    public let notes: [String]

    public init(
        name: String,
        surface: String,
        access: String,
        requiresWriteMode: Bool,
        requiredConfirmations: [String] = [],
        supportsDryRun: Bool = false,
        uiVerificationRequired: Bool = false,
        notes: [String] = []
    ) {
        self.name = name
        self.surface = surface
        self.access = access
        self.requiresWriteMode = requiresWriteMode
        self.requiredConfirmations = requiredConfirmations
        self.supportsDryRun = supportsDryRun
        self.uiVerificationRequired = uiVerificationRequired
        self.notes = notes
    }
}

public enum CapabilityRegistry {
    public static func report() -> CapabilityReportDTO {
        CapabilityReportDTO(
            commands: cliCapabilities(),
            tools: mcpCapabilities()
        )
    }

    public static func cliCapabilities() -> [CommandCapabilityDTO] {
        [
            readCLI("accounts list"),
            readCLI("accounts balance"),
            readCLI("accounts net-worth"),
            readCLI("accounts spending"),
            readCLI("accounts income"),
            readCLI("accounts summary"),
            writeCLI("accounts create"),
            readCLI("transactions list"),
            readCLI("transactions search"),
            readCLI("transactions get"),
            writeCLI("transactions create"),
            writeCLI("transactions update"),
            writeCLI("transactions delete"),
            readCLI("transactions sync-info"),
            readCLI("categories list"),
            readCLI("categories get"),
            readCLI("categories tree"),
            writeCLI("categories create"),
            readCLI("tags list"),
            writeCLI("tags create"),
            writeCLI("tags tag-transaction"),
            readCLI("tags get-by-tag"),
            writeCLI("tags bulk-tag"),
            readCLI("uncategorized list"),
            readCLI("uncategorized suggest"),
            readCLI("uncategorized review"),
            readCLI("uncategorized payee-summary"),
            writeCLI("uncategorized recategorize"),
            writeCLI("uncategorized bulk-recategorize", supportsDryRun: true),
            readCLI("line-items get"),
            verifiedWriteCLI("line-items add", supportsDryRun: true, note: "Line-item writes affect balances and statement membership."),
            verifiedWriteCLI("line-items update", supportsDryRun: true, note: "Line-item writes affect balances and statement membership."),
            verifiedWriteCLI("line-items delete", supportsDryRun: true, note: "Line-item writes affect balances and statement membership."),
            readCLI("templates list"),
            readCLI("templates get"),
            writeCLI("templates create"),
            writeCLI("templates update"),
            writeCLI("templates delete"),
            readCLI("import-rules list"),
            readCLI("import-rules get"),
            readCLI("import-rules match"),
            writeCLI("import-rules create"),
            writeCLI("import-rules update"),
            writeCLI("import-rules delete"),
            readCLI("scheduled list"),
            readCLI("scheduled get"),
            writeCLI("scheduled create"),
            writeCLI("scheduled update"),
            writeCLI("scheduled delete"),
            readCLI("statements list", uiVerificationRequired: true),
            readCLI("statements get", uiVerificationRequired: true),
            writeCLI("statements create", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true),
            writeCLI("statements delete", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true, note: "Internal investment statement rows require an explicit diagnostic plan plus allow_internal."),
            writeCLI("statements reconcile", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true),
            writeCLI("statements unreconcile", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true),
            readCLI("statements unreconciled"),
            readCLI("securities list"),
            writeCLI("securities create"),
            readCLI("securities prices"),
            writeCLI("securities import-prices"),
            writeCLI("securities delete-prices"),
            writeCLI("securities fix-prices"),
            readCLI("securities holdings", note: "Aggregate cost basis is best-effort and not lot-aware."),
            readCLI("securities trades"),
            readCLI("securities income"),
            writeCLI("securities adjust"),
            verifiedWriteCLI("securities update-trade", note: "Security trade writes should be verified against provider trade evidence. Use --basis-only-transfer for zero-cash transfer-in basis repairs."),
            readCLI("schema"),
            readCLI("export turtle"),
            readCLI("capabilities"),
        ].sorted { $0.name < $1.name }
    }

    public static func mcpCapabilities() -> [CommandCapabilityDTO] {
        [
            readMCP("list_accounts"),
            readMCP("get_account_balance"),
            readMCP("get_net_worth"),
            readMCP("get_spending_by_category"),
            readMCP("get_income_by_category"),
            readMCP("get_summary"),
            writeMCP("create_account"),
            readMCP("list_transactions"),
            readMCP("search_transactions"),
            readMCP("get_transaction"),
            writeMCP("create_transaction"),
            writeMCP("update_transaction"),
            writeMCP("delete_transaction"),
            readMCP("list_categories"),
            readMCP("get_category"),
            readMCP("get_category_tree"),
            writeMCP("create_category"),
            readMCP("list_tags"),
            writeMCP("create_tag"),
            writeMCP("tag_transaction"),
            readMCP("get_transactions_by_tag"),
            writeMCP("bulk_tag_transactions"),
            readMCP("get_uncategorized_transactions"),
            readMCP("suggest_category"),
            readMCP("review_categories"),
            readMCP("get_payee_category_summary"),
            writeMCP("recategorize_transaction"),
            writeMCP("bulk_recategorize", supportsDryRun: true),
            readMCP("get_line_item"),
            verifiedWriteMCP("add_line_item", supportsDryRun: true, note: "Line-item writes affect balances and statement membership."),
            verifiedWriteMCP("update_line_item", supportsDryRun: true, note: "Line-item writes affect balances and statement membership."),
            verifiedWriteMCP("delete_line_item", supportsDryRun: true, note: "Line-item writes affect balances and statement membership."),
            readMCP("list_statements", uiVerificationRequired: true),
            readMCP("get_statement", uiVerificationRequired: true),
            writeMCP("create_statement", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true),
            writeMCP("delete_statement", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true, note: "Internal investment statement rows require an explicit diagnostic plan plus allow_internal."),
            writeMCP("reconcile_line_items", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true),
            writeMCP("unreconcile_line_items", confirmations: ["backup_confirmed", "post_ui_verification_required"], uiVerificationRequired: true),
            readMCP("get_unreconciled_line_items"),
            readMCP("list_securities"),
            writeMCP("create_security"),
            writeMCP("create_share_adjustment"),
            readMCP("get_security_prices"),
            writeMCP("import_security_prices"),
            writeMCP("fix_security_prices"),
            readMCP("get_security_holdings", note: "Aggregate cost basis is best-effort and not lot-aware."),
            readMCP("get_security_trades"),
            readMCP("get_security_income"),
            verifiedWriteMCP("update_security_trade", note: "Security trade writes should be verified against provider trade evidence. Use basis_only_transfer for zero-cash transfer-in basis repairs."),
            writeMCP("delete_security_prices"),
            readMCP("dump_schema"),
            readMCP("export_turtle"),
            readMCP("get_capabilities"),
        ].sorted { $0.name < $1.name }
    }

    private static func readCLI(_ name: String, uiVerificationRequired: Bool = false, note: String? = nil) -> CommandCapabilityDTO {
        capability(name, surface: "cli", access: "read", uiVerificationRequired: uiVerificationRequired, note: note)
    }

    private static func writeCLI(
        _ name: String,
        confirmations: [String] = [],
        supportsDryRun: Bool = false,
        uiVerificationRequired: Bool = false,
        note: String? = nil
    ) -> CommandCapabilityDTO {
        capability(name, surface: "cli", access: "write", confirmations: confirmations, supportsDryRun: supportsDryRun, uiVerificationRequired: uiVerificationRequired, note: note)
    }

    private static func verifiedWriteCLI(_ name: String, supportsDryRun: Bool = false, note: String) -> CommandCapabilityDTO {
        writeCLI(name, confirmations: ["operator_reviewed_target", "post_ui_verification_required"], supportsDryRun: supportsDryRun, uiVerificationRequired: true, note: note)
    }

    private static func readMCP(_ name: String, uiVerificationRequired: Bool = false, note: String? = nil) -> CommandCapabilityDTO {
        capability(name, surface: "mcp", access: "read", uiVerificationRequired: uiVerificationRequired, note: note)
    }

    private static func writeMCP(
        _ name: String,
        confirmations: [String] = [],
        supportsDryRun: Bool = false,
        uiVerificationRequired: Bool = false,
        note: String? = nil
    ) -> CommandCapabilityDTO {
        capability(name, surface: "mcp", access: "write", confirmations: confirmations, supportsDryRun: supportsDryRun, uiVerificationRequired: uiVerificationRequired, note: note)
    }

    private static func verifiedWriteMCP(_ name: String, supportsDryRun: Bool = false, note: String) -> CommandCapabilityDTO {
        writeMCP(name, confirmations: ["operator_reviewed_target", "post_ui_verification_required"], supportsDryRun: supportsDryRun, uiVerificationRequired: true, note: note)
    }

    private static func capability(
        _ name: String,
        surface: String,
        access: String,
        confirmations: [String] = [],
        supportsDryRun: Bool = false,
        uiVerificationRequired: Bool = false,
        note: String? = nil
    ) -> CommandCapabilityDTO {
        CommandCapabilityDTO(
            name: name,
            surface: surface,
            access: access,
            requiresWriteMode: access == "write",
            requiredConfirmations: confirmations,
            supportsDryRun: supportsDryRun,
            uiVerificationRequired: uiVerificationRequired,
            notes: note.map { [$0] } ?? []
        )
    }
}
