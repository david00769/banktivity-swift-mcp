---
name: banktivity
description: Query and manage Banktivity financial data. Use when the user asks about transactions, accounts, spending, categories, tags, or securities in their Banktivity database.
allowed-tools: Bash, Read
---

# Banktivity CLI Skill

You have `banktivity-cli`, a command-line tool that reads and writes a
Banktivity personal finance vault.

## Setup

- **Binary**: `~/.local/bin/banktivity-cli` (on PATH)
- **Vault**: `~/Documents/Banktivity/My Accounts.bank8` ← **edit this path**
- Every command needs the vault, from `BANKTIVITY_FILE_PATH` or `--vault`.

## Running a command

Commands come in groups: `banktivity-cli <group> <command> [options]`. Options
use hyphens (`--account-id`), and most take an account by ID or by name.

```sh
export BANKTIVITY_FILE_PATH="$HOME/Documents/Banktivity/My Accounts.bank8"
banktivity-cli accounts list 2>/dev/null
banktivity-cli transactions list --account-name "Checking" --start-date 2026-01-01 --limit 20 2>/dev/null
```

Add `2>/dev/null`: Core Data prints harmless warnings on stderr every time.
`banktivity-cli <group> <command> --help` shows every option, and
`banktivity-cli capabilities` lists which commands write and what confirmation
flags each needs. Neither needs a vault.

## Safety rules for writes

- Run one `banktivity-cli` or `banktivity-mcp` process per vault. Reads are low
  risk, but writes from two processes at once can lose data.
- Do one write at a time. Where you can, read the row first and write only if it
  still holds the value you planned to change.
- Make a fresh backup before any write session. Prefer a copy of the vault until
  the workflow is proven.
- Quit `banktivity-mcp` and any long-running CLI process before the vault is
  opened in Banktivity.app.
- After a vault is restored, imported or migrated in Banktivity 10, look up
  account, transaction, statement and category IDs again. They can change.
- Some writes refuse to run without confirmation flags (for example
  `--operator-reviewed-target`, `--backup-confirmed`). Only add them after the
  user has confirmed what they assert.

## Output

- Every command prints JSON on stdout.
- Lists are a plain JSON array (`[{...}, {...}]`), not wrapped in an object.
- For large results (more than about 50 items), write to a temp file and read it
  with `python3` instead of printing it into the conversation.

## Commands

### Looking things up

| Task | Command | Notes |
|---|---|---|
| All accounts with balances | `accounts list` | `--include-hidden`, `--include-categories` |
| One account's balance | `accounts balance --account-name "Checking"` | or `--account-id N` |
| Net worth | `accounts net-worth` | Set `BANKTIVITY_REPORTING_CURRENCY=USD` for totals converted into one currency |
| Vault overview | `accounts summary` | Account counts and totals |
| Spending or income by category | `accounts spending --start-date 2026-01-01 --end-date 2026-03-31` | `accounts income` for income |
| Transactions in an account | `transactions list --account-name "Checking" --start-date 2026-01-01 --limit 50` | `--offset` to page |
| Search | `transactions search --query "Costco" --limit 20` | Searches titles and notes, **not tags** |
| One transaction | `transactions get 1234` | With all its line items |
| One line item | `line-items get 5678` | |
| What the bank sent for a line item | `line-items source 5678` | Raw Plaid/OFX record; `[]` for manual entries |
| Tags | `tags list` | |
| Transactions with a tag | `tags get-by-tag --tag-name "Vacation"` | The way to find tagged transactions |
| Categories | `categories list --type expense` | Subcategories have a `fullName` like `"Motor:Tolls"` |
| One category | `categories get "Insurance:Life"` | By ID or full path |
| Category tree | `categories tree --type income` | |
| Uncategorized transactions | `uncategorized list --account-id N --limit 50` | `--exclude-transfers` |
| Categories used per payee | `uncategorized payee-summary --account-id N --min-transactions 3` | Shows inconsistent payees |
| Review a category's transactions | `uncategorized review --category-name "Groceries" --limit 50` | Or `--payee-pattern` |
| Suggest a category | `uncategorized suggest "BLUE BOTTLE"` | From rules and history |
| Which import rules match | `import-rules match "SQ *BLUE BOTTLE"` | |

### Statements (reconciliation)

| Task | Command | Notes |
|---|---|---|
| Statements for an account | `statements list --account-name "Checking"` | |
| How far reconciliation has got | `statements status --account-name "Checking"` | Statement count and latest end date; read-only |
| One statement | `statements get 42` | With reconciliation progress |
| Unreconciled line items | `statements unreconciled --account-id N --start-date 2026-01-01 --end-date 2026-01-31` | |
| Create a statement | `statements create --account-id N --start-date ... --end-date ... --beginning-balance ... --ending-balance ...` | Checks the balance carries on from the previous statement |
| Add line items to a statement | `statements reconcile --statement-id 42 --line-item-ids 1,2,3` | Refuses lines from another account or already on a statement; `--dry-run` first |
| Remove line items | `statements unreconcile --statement-id 42 --line-item-ids 1,2,3` | |
| Delete a statement | `statements delete 42` | Un-reconciles its lines |

Check `statements status` before planning new statements. Statement dates are
whole local days. Pick the candidate line items yourself before calling
`statements reconcile`. Reconciling keeps each line's cleared flag as it was,
unless the user asks for something different.

### Securities

| Task | Command | Notes |
|---|---|---|
| All securities | `securities list` | |
| Prices | `securities prices --symbol AAPL --start-date 2026-01-01 --limit 30` | Or `--id N` |
| Holdings | `securities holdings --account-id N` | Shares, cost basis, market value |
| Trades | `securities trades --symbol AAPL --account-id N` | Buys, sells, transfers |
| Realised gains | `securities realized-gains --account-id N --start-date 2026-01-01` | Per closed lot, FIFO; dates filter the sale. Refuses a non-FIFO cost-basis method |
| Income | `securities income --account-id N --start-date 2026-01-01` | Dividends, interest, distributions |
| Create a security | `securities create --symbol SYM --name "Name" --currency USD` | |
| Rename a security | `securities rename --symbol OLD --new-symbol NEW --new-name "New name"` | Refuses a ticker another security already has |
| Record a buy or sell | `securities create-trade ...` | Positive shares buy, negative sell; see `--help` for the cash-line options |
| Record a dividend | `securities create-income --account-id N --amount 12.34 --date 2026-03-31 ...` | See `--help` for the security and offset category |
| Change a trade | `securities update-trade 1234 --shares 10 --price-per-share 101.5` | Also `--amount`, `--commission`, `--symbol` |
| Share adjustment | `securities adjust --symbol SYM --account-id N --shares=-10 --date 2026-03-31` | Splits, charges, corrections |
| Import prices | `securities import-prices --symbol AAPL --file prices.csv` | Yahoo Finance, OHLCV or Date/Close CSV |
| Delete prices | `securities delete-prices --symbol AAPL --start-date ... --end-date ...` | Date range optional |
| Delete a security | `securities delete --symbol SYM --dry-run` | Refuses while trades use it; a real delete also needs `--operator-reviewed-target --post-ui-verification-required` |

### Changing things

| Task | Command | Notes |
|---|---|---|
| Create a transaction | `transactions create --date 2026-10-02 --title "Payee" --line-items '[{"account_id":6,"amount":-50},{"account_id":10,"amount":50}]'` | Type is worked out from the bank and card lines, or pass `--transaction-type` with `check`, `deposit`, `transfer` or `withdrawal`. Buys and dividends need the securities commands |
| Edit a transaction | `transactions update 1234 --title "New payee" --note "..."` | Also `--date`, `--cleared`, `--transaction-type` (any type, investment types included) |
| Change a category | `uncategorized recategorize 1234 --category-id N` | Use `--category-id` for subcategories |
| Recategorize by payee | `uncategorized bulk-recategorize --payee-pattern "UBER" --category-id N --uncategorized-only --dry-run` | **Always `--dry-run` first** |
| Tag or untag | `tags tag-transaction --transaction-id 1234 --tag-name "Vacation" --action add` | `--action remove` to untag |
| Tag many | `tags bulk-tag --transaction-ids 1,2,3 --tag-name "Vacation" --action add` | |
| Create a tag | `tags create --name "Vacation"` | |
| Create a category | `categories create --name "Tolls" --type expense --parent-path "Motor"` | |
| Rename, retype or hide an account | `accounts update --account-name "Old" --name "New"` | `--type savings`, `--hidden` / `--no-hidden`. A new type must stay on the same side of the investment line; categories are refused |

### Repairing a cross-currency transfer

Use `transactions repair-forex` (MCP: `repair_forex_transfer`). Don't imitate it
with `transactions create`, `transactions update` or line-item edits.

Only run it once the source account, target account, fee category, gross source
amount, source-currency fee, target amount and exchange rate are all known from
the bank's records. It repairs an existing transaction; it does not create one.
Back up first, and check the result in Banktivity afterwards.

How Banktivity stores such a transfer:

- the transaction's currency is the source account's currency;
- the source line is the gross debit in the source currency;
- the target line keeps the source amount after fees, with `pExchangeRate` set
  to the rate and `accountAmount` equal to what arrived in the target currency;
- the fee is a separate category line in the source currency.

```sh
banktivity-cli transactions repair-forex --transaction-id 1001 --source-account-id 2001 --target-account-id 2002 --fee-category-id 3001 --gross-source-amount 100 --source-fee-amount 1 --target-amount 74.25 --exchange-rate 0.75
```

### Export

`banktivity-cli export turtle --output vault.ttl` writes the whole vault as
RDF/Turtle (to stdout without `--output`).

### Everything else

`banktivity-cli --help` lists the groups and `<group> --help` the commands.
`references/tools.md` documents the MCP tools (the server's equivalents of these
commands) with their input schemas.

## Common gotchas

1. **Category names must match exactly**: `"Gift Given"`, not `"Gifts Given"`.
2. **Use `--category-id` for subcategories.** `--category-name "Vacation:Entertainment"`
   can resolve to the top-level "Entertainment". Look the ID up with
   `categories list` first.
3. **`transactions search` doesn't search tags.** Use `tags get-by-tag`.
4. **Dates can be a day apart** (posting date vs transaction date). Searching by
   payee or reference is more reliable than an exact date.
5. **`uncategorized bulk-recategorize` covers all history**, not just recent
   transactions. `--uncategorized-only` limits it to uncategorized ones.
6. **Dry-run first.** Before changing many transactions, run with `--dry-run` and
   show the user the count.
7. **Tags live on line items**, not on the transaction itself.
8. **Writes are saved immediately.** There is no undo; the backup is the undo.
