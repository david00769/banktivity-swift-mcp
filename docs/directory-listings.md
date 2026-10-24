# Directory listings

Text and steps for listing this project in MCP directories. Nothing here is
submitted automatically; the maintainer submits each one by hand. Check each
directory's current rules before submitting, because they change.

## Text to reuse

**Name:** banktivity-swift-mcp

**One line (under 100 characters):**
Banktivity MCP server and CLI in Swift; writes go through Core Data so CloudKit sync sees them.

**Short description:**
MCP server (79 tools) and CLI for Banktivity 10 `.bank8` personal finance
vaults, written in Swift. It reads and writes accounts, transactions, splits,
categories, tags, statements and securities through Core Data, the way
Banktivity does, so edits are seen by iCloud/CloudKit sync. Works with Claude
Desktop, Claude Code, Cursor and any stdio MCP client. macOS 14+, MIT.

**Links:** repository `https://github.com/david00769/banktivity-swift-mcp`,
releases `https://github.com/david00769/banktivity-swift-mcp/releases`.

**Keywords:** banktivity, bank8, mcp, model context protocol, swift, core data,
cloudkit, personal finance, macos, claude, cursor.

## Where to submit

### awesome-mcp-servers (`punkpeye/awesome-mcp-servers`)

Open a pull request adding one line under the finance section (currently "Finance & Fintech"), in alphabetical
order, using the list's current line format and legend emoji (check the
README's legend: it marks language, local versus cloud, and OS). The line links
`david00769/banktivity-swift-mcp` and uses the one-line text above.

### Glama (`glama.ai/mcp/servers`)

Glama indexes public GitHub MCP servers. Search for the repository; if it is
missing, use "Add server" with the repository URL, then claim it with the
GitHub account to edit its listing.

### mcp.so

Use the site's submit form with the repository URL and the short description.

### Official MCP Registry (`registry.modelcontextprotocol.io`)

Not ready yet. A `server.json` package must be one of the registry's package
types (npm, PyPI, NuGet, OCI image, MCPB bundle, ...); a plain release tarball
does not qualify. The fit for this project is an **MCPB bundle** (`.mcpb`)
attached to each GitHub release, which the release workflow does not build
yet. Once it does:

1. Add `server.json` with `name` `io.github.david00769/banktivity-swift-mcp`,
   the release version, and a package of `registryType` `mcpb` whose
   `identifier` is the `.mcpb` release URL and `fileSha256` its checksum
   (schema seen 2026-10-25: `https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json`;
   check the registry docs for the current schema and field names first).
2. Publish with the registry's `mcp-publisher` CLI, signing in with GitHub,
   which proves ownership of the `io.github.david00769/` namespace.

### Smithery

Smithery is aimed at servers it can install or host for the user, and expects
its own config file. Skip it unless an MCPB or similar package exists.
