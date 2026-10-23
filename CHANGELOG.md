# Changelog

## Unreleased

- Sync model: the modification date is the only upload signal for inserts and updates, deletes use Banktivity's pending-delete mark, and the CLI never writes `pRemoteEntityData`. Every create stamps `pCreationTime`/`pModificationDate` and writes no `SyncedHostedEntity` (Banktivity inserts its own on upload); every update stamps `pModificationDate` in the edit's own save, including line-item add/delete, statement delete, tag delete and security price import/fix/delete. Transaction, statement (including the replacement a typed restore removes), security and tag deletes mark the record `pSyncedState = 3` in the same save as the delete; a never-synced row is simply deleted and an already-pending mark is left as it is. Patching the blob (Banktivity's three-way-merge base) told Banktivity the server already held the edit, so a stale server copy won and CLI trade repairs were reverted (measured 2026-09-30). `SyncBlobUpdater` is retired: `SyncRecords` holds the in-context deletion marks and the read-only `inspect`, and repositories no longer take a `syncBlobUpdater:` parameter. Statement replace/restore records and restores the statement record's exact prior `pSyncedModificationDate`.
- Statement preimages now include the statement sync record's `pSyncedModificationDate` (`syncedModificationTimestamp`). A preimage captured by an older binary for a statement whose sync record has a synced date hashes differently, so its stored envelope fails closed ("preimage or account scope does not match") and must be re-captured with `inspect-membership`.
- Add optional `transaction_type` to MCP `create_transaction` and CLI
  `transactions create --transaction-type`. When omitted, infer only deposit,
  withdrawal, or transfer from asset/liability line items (transfer whenever
  two or more distinct bank accounts are involved, including fee/FX transfers)
  instead of picking the first arbitrary TransactionType (often Return Of Capital).
  Investment types (`buy`, `dividend`, `check`, etc.) must be passed explicitly.
  (Roberto Michelena, rmichelena/banktivity-swift-mcp; ported onto the modification-date sync model.)
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
