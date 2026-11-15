// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib
@testable import BanktivityMCPLib

/// Every MCP tool has a `banktivity-cli` equivalent, and the two lists cannot part
/// silently. The CLI is the primary interface; MCP is the fallback, so a tool with
/// no verb is a feature the primary interface lacks.
///
/// The CLI is an executable target and cannot be imported, so its verbs are read
/// from its sources: a nested `AsyncParsableCommand` struct is a verb named by its
/// `commandName:` or, failing that, its kebab-cased struct name, and a top-level
/// struct with no nested commands is itself a verb.
// Runs on the main actor: see TestVaultHelper.
@Suite("CLI and MCP parity", .serialized)
@MainActor
struct CLIMCPParityTests {

    /// MCP tool -> "group verb" (or a bare verb for `schema` and `capabilities`).
    static let toolToVerb: [String: String] = [
        "list_accounts": "accounts list",
        "get_account_balance": "accounts balance",
        "get_net_worth": "accounts net-worth",
        "update_account": "accounts update",
        "get_spending_by_category": "accounts spending",
        "get_income_by_category": "accounts income",
        "get_summary": "accounts summary",
        "search_transactions": "transactions search",
        "get_transaction": "transactions get",
        "get_transactions": "transactions list",
        "create_transaction": "transactions create",
        "update_transaction": "transactions update",
        "delete_transaction": "transactions delete",
        "repair_forex_transfer": "transactions repair-forex",
        "list_categories": "categories list",
        "get_category": "categories get",
        "get_category_tree": "categories tree",
        "create_category": "categories create",
        "audit_category_entities": "categories audit-entities",
        "get_tags": "tags list",
        "create_tag": "tags create",
        "tag_transaction": "tags tag-transaction",
        "get_transactions_by_tag": "tags get-by-tag",
        "bulk_tag_transactions": "tags bulk-tag",
        "get_uncategorized_transactions": "uncategorized list",
        "suggest_category_for_merchant": "uncategorized suggest",
        "review_categorizations": "uncategorized review",
        "get_payee_category_summary": "uncategorized payee-summary",
        "recategorize_transaction": "uncategorized recategorize",
        "bulk_recategorize_by_payee": "uncategorized bulk-recategorize",
        "get_line_item": "line-items get",
        "get_line_item_source": "line-items source",
        "add_line_item": "line-items add",
        "update_line_item": "line-items update",
        "delete_line_item": "line-items delete",
        "list_transaction_templates": "templates list",
        "get_transaction_template": "templates get",
        "create_transaction_template": "templates create",
        "update_transaction_template": "templates update",
        "delete_transaction_template": "templates delete",
        "list_import_rules": "import-rules list",
        "get_import_rule": "import-rules get",
        "match_import_rules": "import-rules match",
        "create_import_rule": "import-rules create",
        "update_import_rule": "import-rules update",
        "delete_import_rule": "import-rules delete",
        "list_scheduled_transactions": "scheduled list",
        "get_scheduled_transaction": "scheduled get",
        "create_scheduled_transaction": "scheduled create",
        "update_scheduled_transaction": "scheduled update",
        "delete_scheduled_transaction": "scheduled delete",
        "list_statements": "statements list",
        "get_account_reconciliation_status": "statements status",
        "get_statement": "statements get",
        "plan_statement_visible_row_correction": "statements visible-row-correction-plan",
        "create_statement": "statements create",
        "update_statement": "statements update",
        "delete_statement": "statements delete",
        "reconcile_line_items": "statements reconcile",
        "unreconcile_line_items": "statements unreconcile",
        "get_unreconciled_line_items": "statements unreconciled",
        "list_securities": "securities list",
        "create_security": "securities create",
        "delete_security": "securities delete",
        "rename_security": "securities rename",
        "get_security_prices": "securities prices",
        "audit_security_prices": "securities audit-prices",
        "import_security_prices": "securities import-prices",
        "delete_security_prices": "securities delete-prices",
        "reset_security_price_range": "securities reset-price-range",
        "get_security_holdings": "securities holdings",
        "get_security_trades": "securities trades",
        "get_security_realized_gains": "securities realized-gains",
        "get_security_income": "securities income",
        "create_security_trade": "securities create-trade",
        "create_security_income": "securities create-income",
        "create_share_adjustment": "securities adjust",
        "update_security_trade": "securities update-trade",
        "dump_schema": "schema",
        "export_turtle": "export turtle",
        "get_capabilities": "capabilities",
    ]

    /// Verbs with no MCP tool, on purpose. Maintenance or bulk operations an agent
    /// should not reach over a transport, or ones the CLI alone needs.
    static let cliOnlyVerbs: Set<String> = [
        "reconciliation execute-bundle",
        "accounts create",
        "accounts recalc-balances",
        "categories delete",
        "statements inspect-membership",
        "statements inspect-sync-record",
        "securities fix-prices",
        "securities link-income-category",
        "transactions sync-info",
    ]

    private func registeredTools() throws -> Set<String> {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools()
        return Set(registry.registeredToolAccess().keys)
    }

    /// Reads the verbs the CLI target defines from its sources.
    static func cliVerbs() throws -> Set<String> {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let commands = tests.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BanktivityCLI/Commands")
        let files = try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var verbs: Set<String> = []
        for file in files {
            let lines = try String(contentsOfFile: file.path, encoding: .utf8).components(separatedBy: "\n")
            var group: String?
            var groupHasChildren = false
            var groupName: String?
            func closeGroup() {
                if let name = groupName, !groupHasChildren { verbs.insert(name) }
            }
            for (index, line) in lines.enumerated() {
                guard let name = structName(in: line) else { continue }
                let indent = line.prefix { $0 == " " }.count
                if indent == 0 {
                    closeGroup()
                    groupName = override(in: lines, after: index) ?? kebab(name)
                    group = groupName
                    groupHasChildren = false
                } else if indent == 4, let group {
                    groupHasChildren = true
                    verbs.insert("\(group) \(override(in: lines, after: index) ?? kebab(name))")
                }
            }
            closeGroup()
        }
        return verbs
    }

    private static func structName(in line: String) -> String? {
        guard let range = line.range(of: #"struct (\w+): (Async)?ParsableCommand"#, options: .regularExpression) else {
            return nil
        }
        return line[range].split(separator: " ")[1].dropLast().description
    }

    /// A `commandName:` in the struct's own configuration (its next few lines).
    private static func override(in lines: [String], after index: Int) -> String? {
        for line in lines[(index + 1)..<min(index + 4, lines.count)] {
            guard let range = line.range(of: #"commandName: "[^"]+""#, options: .regularExpression) else { continue }
            return String(line[range].dropFirst("commandName: \"".count).dropLast())
        }
        return nil
    }

    /// ArgumentParser's derivation: `NetWorth` -> `net-worth`.
    private static func kebab(_ name: String) -> String {
        var out = ""
        for (offset, ch) in name.enumerated() {
            if ch.isUppercase, offset > 0 { out.append("-") }
            out.append(contentsOf: String(ch).lowercased())
        }
        return out
    }

    @Test("every registered MCP tool is mapped to a CLI verb")
    func everyToolIsMapped() throws {
        let missing = try registeredTools().subtracting(Self.toolToVerb.keys).sorted()
        #expect(missing.isEmpty, "MCP tools with no CLI verb in the parity map: \(missing)")
    }

    @Test("every mapped tool is a registered tool")
    func noStaleMapEntries() throws {
        let stale = Set(Self.toolToVerb.keys).subtracting(try registeredTools()).sorted()
        #expect(stale.isEmpty, "parity map names tools that are not registered: \(stale)")
    }

    @Test("every mapped CLI verb exists in the CLI sources")
    func mappedVerbsExist() throws {
        let real = try Self.cliVerbs()
        let missing = Set(Self.toolToVerb.values).union(Self.cliOnlyVerbs).subtracting(real).sorted()
        #expect(missing.isEmpty, "verbs named in the parity map that the CLI does not define: \(missing)")
    }

    @Test("every CLI verb is mapped to a tool or listed as CLI-only")
    func everyVerbAccountedFor() throws {
        let known = Set(Self.toolToVerb.values).union(Self.cliOnlyVerbs)
        let unaccounted = try Self.cliVerbs().subtracting(known).sorted()
        #expect(unaccounted.isEmpty, "CLI verbs neither mapped to a tool nor listed as CLI-only: \(unaccounted)")
    }

    @Test("no two tools share a verb")
    func verbsAreUnique() {
        #expect(Set(Self.toolToVerb.values).count == Self.toolToVerb.count)
    }

    /// Parameters the CLI exposed that the tool lacked, closed from the CLI side.
    static let requiredToolParameters: [String: [String]] = [
        "update_statement": ["beginning_balance", "start_date", "end_date", "name", "allow_internal"],
        "create_security_income": ["withheld_amount", "withholding_category_id"],
        "create_statement": ["line_item_ids", "operator_confirmed_visible"],
        "reconcile_line_items": ["dry_run"],
        "get_transaction": ["show_instant"],
        "get_transactions": ["show_instant"],
    ]

    @Test("tools carry the parameters the CLI verb has")
    func toolsCarryCLIParameters() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools()
        let tools = Dictionary(uniqueKeysWithValues: registry.listTools().map { ($0.name, $0) })
        for (name, parameters) in Self.requiredToolParameters {
            let schema = tools[name]?.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            for parameter in parameters {
                #expect(schema[parameter] != nil, "\(name) lacks \(parameter)")
            }
        }
    }
}
