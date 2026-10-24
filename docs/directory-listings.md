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

`glama.json` at the repository root names `david00769` as maintainer, which is
how Glama assigns ownership. If Glama has not indexed the repository, sign in
at glama.ai with GitHub and use "Add server" with the repository URL. Most
awesome-mcp-servers entries carry a Glama score badge, so do this first.

### mcp.so

Use the site's submit form (`https://mcp.so/submit`) with the repository URL.
The free path goes through review; there is also a paid "publish
immediately" option, which is not needed.

### Official MCP Registry (`registry.modelcontextprotocol.io`)

Automated. The release workflow builds the MCP Bundle (`make mcpb`), attaches
it to the release, hashes the asset GitHub serves, writes that hash into
`server.json` as `fileSha256`, and publishes with `mcp-publisher` over GitHub
OIDC (no stored token). Before tagging a release, set `version` and the
`.mcpb` URL in `server.json` to the new version; the workflow refuses to run
if they do not match `Version.swift`. A version can be published to the
registry only once.

### Smithery

Smithery is aimed at servers it can install or host for the user, and expects
its own config file. Skip it unless an MCPB or similar package exists.
