# Contributing to banktivity-mcp

Thanks for your interest in contributing! This document covers the basics for getting started.

## Getting Started

1. Fork the repository and clone your fork
2. Build the project: `swift build`
3. Make your changes on a feature branch

## Development Setup

- **macOS 14+** and **Swift 6.0+** are required
- The only external dependency is the [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- Running tests requires Xcode installed (the Testing framework isn't available in Command Line Tools alone) — see the test command in [AGENTS.md](AGENTS.md)
- Integration tests require a Banktivity `.bank8` vault file and will skip gracefully if one isn't available

## Making Changes

### Before You Start

- For bug fixes, open an issue first describing the problem
- For new features or significant changes, open an issue to discuss the approach before writing code

### Code Style

- Follow existing patterns in the codebase — KVC access on `NSManagedObject`, repository pattern, tool registration via `ToolRegistry`
- All new source files should include the copyright header: `// Copyright (c) 2026 Steve Flinter. MIT License.`
- Keep tools self-contained: each tool's handler should validate its own inputs and return structured JSON responses via `ToolHelpers`

### Critical Constraints

If you're modifying Core Data or repository code, be aware of these constraints that exist to prevent vault corruption:

- **Never enable `NSPersistentHistoryTrackingKey`** — Banktivity uses its own sync mechanism and doesn't recognise the metadata Core Data's history tracking adds
- **Handle null-account line items** — Transactions can have orphaned line items with no `pAccount`; write operations must account for these
- **All write tools must check `WriteGuard`** before making mutations

### Testing

- Add tests for new functionality where possible
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`)
- Integration tests that need a vault file should return early (not fail) if the fixture is unavailable

## Pull Requests

1. Keep PRs focused — one feature or fix per PR
2. Include a clear description of what changed and why
3. Ensure `swift build` succeeds with no errors
4. Run the test suite if you have a test vault available

## Reporting Issues

When reporting bugs, include:

- What you were trying to do
- The tool name and arguments (if applicable)
- Any error messages from the MCP server (stderr output)
- Your macOS and Swift versions

## License

See [LICENSE](LICENSE): the repository is MIT up to commit `9bcd5d2` and
PolyForm Noncommercial 1.0.0 for the maintainer's later work, with commercial
licenses available from the maintainer.

By submitting a contribution, you license it to david00769 under the MIT
License. That lets it be distributed under this repository's licenses,
including the PolyForm Noncommercial License and commercial licenses
david00769 grants. You confirm that you have the right to do so. If you want
your change to stay under MIT only, say so in the pull request; it will then
be marked as MIT.
