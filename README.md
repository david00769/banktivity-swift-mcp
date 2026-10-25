# banktivity-swift-mcp: Banktivity MCP server and CLI for AI assistants

[![CI](https://img.shields.io/github/actions/workflow/status/david00769/banktivity-swift-mcp/ci.yml?branch=main&label=CI)](https://github.com/david00769/banktivity-swift-mcp/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/david00769/banktivity-swift-mcp)](https://github.com/david00769/banktivity-swift-mcp/releases)
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-F05138)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)](#requirements)
[![MCP](https://img.shields.io/badge/MCP-server-blue)](https://modelcontextprotocol.io/)
[![License: PolyForm Noncommercial + MIT](https://img.shields.io/badge/License-PolyForm%20NC%20%2B%20MIT-orange)](#license)

A Swift library, [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)
server and command-line tool for [Banktivity](https://www.iggsoftware.com/banktivity/)
personal finance files. It lets Claude Desktop, Claude Code, Cursor and other
MCP clients or AI agents read and write a Banktivity 10 `.bank8` vault:
accounts, transactions, splits, categories, payees, tags, templates, import
rules, scheduled transactions, statements and securities. It can also export a
vault as RDF.

- **banktivity-cli** is the command-line tool, for scripts, for AI agents that run shell commands, and for looking things up yourself.
- **banktivity-mcp** is an MCP server with 79 tools, so an AI assistant such as Claude can work with your vault.
- **BanktivityLib** is the library both are built on. It has no server dependencies.

Every change goes through Core Data, the way Banktivity itself writes, so
edits are seen by Banktivity's iCloud/CloudKit sync. See
[CloudKit sync safety](#cloudkit-sync-safety-why-core-data-not-direct-sqlite).

## CloudKit sync safety: why Core Data, not direct SQLite

A `.bank8` vault is a Core Data store, and Banktivity syncs it through CloudKit.

- **Writing SQLite directly is invisible to sync.** A tool that writes
  `core.sql` with SQL bypasses Core Data's change tracking. CloudKit sync never
  sees those edits, so they can fail to sync, be reverted, or corrupt the vault.
  Martijn Riemers's TypeScript
  [banktivity-mcp](https://github.com/mhriemers/banktivity-mcp), which
  inspired the Swift rewrite, was built that way.
- **This tool writes through Core Data.** Steve Flinter's Swift rewrite opens
  the vault with `NSPersistentContainer`, using Banktivity's own compiled data
  model, and makes every change through it, as Banktivity does.
- **Writes are refused while Banktivity has the vault open** (an `lsof` check,
  from the Swift rewrite).
- **This fork adds more guards.** CLI edits are no longer reverted by the next
  sync, Core Data is never allowed to migrate (rewrite) Banktivity's database,
  and the write guard now refuses when it cannot tell and is enforced where
  every write is saved. See
  [Safety Features](#safety-features).

> **Warning: this tool changes your Banktivity data.** Write commands make real
> changes to your vault, and AI assistants make mistakes. Back up the vault before
> any write session, and work on a copy until you trust your setup. The authors
> are not responsible for data loss.

**Using it safely**

- Run one `banktivity-cli` or `banktivity-mcp` process per vault at a time.
  Writes are queued inside one process, but nothing locks the file across
  processes.
- Quit any `banktivity-mcp` server before you open the same vault in
  Banktivity.app. The app and this tool must not have the file open together.
  (Writes are refused while Banktivity has the vault open, but reads are not.)
- Back up before every write session.
- After restoring, importing or migrating a vault in Banktivity 10, look up
  account, transaction, statement and category IDs again. Banktivity can
  renumber them.

## About this fork

This is david00769's maintained fork of Steve Flinter's
[banktivity-swift-mcp](https://github.com/sflinter/banktivity-swift-mcp). It
has everything upstream has. The fixes and features below are offered upstream
as [pull requests](https://github.com/sflinter/banktivity-swift-mcp/pulls?q=is%3Apr+is%3Aopen+author%3Adavid00769),
but upstream has merged nothing since May 2026.

What the fork adds:

- **Edits that survive sync.** Changes made with the CLI are no longer reverted
  the next time Banktivity syncs.
- **Statements:** reconciliation, plus repair commands for statement rows.
- **Investments:** create security trades and income, and see realised capital
  gains per lot.
- **Safety and reporting:** a read-only mode, a machine-readable list of which
  commands write, net worth in one reporting currency, and the market value of
  holdings.
- **New in v0.17.0:**
  - a guard that stops Core Data from rewriting Banktivity's database;
  - `accounts update`;
  - `line-items source`, showing the raw bank import behind a transaction;
  - automatic transaction types on create;
  - an optional HTTP server mode.

Some of this came from other people's forks. [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)
credits each contribution, and [CHANGELOG.md](CHANGELOG.md) lists every change
by release.

## Which Banktivity MCP should I use?

Three related projects come up when you search for a Banktivity MCP server:

| Project | Language | How it writes | Install | Status |
| --- | --- | --- | --- | --- |
| [mhriemers/banktivity-mcp](https://github.com/mhriemers/banktivity-mcp) | TypeScript (npm) | SQL into `core.sql` (as described when the Swift rewrite began) | npm | The original TypeScript server that inspired the Swift rewrite |
| [sflinter/banktivity-swift-mcp](https://github.com/sflinter/banktivity-swift-mcp) | Swift | Core Data (`NSPersistentContainer`) | Homebrew (`sflinter/tap`) | The Swift rewrite this fork is based on |
| **david00769/banktivity-swift-mcp** (this repo) | Swift | Core Data, plus the guards above | [Release download](#download-a-release-recommended) or `make install` | Maintained; everything upstream has, plus the [fork's additions](#about-this-fork) |

If you want an AI assistant to write to a vault that syncs through iCloud,
use one of the Core Data projects. All three can read a vault.

## Requirements

- macOS 14 or later
- A Banktivity `.bank8` vault

## Installation

### Download a release (recommended)

Each [release](https://github.com/david00769/banktivity-swift-mcp/releases)
has one universal download (Apple Silicon and Intel) and a checksum file. CI
builds and tests the release from the tagged commit. For v0.17.3:

```sh
base=https://github.com/david00769/banktivity-swift-mcp/releases/download/v0.17.3
curl -LO "$base/banktivity-swift-mcp-v0.17.3-macos-universal.tar.gz"
curl -LO "$base/banktivity-swift-mcp-v0.17.3-macos-universal.tar.gz.sha256"
shasum -a 256 -c banktivity-swift-mcp-v0.17.3-macos-universal.tar.gz.sha256   # prints "OK"

tar xzf banktivity-swift-mcp-v0.17.3-macos-universal.tar.gz
xattr -d com.apple.quarantine banktivity-cli banktivity-mcp 2>/dev/null || true
mkdir -p ~/.local/bin && mv banktivity-cli banktivity-mcp ~/.local/bin/
banktivity-cli --version   # 0.17.3
```

The binaries are signed ad hoc, not notarized. The `xattr` line removes the
quarantine flag macOS puts on downloaded files, which would otherwise stop them
from running.

### Claude Desktop extension (`.mcpb`)

Each release also has `banktivity-swift-mcp-vX.Y.Z-macos-universal.mcpb`, an
[MCP Bundle](https://github.com/modelcontextprotocol/mcpb). Download it and
open it with Claude Desktop to install `banktivity-mcp` as an extension. Leave
**Vault path** blank to use your Banktivity 10 vault (see
[Where is my vault?](#where-is-my-vault)), and consider turning **Read-only** on. The binary inside is ad-hoc signed, not
notarized; if macOS refuses to run it, clear the quarantine flag with
`xattr -dr com.apple.quarantine ~/Library/Application\ Support/Claude/Claude\ Extensions`
and restart Claude Desktop. It installs only the MCP server; for the CLI, use the download above. The server
is also listed in the [MCP Registry](https://registry.modelcontextprotocol.io/)
as `io.github.david00769/banktivity-swift-mcp`.

### Build from source

Xcode 16 or later is recommended. Without Xcode the Makefile falls back to the Command Line Tools for building and installing (not tested here); running the tests needs Xcode.

```sh
git clone https://github.com/david00769/banktivity-swift-mcp.git
cd banktivity-swift-mcp
make install        # universal build, installed to ~/.local/bin
```

Always install with `make install` (or `make install-fast` for a quicker
single-architecture build). Never copy a new binary over `~/.local/bin` with
`cp`. `cp` rewrites the file in place, and a `banktivity-mcp` still running from
it is killed by macOS the next time it starts ("Code Signature Invalid"). The
Makefile copies to a temporary name, signs it, then renames it into place.

Other Makefile targets:

```sh
make help           # list all targets
make install-fast   # native-architecture build and install, for development
make verify         # check that the installed binaries actually run
make build          # debug build
make test           # run all tests
make test-filter FILTER=AccountUpdateTests   # run one test type
make release        # universal release build (arm64 + x86_64)
make package        # release tarball plus its SHA-256
make mcpb           # the tarball plus the Claude Desktop bundle (.mcpb)
make clean          # remove build output
```

`make test` runs the suite the way a release build behaves: release
configuration, one worker, Xcode's test frameworks.

### Homebrew (upstream's version)

```sh
brew install sflinter/tap/banktivity-swift-mcp
```

This installs upstream's binaries, without this fork's changes.

### How releases are made

CI (`.github/workflows/ci.yml`) runs on every push and pull request to `main`.
It runs `make test`, then `make package`, so a change that breaks the release
build fails before anyone tags it. To release, bump
`Sources/BanktivityLib/Version.swift` and add a matching section to
`CHANGELOG.md`, then push a tag:

```sh
git tag -a v0.18.0 -m "v0.18.0" && git push origin v0.18.0
```

`.github/workflows/release.yml` then checks that the tag matches
`Version.swift`, runs the tests, builds the tarball and publishes the release.
The CHANGELOG section becomes the release notes.

## Configuration

### Where is my vault?

Banktivity 10 keeps a vault that syncs through Banktivity Cloud in its own
library, not in Documents:

```
~/Library/Group Containers/group.com.iggsoftware.banktivity.library/IGGFinance/production/Documents/<vault id>/1.bank8
```

The `<vault id>` folder differs from Mac to Mac. **If `BANKTIVITY_FILE_PATH`
is unset or empty, `banktivity-mcp` and `banktivity-cli` use the vault in that
folder**, provided there is exactly one. With several they list them and stop,
so you can pick one.

**macOS privacy permission.** That folder belongs to Banktivity, and macOS
protects one app's data from others. The first time `banktivity-mcp` reads it
from Claude Desktop, macOS blocks it and says so in a notification ("access data
from other apps"); the server then reports that macOS blocked access. Allow it in
**System Settings > Privacy & Security > Full Disk Access**: add
`~/Library/Application Support/Claude/Claude Extensions/local.mcpb.david00769.banktivity-swift-mcp/server/banktivity-mcp`
(press ⌘⇧G in the file picker to paste the path), then turn the extension off
and on. A Terminal that already has Full Disk Access needs nothing. Because the
binaries are ad-hoc signed, macOS may ask again after an update.

A vault saved anywhere else (the examples below use
`~/Documents/Banktivity/My Accounts.bank8`) needs its path set. The path must
end in `.bank8`; if you give a folder, the error lists the vaults inside it.

### Claude Code

Add to a project's `.mcp.json`, or to `~/.claude.json` for every project
(`claude mcp add` writes the same entry):

```json
{
  "mcpServers": {
    "banktivity": {
      "command": "/Users/you/.local/bin/banktivity-mcp",
      "env": {
        "BANKTIVITY_FILE_PATH": "/Users/you/Documents/Banktivity/My Accounts.bank8"
      }
    }
  }
}
```

### Claude Desktop (`claude_desktop_config.json`)

Add the same block to
`~/Library/Application Support/Claude/claude_desktop_config.json`, then
restart Claude Desktop.

### Cursor (`mcp.json`)

Add the same block to `~/.cursor/mcp.json`, or to `.cursor/mcp.json` in a
project.

### Other MCP clients

Any client that starts stdio MCP servers takes the same two things: the
command `banktivity-mcp` (use its absolute path) and the environment variable
`BANKTIVITY_FILE_PATH` set to your `.bank8` vault (optional for a Banktivity 10
vault; see [Where is my vault?](#where-is-my-vault)). For one shared server over
HTTP, see below. For agents that can run shell commands, also consider the
[CLI](#cli-or-mcp-server-which-to-run-and-keeping-the-vault-safe).

### Running one long-lived server over HTTP

Normally each client starts its own `banktivity-mcp` over stdio. If you'd rather
run one server that stays up (for example under launchd), set
`BANKTIVITY_HTTP_PORT`. It listens on `127.0.0.1` only:

```sh
BANKTIVITY_FILE_PATH=~/Documents/Banktivity/My\ Accounts.bank8 \
BANKTIVITY_HTTP_PORT=8790 banktivity-mcp
# Banktivity MCP server listening on http://127.0.0.1:8790/mcp
```

`BANKTIVITY_HTTP_PATH` changes the `/mcp` path. To check that it answers:

```sh
curl -s http://127.0.0.1:8790/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'
# {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{...}},"serverInfo":{"name":"banktivity-mcp","version":"0.17.3"},...}}
```

Point a client at it with a URL instead of a command:

```json
{ "mcpServers": { "banktivity": { "type": "http", "url": "http://127.0.0.1:8790/mcp" } } }
```

Two things to know before you use it:

- **Anything on your Mac can connect.** There is no password, so treat the port
  like the vault file itself. Browser pages from other sites are refused (their
  `Origin` header is checked), and so are malformed requests.
- **It keeps the vault open while it runs, and it does not see edits Banktivity
  makes.** Stop the server before you open the vault in Banktivity, and start it
  again afterwards.

## Read-only mode

Set `BANKTIVITY_STORE_READ_ONLY=1` (or `true`, `yes`) to open the vault
read-only. Even a plain read lets SQLite tidy its write-ahead log, which
changes files on disk. Use this when you want to look at a vault without
changing a byte of it:

```sh
BANKTIVITY_STORE_READ_ONLY=1 \
  banktivity-cli accounts list --vault ~/Documents/Banktivity/My\ Accounts.bank8
```

In this mode a write fails when it reaches the database. SQLite may still open
`core.sql-shm` for writing on its own, so this is an extra layer; keep your
backups.

## Net worth in one currency, and holdings value

Net worth (`accounts net-worth`, `get_net_worth`, and `netWorth` inside
`summary`) reports `assets`, `liabilities` and `netWorth`, which add each account's
cash in its own currency, without converting. Net worth also
reports:

- `reportingCurrency` and `converted`: the same totals converted into one
  currency, plus `holdingsValue` (the market value of investments) and
  `netWorthWithHoldings`;
- `currencyBreakdown`: for each currency, the cash, holdings, exchange rate used
  and converted amounts;
- `warnings`: for example, an account left out because the vault has no
  exchange rate for its currency.

Choose the currency with `BANKTIVITY_REPORTING_CURRENCY` (an ISO code such as
`USD`). If it is unset, EUR is used, the label the totals have always carried.
Rates come from the vault's own exchange-rate table: the latest direct rate if
there is one, otherwise the inverse of the latest reverse rate, otherwise a
conversion through USD.

```sh
BANKTIVITY_REPORTING_CURRENCY=USD banktivity-cli accounts net-worth
```

Investment accounts in `accounts list` and `accounts balance` (and their MCP
tools) also carry `holdingsValue`: shares held × latest closing price × the
security's price multiplier. It is shown next to `balance`, never added to it.

## Available Tools

### Accounts
- `list_accounts` — List all accounts with balances
- `get_account_balance` — Get balance for a specific account
- `get_net_worth` — Calculate total net worth
- `get_spending_by_category` — Spending breakdown by category for a date range
- `get_income_by_category` — Income breakdown by category for a date range
- `get_summary` — Overall financial summary
- `update_account` — Rename an account, change its type, or hide it (see [Changing an account](#changing-an-account))

### Transactions
- `get_transactions` — List transactions with filtering and pagination
- `search_transactions` — Full-text search across payees, memos, etc.
- `get_transaction` — Get a single transaction by ID
- `create_transaction` — Create a new transaction; optional `transaction_type`, otherwise deposit, withdrawal or transfer is inferred from the bank-account lines
- `repair_forex_transfer` — Repair an existing cross-currency transfer with a target-currency receipt and source-currency fee split
- `update_transaction` — Update an existing transaction
- `delete_transaction` — Delete a transaction

#### Cross-Currency Transfer Repair

`repair_forex_transfer` repairs existing cross-currency transfer transactions through MCP, and the same `BanktivityLib` repair path is available in the CLI as `transactions repair-forex`. Use it when a transfer already exists in Banktivity but was recorded with equal numeric source/target amounts or without a fee split. It does not create new transfers.

Required inputs:

- `transaction_id` — existing transaction to repair
- `source_account_id` — account debited in the source currency
- `target_account_id` — account receiving funds in the target currency
- `fee_category_id` — expense category for the source-currency fee
- `gross_source_amount` — full source-currency debit
- `source_fee_amount` — fee in the source currency
- `target_amount` — amount received in the target account currency
- `exchange_rate` — rate from source amount after fees to target currency

Optional inputs are `title`, `date`, `note`, `source_memo`, `target_memo`, and `fee_memo`.

The repaired transaction is stored in the source account currency. The target line item stores `gross_source_amount - source_fee_amount` as its transaction amount, `exchange_rate` as `pExchangeRate`, and `target_amount` as the target account amount. The fee is a separate source-currency category split. Transactions with unmanaged extra line items are rejected instead of merged or deleted.

Example MCP call arguments:

```json
{
  "transaction_id": 1001,
  "source_account_id": 2001,
  "target_account_id": 2002,
  "fee_category_id": 3001,
  "gross_source_amount": 100.00,
  "source_fee_amount": 1.00,
  "target_amount": 74.25,
  "exchange_rate": 0.75,
  "title": "Cross-Currency Transfer",
  "date": "2025-04-27",
  "note": "Provider transfer reference",
  "source_memo": "Source-currency gross debit",
  "target_memo": "Target-currency receipt",
  "fee_memo": "Provider fee"
}
```

Equivalent CLI example:

```sh
banktivity-cli transactions repair-forex \
  --transaction-id 1001 \
  --source-account-id 2001 \
  --target-account-id 2002 \
  --fee-category-id 3001 \
  --gross-source-amount 100.00 \
  --source-fee-amount 1.00 \
  --target-amount 74.25 \
  --exchange-rate 0.75 \
  --title "Cross-Currency Transfer" \
  --date 2025-04-27 \
  --note "Provider transfer reference" \
  --source-memo "Source-currency gross debit" \
  --target-memo "Target-currency receipt" \
  --fee-memo "Provider fee"
```

### Line Items
- `get_line_item` — Get a specific line item
- `get_line_item_source` — Raw imported bank details (Plaid/OFX description, source type and identifier) for a line item; empty for manual entries
- `add_line_item` — Add a line item to a transaction (for splits)
- `update_line_item` — Update a line item
- `delete_line_item` — Delete a line item

### Categories
- `list_categories` — List all income/expense categories
- `get_category` — Get a specific category
- `get_category_tree` — Get the full category hierarchy
- `create_category` — Create a new category
- `audit_category_entities` — Find categories stored under the wrong internal type, a fault older tools could leave behind

### Categorization
- `get_uncategorized_transactions` — Find transactions without categories
- `suggest_category_for_merchant` — Suggest a category based on merchant history
- `recategorize_transaction` — Change a transaction's category
- `bulk_recategorize_by_payee` — Recategorize all transactions for a payee
- `review_categorizations` — Review recent categorization changes
- `get_payee_category_summary` — Summary of categories used per payee

### Tags
- `get_tags` — List all tags
- `create_tag` — Create a new tag
- `tag_transaction` — Tag a transaction
- `get_transactions_by_tag` — Find transactions with a specific tag
- `bulk_tag_transactions` — Tag multiple transactions at once

### Templates
- `list_transaction_templates` — List saved transaction templates
- `get_transaction_template` — Get a specific template
- `create_transaction_template` — Create a new template
- `update_transaction_template` — Update a template
- `delete_transaction_template` — Delete a template

### Import Rules
- `list_import_rules` — List all import rules
- `get_import_rule` — Get a specific import rule
- `match_import_rules` — Find rules matching a payee string
- `create_import_rule` — Create a new import rule
- `update_import_rule` — Update an import rule
- `delete_import_rule` — Delete an import rule

### Scheduled Transactions
- `list_scheduled_transactions` — List all scheduled transactions
- `get_scheduled_transaction` — Get a specific scheduled transaction
- `create_scheduled_transaction` — Create a new scheduled transaction
- `update_scheduled_transaction` — Update a scheduled transaction
- `delete_scheduled_transaction` — Delete a scheduled transaction

### Statements (Reconciliation)
- `list_statements` — List statements for an account
- `get_account_reconciliation_status` — Get statement count and latest statement end date for an account
- `get_statement` — Get a statement with reconciliation progress
- `create_statement` — Create a new statement with balance validation
- `delete_statement` — Delete a statement and unreconcile its line items; internal/unnamed investment rows require explicit `allow_internal`
- `reconcile_line_items` — Assign line items to a statement
- `unreconcile_line_items` — Remove line items from a statement
- `get_unreconciled_line_items` — List unreconciled line items for an account
- `update_statement` — Correct a statement's ending balance to match what Banktivity's window shows
- `plan_statement_visible_row_correction` — Turn the start, end and missing amounts you read off Banktivity's statement window into a correction plan (it does not read Banktivity's screen itself)

Each line item in a statement carries `statementBalanceAmount`, the amount
that line contributes to the statement's balance. For an investment account, add
up `statementBalanceAmount` rather than `amount` or `accountAmount`: a security
trade can move cash that the raw amounts don't show.

### Securities
- `list_securities` — List all securities with name, symbol, and currency
- `create_security` — Create a new security with symbol, name, and currency
- `get_security_prices` — Get price history for a security (by symbol or ID, optional date range/limit)
- `get_security_holdings` — Get current holdings (positions) with shares, cost basis, and market value
- `get_security_trades` — Get trade history (buys, sells, transfers) with shares, prices, and commissions
- `get_security_realized_gains` — Get realised capital gains per closed lot (acquisition date, proceeds, cost basis, gain, short/long term)
- `get_security_income` — Get investment income (dividends, interest, capital gains distributions)
- `create_security_trade` — Record a buy or sell (positive shares buy, negative shares sell), with its cash line
- `update_security_trade` — Change an existing trade's shares, price, amount, commission or security
- `create_security_income` — Create native security income, currently dividend income
- `rename_security` — Change a security's ticker, name or both (refused if another security already has that ticker)
- `create_share_adjustment` — Create a share adjustment (e.g. charges, stock splits, position corrections)
- `import_security_prices` — Import prices from a CSV file (Yahoo Finance, OHLCV, or Date/Close)
- `delete_security_prices` — Delete price history for a security (optional date range)
- `delete_security` — Delete a security record that no trade references

### Export
- `export_turtle` — Export the entire vault as RDF/Turtle (.ttl), optionally to a file

### Diagnostic
- `dump_schema` — Inspect the Core Data model schema (entity names, attributes, relationships)
- `get_capabilities` — List every command and tool, whether it reads or writes, and what confirmation it needs

## CLI or MCP server: which to run, and keeping the vault safe

The CLI is a first-class part of this project, and the reason is the vault's
safety.

**An MCP server stays running.** `banktivity-mcp` opens the vault when it
starts and keeps it open until it exits. A client such as Claude Desktop
usually starts it at launch and leaves it running in the background, even when
you are not using it. If Banktivity then opens the same vault for reading and
writing, or its sync touches the file, the two processes have the database
open at once. Banktivity may hang or crash, or sync may go wrong. You can quit
the server whenever you are done, but it is easy to forget.

**The CLI opens the vault for one command and exits.** `banktivity-cli` loads
the vault, runs the read or write, prints JSON and exits, so it is not holding
the file when you open Banktivity. AI agents are good at tool calling through
the shell, so Claude Code, Cursor's agent and other terminal agents can do the
same work through the CLI that they do through MCP tools. The
[Claude Code skill](#claude-code-skill) does exactly that.

| | `banktivity-cli` | `banktivity-mcp` |
| --- | --- | --- |
| Holds the vault open | Only while one command runs | For as long as the server runs |
| Best for | Claude Code, terminal agents, scripts, cron | Clients that only speak MCP (e.g. Claude Desktop) |
| Before opening Banktivity | Nothing to do | Quit the server (or the client that started it) |

What neither tool does:

- **Neither locks the vault.** Both refuse to *write* while Banktivity has the
  vault open (an `lsof` check before writes, cached for 3 seconds). Nothing stops Banktivity
  from opening the vault while a command is running, and reads are not
  blocked. The CLI shortens the window; it does not close it.
- **Neither replaces backups.** Back up the vault before any write session.

```sh
# Read the five latest transactions; nothing stays running afterwards
banktivity-cli transactions list --vault ~/Documents/Banktivity/My\ Accounts.bank8 --limit 5
```

## CLI

A standalone CLI (`banktivity-cli`) provides the same query and write
functionality without an MCP server. It reads a `.bank8` vault selected by
`--vault /absolute/path/to/Ledger.bank8` or `BANKTIVITY_FILE_PATH`, or with
neither, the Banktivity 10 vault ([Where is my vault?](#where-is-my-vault)).

Start with the built-in help:

```sh
banktivity-cli --help
banktivity-cli accounts --help
banktivity-cli statements inspect-membership --help
banktivity-cli capabilities --format compact
```

Help is safe to run without opening a vault. Read commands return JSON on
standard output. Write commands change financial records immediately through
Core Data; back up the vault first and review the command-specific safeguards
before using them.

Common examples:

```sh
banktivity-cli accounts list --vault ~/Documents/Banktivity/My\ Accounts.bank8
banktivity-cli accounts balance --account-name "Checking"
banktivity-cli transactions list --account-name "Checking" --start-date 2025-01-01 --limit 10
banktivity-cli statements status --account-name "Brokerage"
banktivity-cli tags get-by-tag --tag-name "Vacation" --limit 20
banktivity-cli export turtle --output vault.ttl
```

### CLI recipes

Copy-paste commands for common jobs. Set `BANKTIVITY_FILE_PATH` once, or add
`--vault <path>` after the subcommand (`accounts list --vault <path>`; it is
not accepted before it). Every command takes
`--format compact` for one-line JSON, which is easier for scripts and agents to
parse.

```sh
export BANKTIVITY_FILE_PATH=~/Documents/Banktivity/My\ Accounts.bank8

# Split one payment across two categories. Make the lines balance:
# money out of Checking (-120) equals money into the categories (+90, +30).
# Any difference is added as an uncategorized offset line.
banktivity-cli transactions create --date 2026-10-01 --title "Costco" \
  --line-items '[{"account_name":"Checking","amount":-120},
                 {"account_name":"Groceries","amount":90,"memo":"food"},
                 {"account_name":"Household","amount":30}]'

# A simple two-line transaction with an explicit type. The category line
# gets the opposite amount (+50).
banktivity-cli transactions create --account-name "Checking" --date 2026-10-02 \
  --title "Cafe" --amount -50 --category-name "Dining" --transaction-type withdrawal

# Full-text search across payees and memos, as one-line JSON
banktivity-cli transactions search --format compact --query "Amazon" --limit 20

# Uncategorized transactions in one account, including transfers
banktivity-cli uncategorized list --account-id 3 --limit 50 --no-exclude-transfers

# Which commands write, so an agent can stick to reads
banktivity-cli capabilities --format compact

# Open the vault read-only (see Read-only mode for what this does not cover)
BANKTIVITY_STORE_READ_ONLY=1 banktivity-cli accounts list
```

`transactions create` options:

| Option | Meaning |
| --- | --- |
| `--account-id` / `--account-name` | Account for the first line item (simple mode) |
| `--date` | Transaction date, `YYYY-MM-DD` (required) |
| `--title` | Payee or title (required) |
| `--amount` | Amount on the account line; required unless `--line-items` is given |
| `--category-id` / `--category-name` | Category for the second line, which gets `-amount` |
| `--note` | Optional note |
| `--transaction-type` | `check`, `deposit`, `transfer` or `withdrawal`; inferred if omitted |
| `--line-items` | JSON array of `{"account_id" or "account_name", "amount", "memo"?}`; replaces the account, amount and category options |

### Changing an account

`accounts update` renames an account, changes its type, or hides it:

```sh
banktivity-cli accounts update --account-name "Old Checking" --name "Joint Checking"
banktivity-cli accounts update --account-id 12 --type savings   # checking to savings: fine
banktivity-cli accounts update --account-id 12 --hidden         # --no-hidden shows it again
```

A new type has to stay on the same side of the investment line. Checking can
become savings or a credit card. A 529 can become a 401k. But a checking
account can't become a brokerage account, because Banktivity keeps securities
only in investment accounts:

```text
$ banktivity-cli accounts update --account-id 12 --type investment
Error: [validation_failed] Account 12 cannot move between investment and non-investment types (class 1001 to 2000); create a new account instead
```

Changing between an asset and a liability type (checking to credit card) is
allowed, and it moves the balance to the other side of net worth.
`accounts update --help` lists every type name; `accounts create --type`
accepts the same names. Categories are changed with the category commands
instead.

### Seeing what the bank sent

`line-items source` shows the raw record behind an imported transaction, before
Banktivity renamed the payee or applied import rules:

```text
$ banktivity-cli line-items source 4821
[
  {
    "amount" : -4.5,
    "date" : "2026-10-01",
    "details" : "SQ *BLUE BOTTLE COFFEE 0123",
    "matched" : true,
    "sourceIdentifier" : "pl_8Vd45zonEXAMPLE",
    "sourceTime" : "2026-10-02T09:53:14Z",
    "sourceType" : "plaid"
  }
]
```

A transaction you entered by hand returns `[]`.

### Transaction types on create

`transactions create` used to give every new transaction whichever type the
database happened to return first, often "Return Of Capital". Now it works the type out
from the bank and card lines:

| Lines | Type |
| --- | --- |
| two or more different bank or card accounts | Transfer |
| one account, money going out | Withdrawal |
| one account, money coming in | Deposit |

```text
$ banktivity-cli transactions create --date 2026-10-02 --title "Move to savings" \
    --line-items '[{"account_id":6,"amount":-500},{"account_id":7,"amount":500}]'
{ "id" : 23122, "title" : "Move to savings", "transactionType" : "Transfer", ... }
```

To choose the type yourself, pass `--transaction-type` with `check`,
`deposit`, `transfer` or `withdrawal`. Investment rows such as buys and
dividends need a security, so create them with `securities create-trade` and
`securities create-income`. `transactions update --transaction-type` can still
set any type on an existing transaction.

### Command reference

The command groups below are the complete CLI surface. Use a group's
`--help` output for required arguments, defaults, and write confirmations.

- `accounts`: `list`, `balance`, `net-worth`, `spending`, `income`, `summary`, `create`, `update`
- `transactions`: `list`, `search`, `get`, `create`, `repair-forex`, `update`, `delete`, `sync-info`
- `categories`: `list`, `get`, `tree`, `audit-entities`, `create`
- `tags`: `list`, `create`, `tag-transaction`, `get-by-tag`, `bulk-tag`
- `uncategorized`: `list`, `suggest`, `review`, `payee-summary`, `recategorize`, `bulk-recategorize`
- `line-items`: `get`, `source`, `add`, `update`, `delete`
- `templates`: `list`, `get`, `create`, `update`, `delete`
- `import-rules`: `list`, `get`, `match`, `create`, `update`, `delete`
- `scheduled`: `list`, `get`, `create`, `update`, `delete`
- `statements`: `list`, `status`, `get`, `inspect-membership`, `inspect-sync-record`, `replace-internal-row-with-visible-statement`, `restore-internal-row-from-preimage`, `visible-row-correction-plan`, `create`, `update`, `delete`, `reconcile`, `unreconcile`, `unreconciled`
- `securities`: `list`, `create`, `rename`, `delete`, `prices`, `import-prices`, `delete-prices`, `fix-prices`, `holdings`, `trades`, `realized-gains`, `income`, `create-trade`, `create-income`, `link-income-category`, `adjust`, `update-trade`
- `reconciliation`: `execute-bundle` runs a reviewed JSON plan of repairs, checked against its SHA-256 digest
- `export`: `turtle`
- `schema`: dump the Core Data schema
- `capabilities`: list every command and tool, whether it writes, and what confirmation it needs

Important behavior:

- Commands that accept `--account-id` generally also accept `--account-name`.
- Statement dates are whole days in your local time zone. Reconciling or
  un-reconciling a line keeps its cleared flag as it was.
- `transactions create --line-items` takes a JSON array for split
  transactions. See [Transaction types on create](#transaction-types-on-create)
  for how the type is chosen.
- `statements inspect-membership` and `statements inspect-sync-record` only
  read. They show which lines belong to a statement and the statement's sync
  state, and never create a missing record.
- Replacing or restoring an internal statement row needs the exact account,
  period, member lines, cleared state and a SHA-256 snapshot of the row as it
  was. These commands repair only the cases they were built for.
- `reconciliation execute-bundle` checks the plan's digest, the vault, the
  order of operations and each command before it runs anything.
- `capabilities` lists, as JSON, every command and tool: whether it writes,
  which confirmation flags it needs, and whether it has a dry run.

Use `--format compact` when a script needs one-line JSON; the default is
pretty-printed JSON for human inspection.

### Shell Completions

ArgumentParser provides shell completion scripts automatically:

```sh
banktivity-cli --generate-completion-script bash   # Bash completions
banktivity-cli --generate-completion-script zsh    # Zsh completions
banktivity-cli --generate-completion-script fish   # Fish completions
```

For example, to install Zsh completions:

```sh
banktivity-cli --generate-completion-script zsh > ~/.zfunc/_banktivity-cli
```

## Claude Code Skill

A `/banktivity` [skill](https://docs.anthropic.com/en/docs/claude-code/skills) is available for Claude Code. It lets Claude use the CLI directly to answer natural-language questions about your finances — "What did I spend on groceries last month?", "Show me uncategorized transactions in Checking", etc.

To install, copy the skill directory into your global Claude Code config:

```sh
mkdir -p ~/.claude/skills
cp -r skills/banktivity ~/.claude/skills/banktivity
```

The `skills/banktivity/` directory contains a `SKILL.md` file that teaches Claude how to invoke `banktivity-cli` with the correct environment variable and arguments. You'll need to edit the `BANKTIVITY_FILE_PATH` in `SKILL.md` to point to your own vault.

Once installed, type `/banktivity` in any Claude Code session to activate it, or Claude will activate it automatically when you ask about transactions, accounts, spending, or categories.

## Safety Features

- **Write guard**: Before any mutation, the server checks if Banktivity.app has the vault open (via `lsof`). If it does, writes are blocked to prevent corruption.
- **No schema migration**: Core Data's automatic migration is turned off. If the data model read from the vault doesn't match its database, the tool refuses to open it. Left on, Core Data would "migrate" by dropping and recreating tables; one user lost 40,459 price records that way.
- **No persistent history tracking**: Banktivity uses its own sync mechanism. Core Data's built-in history tracking would add unrecognized metadata that corrupts the vault.
- **Background contexts**: All writes use background `NSManagedObjectContext` instances with `performAndWait` for data integrity.
- **How long the vault is held open**: `banktivity-mcp` keeps the vault open for as long as it runs; `banktivity-cli` only while one command runs. Neither locks the file. See [CLI or MCP server](#cli-or-mcp-server-which-to-run-and-keeping-the-vault-safe).

## How It Works

Banktivity's `.bank8` bundle is a folder holding Banktivity's compiled data model (the `.momd` files) and a SQLite database (`StoreContent/core.sql`). This tool:

1. Loads and merges all `.momd` model bundles from the vault, in filename order
2. Opens the SQLite store via `NSPersistentContainer` (no history tracking, no migration)
3. Exposes 79 MCP tools over stdio, or over loopback HTTP when `BANKTIVITY_HTTP_PORT` is set
4. Uses KVC (`value(forKey:)`) to access entities since we load Banktivity's own compiled models at runtime

## FAQ

**Can Claude (or Cursor, or another AI agent) read my Banktivity data?**
Yes. Point an MCP client at `banktivity-mcp` ([Configuration](#configuration)),
or let a shell-capable agent run `banktivity-cli` ([CLI](#cli)).

**Is it safe with iCloud / CloudKit sync?**
Writes go through Core Data, as Banktivity's do, so sync sees them
([CloudKit sync safety](#cloudkit-sync-safety-why-core-data-not-direct-sqlite)).
Don't run it while Banktivity has the same vault open, and back up first.

**Can a running MCP server cause trouble when I open Banktivity?**
It can: the server keeps the vault open. Quit it before opening Banktivity, or use the
CLI ([CLI or MCP server](#cli-or-mcp-server-which-to-run-and-keeping-the-vault-safe)).

**Does it work with Banktivity 10 and `.bank8` files?**
Yes. It reads Banktivity's own data model from inside the `.bank8` bundle
([How It Works](#how-it-works)).

**Can I give an AI read-only access?**
Set `BANKTIVITY_STORE_READ_ONLY=1` ([Read-only mode](#read-only-mode)), and use
`banktivity-cli capabilities` to see which commands write. This is a safety
layer, not a sandbox: an agent that can run shell commands can unset the
variable, so give it a copy of the vault if it must not write.

## Acknowledgements

This fork includes work by Peter Baker, Roberto Michelena, producethis,
muxadil, Richard Jeans, Howy Perrin and Martijn Riemers, on top of Steve
Flinter's original. [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) lists each
contribution, where it came from, and how it was taken.

## License

Two licenses; [LICENSE](LICENSE) explains which applies where.

- **MIT:** everything up to commit `9bcd5d2` (just after v0.17.2), including every
  release through v0.17.2, Steve Flinter's original and all credited
  contributions ([LICENSES/MIT.txt](LICENSES/MIT.txt)).
- **PolyForm Noncommercial 1.0.0:** david00769's changes after that commit
  ([LICENSES/PolyForm-Noncommercial-1.0.0.md](LICENSES/PolyForm-Noncommercial-1.0.0.md)).
  Free for personal, hobby, research, educational, charitable and government
  use.

**Commercial use** of the PolyForm-licensed parts needs a commercial license
from [david00769](https://github.com/david00769)
(davidsiroky@me.com).
