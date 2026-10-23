// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
@_exported import BanktivityLib
import MCP

/// Central registry for all MCP tools.
/// Manages tool definitions and dispatches tool calls to the appropriate handler.
public final class ToolRegistry: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let writeGuard: WriteGuard
    private let bankFilePath: String

    struct ToolDefinition: Sendable {
        let tool: Tool
        let access: CapabilityAccess
        let handler: @Sendable ([String: Value]?) async throws -> CallTool.Result
    }

    private var tools: [String: ToolDefinition] = [:]

    public init(container: NSPersistentContainer, writeGuard: WriteGuard, bankFilePath: String) {
        self.container = container
        self.writeGuard = writeGuard
        self.bankFilePath = bankFilePath
    }

    /// Register a tool with its handler.
    ///
    /// `access` has no default on purpose: a tool nobody classified is exactly
    /// the gap that let ~24 write-capable tools be reachable over stdio while
    /// unadvertised. Omitting it is a compile error rather than a silent read.
    func register(
        name: String,
        access: CapabilityAccess,
        description: String,
        inputSchema: Value,
        handler: @escaping @Sendable ([String: Value]?) async throws -> CallTool.Result
    ) {
        let tool = Tool(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
        tools[name] = ToolDefinition(tool: tool, access: access, handler: handler)
    }

    /// The access this registry actually enforces for one tool, or nil if unknown.
    public func access(of name: String) -> CapabilityAccess? {
        tools[name]?.access
    }

    /// Every registered name with the access it was registered under.
    ///
    /// The drift test compares this against `CapabilityRegistry.mcpCapabilities()`;
    /// nothing else may treat it as the authority, because a binary reporting on
    /// itself cannot certify itself.
    public func registeredToolAccess() -> [String: CapabilityAccess] {
        tools.mapValues(\.access)
    }

    /// Get all registered tool definitions
    public func listTools() -> [Tool] {
        tools.values.map(\.tool).sorted { $0.name < $1.name }
    }

    /// Dispatch a tool call by name
    public func callTool(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let definition = tools[name] else {
            return ToolHelpers.errorResponse("Unknown tool: \(name)")
        }

        // The MCP analogue of the wrapper's central read/write gate. The CLI has
        // had one since the capability catalog existed; dispatch here consulted
        // nothing, which is why a write tool was reachable over stdio whenever
        // the transport was.
        if definition.access == .write, PersistentContainerFactory.readOnlyFromEnvironment {
            return ToolHelpers.errorResponse(
                "Blocked: '\(name)' is a write tool and BANKTIVITY_STORE_READ_ONLY is set."
            )
        }

        do {
            return try await definition.handler(arguments)
        } catch {
            FileHandle.standardError.write(Data("[banktivity-mcp] Tool '\(name)' error: \(error)\n".utf8))
            return ToolHelpers.errorResponse("Tool error: \(error)")
        }
    }

    /// Register the built-in diagnostic tool for dumping the Core Data model schema
    func registerDiagnosticTools() {
        register(
            name: "get_capabilities",
            access: .read,
            description: "Return stable JSON metadata for CLI commands and MCP tools, including read/write classification and safety requirements.",
            inputSchema: ToolHelpers.schema(properties: [:])
        ) { _ in
            try ToolHelpers.jsonResponse(CapabilityRegistry.report())
        }

        register(
            name: "dump_schema",
            access: .read,
            description:
                "Dump the Core Data model schema showing all entity names, attributes, and relationships. Use this to discover property names for querying.",
            inputSchema: ToolHelpers.schema(properties: [
                "entity_name": ToolHelpers.property(
                    type: "string",
                    description:
                        "Optional: filter to a specific entity name (e.g. 'Transaction', 'Account')"
                )
            ])
        ) { [bankFilePath] arguments in
            let storeContentURL = URL(fileURLWithPath: bankFilePath)
                .appendingPathComponent("StoreContent")
            let schema = try PersistentContainerFactory.dumpModelSchema(from: storeContentURL)

            let entityFilter = ToolHelpers.getString(arguments, key: "entity_name")

            if let entityFilter = entityFilter {
                let filtered = schema.filter {
                    ($0["name"] as? String)?.lowercased() == entityFilter.lowercased()
                }
                if filtered.isEmpty {
                    return ToolHelpers.errorResponse(
                        "Entity '\(entityFilter)' not found. Use dump_schema without entity_name to see all entities."
                    )
                }
                return ToolHelpers.jsonResponse(filtered)
            }

            return ToolHelpers.jsonResponse(schema)
        }
    }

    /// The five statement WRITE tools: `create_statement`, `update_statement`,
    /// `delete_statement`, `reconcile_line_items` and `unreconcile_line_items`.
    public static let statementWriteToolNames: Set<String> = [
        "create_statement", "update_statement", "delete_statement",
        "reconcile_line_items", "unreconcile_line_items",
    ]

    /// Whether the statement write tools are registered, from
    /// `BANKTIVITY_MCP_STATEMENT_WRITES`.
    ///
    /// Unset means yes, so the upstream default is unchanged. `0`, `false`,
    /// `no` or `off` leave the five tools out of the registry entirely -- not
    /// refused at dispatch but absent from `tools/list`, so a client never
    /// sees them. A deployment that plans and writes statements through a
    /// separate, reviewed route sets it to keep the MCP surface read-only for
    /// statements. The statement read tools are unaffected.
    public static func statementWritesEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = environment["BANKTIVITY_MCP_STATEMENT_WRITES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "0", "false", "no", "off": return false
        default: return true
        }
    }

    /// Register all tools. Called during server initialization.
    ///
    /// `statementWrites` defaults to `BANKTIVITY_MCP_STATEMENT_WRITES`; see
    /// `statementWritesEnabled(environment:)`.
    public func registerAllTools(statementWrites: Bool = ToolRegistry.statementWritesEnabled()) {
        registerDiagnosticTools()

        // Create repositories
        let lineItemRepo = LineItemRepository(container: container)
        let accountRepo = AccountRepository(container: container)
        let transactionRepo = TransactionRepository(container: container, lineItemRepo: lineItemRepo)
        let tagRepo = TagRepository(container: container)
        let categoryRepo = CategoryRepository(container: container)
        let templateRepo = TemplateRepository(container: container)
        let importRuleRepo = ImportRuleRepository(container: container)
        let scheduledRepo = ScheduledTransactionRepository(container: container)
        let categorizationRepo = CategorizationRepository(
            container: container,
            categoryRepo: categoryRepo,
            importRuleRepo: importRuleRepo
        )

        // Account tools
        registerAccountTools(registry: self, accounts: accountRepo, tags: tagRepo, writeGuard: writeGuard)

        // Transaction tools (read + write)
        registerTransactionTools(
            registry: self, transactions: transactionRepo,
            accounts: accountRepo, writeGuard: writeGuard
        )

        // Category tools (read + write)
        registerCategoryTools(registry: self, categories: categoryRepo, writeGuard: writeGuard)

        // Tag tools (read + write)
        registerTagTools(
            registry: self, tags: tagRepo,
            writeGuard: writeGuard, transactions: transactionRepo
        )

        // Template tools (read + write)
        registerTemplateTools(registry: self, templates: templateRepo, writeGuard: writeGuard)

        // Import rule tools (read + write)
        registerImportRuleTools(registry: self, importRules: importRuleRepo, writeGuard: writeGuard)

        // Scheduled transaction tools (read + write)
        registerScheduledTransactionTools(registry: self, scheduled: scheduledRepo, writeGuard: writeGuard)

        // Categorization tools (read + write)
        registerCategorizationTools(
            registry: self, categorization: categorizationRepo,
            categories: categoryRepo, writeGuard: writeGuard
        )

        // Line item tools (read + write)
        registerLineItemTools(
            registry: self, lineItems: lineItemRepo,
            accounts: accountRepo, writeGuard: writeGuard
        )

        // Statement tools (read + write)
        let statementRepo = StatementRepository(container: container, lineItemRepo: lineItemRepo)
        registerStatementTools(
            registry: self, statements: statementRepo,
            accounts: accountRepo, lineItems: lineItemRepo, writeGuard: writeGuard,
            includeWrites: statementWrites
        )

        // Security tools (read + write)
        let securityRepo = SecurityRepository(container: container)
        registerSecurityTools(registry: self, securities: securityRepo, writeGuard: writeGuard)

        // Export tools (read-only)
        registerExportTools(registry: self, container: container, bankFilePath: bankFilePath)
    }
}
