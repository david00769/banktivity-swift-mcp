# Acknowledgements

This fork (`david00769/banktivity-swift-mcp`) builds on Steve Flinter's
[banktivity-swift-mcp](https://github.com/sflinter/banktivity-swift-mcp), which
was inspired by Martijn Riemers's TypeScript
[banktivity-mcp](https://github.com/mhriemers/banktivity-mcp). Other people
have published fixes and features in their own forks, or as pull requests
upstream. This file records what this fork took from them, how, and what was
changed. Anyone reading the code can then tell borrowed work from local work,
and find the original.

How to read it:

- **Cherry-picked** means the commit is in this history with its original
  author and date. Its message ends with `Taken from <fork>, branch <name>
  (original commit <sha>)`.
- **Ported** means the idea or code was reimplemented on this fork's current
  code and committed by the maintainer, with the original author named in a
  `Co-authored-by:` trailer and the original commits cited in the message.
- Contributors' commit messages are unchanged except for three things. The
  provenance line was added. Where a conflict was resolved or the code adapted,
  one line says so. And AI-assistant co-author lines were removed, because this
  fork's commits list only human authors.

## 2026-10-23 intake (v0.17.0)

| Contribution | Author | Source | How taken | Local commit |
| --- | --- | --- | --- | --- |
| Never let Core Data migrate Banktivity's store; merge `.momd` bundles in a stable order | Peter Baker | `peterbaker/banktivity-swift-mcp` `fix/security-trade-cash-balance`, `6901da5` | Cherry-picked; conflict resolved beside this fork's `isReadOnly` option | `4938218` |
| Install atomically instead of `cp`-ing over the installed binary (`make install`, `install-fast`, `verify`) | Peter Baker | `peterbaker/banktivity-swift-mcp` `fix/atomic-install`, `83ea8e5` | Cherry-picked, unchanged | `165c283` |
| `get_line_item_source` MCP tool: raw Plaid/OFX import details for a line item | producethis | `producethis/banktivity-swift-mcp` `main`, `a6a8ab8` | Cherry-picked; adapted to declare `access: .read` and to be listed in `CapabilityRegistry` | `b36b26b` |
| Infer or accept a transaction type on create | Roberto Michelena | `rmichelena/banktivity-swift-mcp` `cursor/create-transaction-type-rebased-3d71`, `fd91944` `1c388fc` `dcb78ed` | Ported: his inference, helpers, 12 tests and docs taken; his sync-blob writes not taken (this fork retired the blob on 2026-10-15) | `8347887` |
| `accounts update` / `update_account`: rename, retype, hide | Peter Baker | `peterbaker/banktivity-swift-mcp` `fix/security-trade-cash-balance`, `521ac43` | Ported: his repository method and refusals kept; type names mapped onto this fork's `AccountClass.slugs` | `a36be32` |
| Loopback HTTP server mode (`BANKTIVITY_HTTP_PORT`) | Peter Baker | `peterbaker/banktivity-swift-mcp` `fix/security-trade-cash-balance`, `6a7a8cb` | Cherry-picked, unchanged; later commits here added request checks and fixed concurrent `initialize` (see below) | `5cde56f` |

Added here around the intake, mostly after code review:

- `line-items source` in the CLI, the same read as `get_line_item_source`;
- tests for the migration guard, the line-item source read, and the HTTP request
  parser (moved into `BanktivityMCPLib` so it can be tested);
- HTTP mode refuses malformed, conflicting, oversized and chunked requests, and
  concurrent `initialize` calls share one result (`SharedFirstSuccess`);
- `transactions create` accepts only cash types by name;
- a retype stays on the same side of the investment line;
- `make verify` fails if a binary is missing or killed, not only on a bad
  signature.

Not taken, on purpose: Peter Baker's and muxadil's ways of calculating an
investment account's cash (`fix/investment-balance-running-balance`, upstream
#19 and #33). Peter's reads Banktivity's stored running balance, which this
fork's writes leave at zero. muxadil's adds up line items, which counts some
trades twice on accounts this fork has repaired. The holdings market value from
the same work was taken (see below).

## Earlier work taken from others

| Contribution | Author | Source | How taken | Local commit |
| --- | --- | --- | --- | --- |
| Domain library split from MCP, and the CLI | Martijn Riemers | upstream PR #1 | Merged upstream; part of the base | `af27a2d` |
| Core Data threading fixes across all repositories | Howy Perrin | upstream PR #3 | Merged upstream; part of the base | `f56da7d` and six follow-ups |
| Complete `AccountClass` mapping with authoritative values | muxadil | upstream PR #18 | Cherry-picked | `2ada0de` |
| A zero or missing exchange rate counts as 1 | Richard Jeans, muxadil | upstream PR #27, PR #19 | Ported (the rule only) | `ea65f33` |
| Market value of an investment account's holdings | muxadil, Peter Baker | upstream PR #19, PR #33 | Ported (the holdings value, not the cash formula) | `d73ed8c` |
| Net worth converted to a reporting currency (`BANKTIVITY_REPORTING_CURRENCY`, `ExchangeRateRepository`) | muxadil | upstream PR #17, PR #20 | Ported | `e59d867` |

Richard Jeans's upstream PRs #28 and #29 (refuse to categorize transfers, fail
safely on category create) and Peter Baker's PR #37 (create categories as
`Category` entities) address the same faults this fork fixed in its own
commits. Their code was not taken; they are listed because the work overlaps
and their pull requests describe the faults well.
