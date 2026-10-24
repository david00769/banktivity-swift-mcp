# Changelog

## v0.17.1 (2026-10-25)

- **Claude Desktop extension and MCP Registry.** Each release now has an MCP
  Bundle, `banktivity-swift-mcp-vX.Y.Z-macos-universal.mcpb`, that installs
  `banktivity-mcp` in Claude Desktop and asks for the vault path (and an
  optional read-only switch). `make mcpb` builds it. The release workflow
  publishes the server to the official MCP Registry as
  `io.github.david00769/banktivity-swift-mcp` (`server.json`). `glama.json`
  names the maintainer for the Glama directory.
- **`uncategorized list` can include transfers.** `--exclude-transfers`
  defaulted to on with no way to turn it off, so the CLI always hid transfers
  (the `get_uncategorized_transactions` tool did not), and a debug build
  refused to parse the command at all. `--no-exclude-transfers` now includes
  them; the default is unchanged.

## v0.17.0 (2026-10-24)

This release takes work from other people's forks, each credited below and in
`ACKNOWLEDGEMENTS.md`, plus fixes found while testing it.

- **Core Data can no longer rewrite Banktivity's database** (Peter Baker).
  Core Data's automatic migration is turned off, and the vault's model files are
  read in a fixed order. Before, if the model didn't match what Banktivity had
  written, Core Data "migrated" the store by dropping and recreating tables. One
  `line-items update` emptied the security price table (40,459 rows) and
  reported success. Now a mismatch stops the vault from opening.
- **Safe installs** (Peter Baker). `make install` and the new
  `make install-fast` write the binary under a temporary name, sign it, then
  rename it into place. Copying over a running `banktivity-mcp` used to get it
  killed by macOS ("Code Signature Invalid"). `make verify` checks that both
  installed binaries run. The Makefile also works with only Xcode's Command
  Line Tools installed.
- **See what the bank sent** (tool by producethis). The new
  `get_line_item_source` tool and `line-items source <id>` command show the raw
  imported record for a line item: description, source (for example Plaid),
  identifier and timestamps. This is what Banktivity's "Imported Transaction
  Details" shows. A manual entry returns an empty list.
- **Transaction types on create** (Roberto Michelena). `transactions create`
  and `create_transaction` take an optional type. Without one, the type is
  worked out from the bank and card lines: two or more accounts make a Transfer
  (fee and currency transfers included), otherwise money out is a Withdrawal and
  money in is a Deposit. Before, every new transaction got whichever type
  the database happened to return first, often "Return Of Capital". Only `check`, `deposit`,
  `transfer` and `withdrawal` can be named, because buys and dividends need a
  security; use `securities create-trade` and `create-income` for those.
- **`accounts update`** and the **`update_account`** tool (Peter Baker). Rename
  an account, change its type, or hide it. Categories are refused, and a new type
  must stay on the same side of the investment line: a checking account can't
  become a brokerage account, or the reverse. `accounts create` and
  `accounts update` now share one list of type names. `equity` is gone from that
  list; creating an equity account never worked.
- **Optional HTTP server** (Peter Baker). Set `BANKTIVITY_HTTP_PORT` to run one
  long-lived server on 127.0.0.1 instead of one stdio process per client.
  `BANKTIVITY_HTTP_PATH` changes the path (default `/mcp`). Leave it unset for
  the usual stdio mode. The server checks each request's origin, refuses
  malformed, oversized or chunked requests, and handles several clients
  connecting at once.
- **A flaky test crash is fixed for good.** Two test suites touched Core Data off
  the main thread, which crashed the run now and then. They now run on the main
  actor. A new test, `MainActorSuiteGuardTests`, fails the run if any future
  suite forgets.
- **CI and releases.** Every push builds and tests the code on GitHub, and
  pushing a version tag publishes a release with a universal download.

## Earlier changes (v0.14.0 to v0.16.0, not recorded per release)

- Sync model: the modification date is the only upload signal for inserts and updates, deletes use Banktivity's pending-delete mark, and the CLI never writes `pRemoteEntityData`. Every create stamps `pCreationTime`/`pModificationDate` and writes no `SyncedHostedEntity` (Banktivity inserts its own on upload); every update stamps `pModificationDate` in the edit's own save, including line-item add/delete, statement delete, tag delete and security price import/fix/delete. Transaction, statement (including the replacement a typed restore removes), security and tag deletes mark the record `pSyncedState = 3` in the same save as the delete; a never-synced row is simply deleted and an already-pending mark is left as it is. Patching the blob (Banktivity's three-way-merge base) told Banktivity the server already held the edit, so a stale server copy won and CLI trade repairs were reverted (measured 2026-09-30). `SyncBlobUpdater` is retired: `SyncRecords` holds the in-context deletion marks and the read-only `inspect`, and repositories no longer take a `syncBlobUpdater:` parameter. Statement replace/restore records and restores the statement record's exact prior `pSyncedModificationDate`.
- Statement preimages now include the statement sync record's `pSyncedModificationDate` (`syncedModificationTimestamp`). A preimage captured by an older binary for a statement whose sync record has a synced date hashes differently, so its stored envelope fails closed ("preimage or account scope does not match") and must be re-captured with `inspect-membership`.
- Preserve Banktivity date-only calendar days in the host time zone instead of
  parsing and formatting them as UTC instants; full ISO 8601 timestamps remain UTC
- Add `securities realized-gains` CLI command and `get_security_realized_gains` MCP tool: realised capital gains per closed lot, with acquisition date, holding period and term. Banktivity computes gains at render time and persists nothing (`SecurityLot` ships empty), so this recomputes them by FIFO lot matching; it refuses rather than guessing when a security uses a cost-basis method other than FIFO
- Add `BaseRepository.decimalValue()`, returning `Decimal` rather than routing an `NSDecimalNumber` column through `Double`

## v0.13.0

- Fix deletion sync: set `pSyncedState = 3` with current timestamp to signal deletion to CloudKit, instead of clearing blob and nulling modification date (which Banktivity ignored)
- Fix statement deletion sync: `StatementRepository.delete()` now marks the statement's own sync record for deletion
- Add `transactions sync-info` CLI command for inspecting sync record state
- Add `SyncBlobUpdater.inspectSyncRecord()` diagnostic method

## v0.12.0

- Fix statement reconciliation balance to include SecurityLineItem amounts (`pAmount`) alongside regular line item amounts (`pTransactionAmount`), matching Banktivity's own calculation for investment accounts

## v0.11.0

- Add RDF/Turtle export (`export turtle` CLI, `export_turtle` MCP tool) using schema.org + custom [personal-finance-ontology](https://github.com/sflinter/personal-finance-ontology)
- Add optional `tags` field to `LineItemDTO` (populated from `pTags` relationship)
- Fix sync propagation: `performBlobUpdate` now NULLs `pSyncedModificationDate` so blob patches propagate after initial desktop sync
- Fix deletion sync: `deleteSyncRecord` keeps the sync record with cleared blob instead of deleting it, so deletions propagate to CloudKit
- Add Makefile for repeatable builds (`make build`, `make test`, `make release`, `make install`, `make package`)
- Update MCP SDK from 0.11.0 to 0.12.0

## v0.10.0

- Add `securities update-trade` CLI command to update SecurityLineItem fields (shares, price, amount, security) on existing transactions
- Add `--transaction-type` option to `transactions update` CLI and `transaction_type` parameter on MCP `update_transaction` tool
- Add transaction type and SecurityLineItem sync blob patching to SyncBlobUpdater
- Fix transaction type base type code mappings (withdrawal=2, move-shares-in=210, dividend=301, etc.)

## v0.9.0

- Update Security sync blobs with latest price on import

## v0.8.0

- Fix currency bug in transaction/security creation
- Add sync record creation for new transactions

## v0.7.0

- Add ZSYNCEDENTITY sync blob updates for CLI/MCP write operations
- Fix sync blob updates: never set pSyncedModificationDate

## v0.6.1

- Fix fetchByPK entity inheritance and statement reconciliation bugs

## v0.6.0

- Add security creation and share adjustment support

## v0.5.0

- Add security holdings, trades, and income support

## v0.4.0

- Add security price history support

## v0.3.0

- Add statement reconciliation support

## v0.2.0

- Separate domain library from MCP and add CLI
- Add `--account-name`, tag commands, multi-line-item create, `--version`
- Add `--format` CLI option
- Add `/banktivity` Claude Code skill

## v0.1.0

- Initial Swift rewrite with Core Data (replacing TypeScript/SQL implementation)
