# Agent Rules

Guidance for any coding agent working in this repository — Claude Code, Codex and the xAI CLI all read `AGENTS.md`.

## What This Is

A Swift MCP (Model Context Protocol) server and CLI for [Banktivity](https://www.iggsoftware.com/banktivity/) personal finance vaults. It reads and writes `.bank8` files using Core Data's `NSPersistentContainer`, ensuring changes are properly tracked for CloudKit sync. This replaces an earlier TypeScript implementation that used direct SQL and corrupted vaults.

## Build & Run

```sh
swift build                    # Debug build
swift build -c release         # Release build

# Install binaries — ALWAYS via make; never cp over ~/.local/bin yourself (see below)
make install-fast              # native arch, fast dev loop
make install                   # universal (arm64 + x86_64)
make verify                    # check the installed binaries actually exec

# Run MCP server
BANKTIVITY_FILE_PATH="/path/to/file.bank8" swift run banktivity-mcp

# Run CLI
BANKTIVITY_FILE_PATH="/path/to/file.bank8" swift run banktivity-cli accounts list
swift run banktivity-cli --vault "/path/to/file.bank8" accounts list
```

### Never `cp` over an installed binary

`banktivity-mcp` is a long-lived **stdio** server — Paperclip agent runs leave copies
resident for hours. `cp` opens the destination `O_TRUNC` and rewrites it **in place**,
so if any running process still has that inode mapped, the kernel's code-signing state
for the vnode goes inconsistent and every later `exec` is SIGKILLed:

```
EXC_CRASH / SIGKILL (Code Signature Invalid)
termination namespace CODESIGNING ("Taskgated Invalid Signature")
```

This happened on **2026-07-28**: two servers from 11:02 and 11:19 were still resident
when 11:26 `cp`'d a new build over them. The build was fine — identical bytes ran
correctly straight out of `.build/release` and from a plain copy — but the *installed
path* was killed at exec for the next 10 hours. Every Paperclip agent silently lost the
banktivity MCP: the connector looked up but exposed zero tools, and the CFO agent could
not verify a single figure.

**The trap:** `codesign --verify` reports `valid on disk` and `satisfies its Designated
Requirement` the whole time. File-exists, `+x`, and signature checks all pass on a binary
the kernel refuses to run. Only *executing* it reveals the problem — that is what
`make verify` does (exit 137 = 128+SIGKILL).

`make install` / `make install-fast` install to a temp file, sign it, then `mv` it into
place. `mv` is a `rename(2)`: atomic, allocates a new inode, and leaves already-running
servers on the old one. If you ever hit this state, `codesign -fs - <path>` clears it by
rewriting the file.

## Testing

Tests use Swift Testing framework (`import Testing`). The Command Line Tools don't ship Testing or XCTest, so tests must run with the Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
swift test \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
```

Integration tests require a Banktivity vault at `~/Documents/Banktivity/Steves Accounts MCP.bank8`. Tests copy it to `/tmp` before each run and skip gracefully if the vault is missing.

## Architecture

Three-target package structure:

```
BanktivityLib        ← Pure domain library (no MCP dependency)
  CoreData/          PersistentContainer, DateConversion, WriteGuard, SyncRecords
  Repositories/      BaseRepository + 10 domain repositories
  Models/            DTOs, Constants, Errors, Formatting
  Export/            RDF export: TurtleWriter, TurtleSerializer, VaultExporter

BanktivityMCPLib     ← MCP glue (depends on BanktivityLib + MCP SDK)
  MCP/               ToolRegistry, ToolHelpers, Tools/*.swift

banktivity-mcp       ← MCP server executable (stdio transport)
banktivity-cli       ← CLI executable (depends on BanktivityLib + ArgumentParser)
```

**MCP server flow**: `main.swift` → reads `BANKTIVITY_FILE_PATH` env → `PersistentContainerFactory.create()` → `WriteGuard` → `ToolRegistry.registerAllTools()` → MCP Server (stdio)

**CLI flow**: `banktivity-cli <subcommand>` → reads `--vault` or `BANKTIVITY_FILE_PATH` → creates container + repos → executes command → JSON output

**Export flow**: `VaultExporter.collectData()` fetches all DTOs from repositories → `TurtleSerializer` maps DTOs to Turtle triples via `TurtleWriter` → output as `.ttl` string. The `RDFSerializer` protocol allows adding JSON-LD or other formats later. The ontology ([sflinter/personal-finance-ontology](https://github.com/sflinter/personal-finance-ontology)) uses schema.org types where applicable and a custom `pfo:` namespace for personal finance concepts.

Tests import `@testable import BanktivityLib`.

### Core Data Access

Banktivity's `.bank8` bundle contains compiled Core Data models (`.momd` files) in `StoreContent/`. We load and merge these at runtime — no `.xcdatamodeld` in this project. All entity access uses KVC on `NSManagedObject`:

```swift
let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
request.predicate = NSPredicate(format: "pDate >= %@", startDate)
let tx = try context.fetch(request)
let name = tx.value(forKey: "pName") as? String
```

Property names are prefixed with `p` (e.g., `pName`, `pDate`, `pAccountClass`, `pHidden`). Use the `dump_schema` MCP tool or `banktivity-cli schema` to inspect entity/attribute names.

### Repository Pattern

`BaseRepository` provides KVC helpers (`stringValue()`, `intValue()`, `doubleValue()`, `relatedObject()`, `relatedSet()`), fetch-by-PK with entity inheritance traversal, and write operations via background contexts (`performWrite()`, `performWriteReturning()`). Domain repositories inherit from it.

### Entity Hierarchy

`Account` (Z_ENT=1) is the base entity. `Category` (Z_ENT=2) and `PrimaryAccount` (Z_ENT=3) are sibling subentities. `pAccountClass` lives on the base: 6000=income, 7000=expense. All income/expense categories are `Category` entities.

## Critical Constraints

**Never enable persistent history tracking.** Banktivity uses `ZSYNCEDENTITY` for its own sync — Core Data's `NSPersistentHistoryTrackingKey` adds Z_PRIMARYKEY entries (entity IDs 16001+) that Banktivity doesn't recognize, corrupting the vault.

**Handle null-account line items.** Transactions can have line items where `pAccount` is NULL (orphaned slots). The recategorize logic must reuse these rather than creating new line items, which would cause false split transactions.

**Transactions require balancing offset line items.** Every transaction must have line items that sum to zero (double-entry). When `TransactionRepository.create()` receives line items that don't sum to zero, it automatically creates a balancing offset line item with no account (uncategorized). Without this, Opening Balance transactions won't affect the account's running cash balance in Banktivity.

**Security prices must set `pClosePrice`.** Some price records (from older imports or Banktivity itself) have `pClosePrice=0` with the actual value only in `pAdjustedClosePrice`. The sync blob embeds only `closePrice`, so the mobile app shows 0. Security price history does **not** sync via CloudKit — only the `latestSecurityPrice` embedded in the Security entity's sync record propagates. Use `securities fix-prices` to repair broken records; it marks each affected Security modified (as do `import-prices` and `delete-prices`). Whether Banktivity's upload then carries the corrected `latestSecurityPrice` is **unverified**.

**WriteGuard before mutations.** All write tools check `WriteGuard.guardWriteAccess()` first. If Banktivity.app has the SQLite file open (detected via `lsof`), writes are blocked to prevent corruption.

**Agent write safety.** AI assistants can issue parallel tool calls or start
multiple MCP servers. Keep one MCP/CLI process per vault, serialize writes in
the harness, and add read-before-write checks where practical so a write only
applies if the target row still has the expected value. Close all MCP/CLI
processes before opening the same vault in Banktivity.app. Make a fresh backup
before write runs, and re-resolve account, transaction, statement, and category
IDs after Banktivity 10 restore/import/migration because local numeric IDs can
change.

### Sync Bookkeeping (SyncRecords)

Banktivity's CloudKit sync keeps a `SyncedHostedEntity` (`ZSYNCEDENTITY`) record per synced entity. Measured against Banktivity 10 on 2026-09-30:

- **Upload detection is by modification date.** `IGGSyncServices` uploads entities whose `pModificationDate` / `pCreationTime` is later than the sync document's last sync date (`fetchSyncEntityIDsOfType:modifiedAfterDate:`).
- **`pRemoteEntityData` is the merge base** — a gzipped XML record of what the server holds, used as the base of a three-way merge (`mergedFieldFromBase:remote:local:`). Banktivity inserts the `SyncedHostedEntity` itself when it uploads a new row (`insertNewSyncedHostedEntityOfType:`), and only its sync writes the blob.
- **`pSyncedState` is only for deletion**: 0 = normal, 3 = pending delete.

The write model:

- **Inserts and updates: the modification date is the only upload signal.** A create sets `pCreationTime` and `pModificationDate` to now; an update sets `pModificationDate` to now — in the same context and save as the edit, as a Banktivity UI edit does. Line items (and statement membership, tags, security legs) travel inside their Transaction's record, so any change to them stamps the parent Transaction. The CLI writes no `SyncedHostedEntity` on create.
- **Deletes use Banktivity's pending-delete mark** (what `markSyncedHostedEntitiesOfType:forDeletionWithLocalIDs:` does): keep the record, set `pSyncedState = 3` and `pSyncedModificationDate` to now, in the same context and save as the entity delete (`SyncRecords.markDeletedIfPresent`). A row with no record never synced, so it is simply deleted; a record already pending deletion is left as it is. Transaction, Statement, Security and Tag deletes mark this way, including the replacement statement a typed restore removes (Tag is a synced entity: `IGGCSyncAccountingTag` in IGGSyncServices).
- **The CLI never writes `pRemoteEntityData`.** Earlier versions hand-built it on create and patched it on update; patching told Banktivity the server already held the edit, so a stale server copy won the merge and CLI trade repairs on ten accounts were reverted (2026-09-30).

Evidence on inserts: CLI creates did reach the cloud under the old model (a CLI-created cash leg appeared on the iPhone; every CLI create survived the 2026-09-30 server re-serve that reverted updates). That the modification date alone uploads an insert follows from the measured predicate but has not yet been observed end to end.

**LineItems have no separate sync records.** A Statement `SyncedHostedEntity` can exist, but historical vaults can legitimately omit an individual Statement record; typed statement replacement must never synthesize one. When an individual Statement record is present, its deleted/restore state is a strict part of the atomic forward/inverse contract: the inspection preimage records its `pSyncedModificationDate` (`syncedModificationTimestamp`) and restore puts back exactly that value. Replace/restore refuses a record already pending deletion.

`SyncRecords` is the only code that touches `SyncedHostedEntity`: static helpers that run inside the caller's context and never save on their own (`markDeletedIfPresent`, `requireNotPendingDelete`, `syncedModificationDate`, `restoreDeletedStatementRecordIfPresent`), plus the read-only `inspect` behind `transactions sync-info` and `statements inspect-sync-record`. Repositories take no sync dependency.

---

*Renamed from `CLAUDE.md` on 2026-09-21. One instruction file per
directory, and it is `AGENTS.md`: Claude Code, Codex and the xAI CLI all read
it, so a per-agent file only creates a split brain. Content is unchanged.*
