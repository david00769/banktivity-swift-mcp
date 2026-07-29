# Prefer full Xcode when it is installed (keeps one toolchain across builds and
# avoids cache invalidation), but fall back to whatever xcode-select points at.
# Hardcoding the Xcode path made EVERY target fail on a CommandLineTools-only host
# ("xcrun: error: missing DEVELOPER_DIR path"), which pushed the install off the
# Makefile and onto a hand-rolled `swift build && cp` — the unsafe in-place copy
# that caused the 2026-07-28 banktivity outage. Keep this fallback working.
XCODE_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
DEVELOPER_DIR := $(shell [ -d $(XCODE_DEVELOPER_DIR) ] && echo $(XCODE_DEVELOPER_DIR) || xcode-select -p)

# Framework/SDK layout differs between full Xcode and CommandLineTools; only the
# `test` target needs these, so resolve them per-toolchain and let them be empty
# when neither layout matches.
XCODE_SDK := $(shell xcrun --show-sdk-path 2>/dev/null)
XCODE_FRAMEWORKS := $(firstword $(wildcard \
  $(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  $(DEVELOPER_DIR)/Library/Frameworks))

# $(HOME), not ~ — the install rules quote this path, and a quoted tilde is not expanded.
INSTALL_DIR := $(HOME)/.local/bin
VERSION := $(shell grep 'public let version' Sources/BanktivityLib/Version.swift | sed 's/.*"\(.*\)"/\1/')

export DEVELOPER_DIR

.PHONY: build test release install install-fast _install-from verify clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Debug build
	swift build

release: ## Universal release build (arm64 + x86_64)
	swift build -c release --arch arm64 --arch x86_64

test: ## Run all tests
	swift build --product banktivity-cli
	SDKROOT=$(XCODE_SDK) \
	DYLD_FRAMEWORK_PATH=$(XCODE_FRAMEWORKS) \
	swift test -c release \
	  --no-parallel \
	  -Xswiftc -F -Xswiftc $(XCODE_FRAMEWORKS) \
	  -Xlinker -rpath -Xlinker $(XCODE_FRAMEWORKS)

test-filter: ## Run filtered tests (usage: make test-filter FILTER=TurtleWriter)
	swift build --product banktivity-cli
	SDKROOT=$(XCODE_SDK) \
	DYLD_FRAMEWORK_PATH=$(XCODE_FRAMEWORKS) \
	swift test -c release --filter '$(FILTER)' \
	  --no-parallel \
	  -Xswiftc -F -Xswiftc $(XCODE_FRAMEWORKS) \
	  -Xlinker -rpath -Xlinker $(XCODE_FRAMEWORKS)

# NEVER `cp` directly over a binary in $(INSTALL_DIR).
#
# banktivity-mcp is a long-lived stdio server: Paperclip agent runs leave copies
# resident for hours. `cp` opens the destination O_TRUNC and rewrites it IN PLACE,
# so if any running process still has that inode mapped, the kernel's code-signing
# state for the vnode goes inconsistent and EVERY later exec is SIGKILLed
# (EXC_CRASH / SIGKILL (Code Signature Invalid), termination namespace CODESIGNING).
#
# This is exactly what happened 2026-07-28: two servers from 11:02 and 11:19 were
# still resident when 11:26 cp'd a new build over them. The bytes were fine — the
# same build ran correctly straight out of .build/release and from a copy — but the
# installed path was killed at exec for the next 10 hours. `codesign --verify` said
# "valid on disk" throughout, so every signature check looked clean while every
# Paperclip agent silently lost the banktivity MCP.
#
# install-to-temp + `mv` is a rename(2): atomic, allocates a NEW inode, and leaves
# already-running servers on the old one where they belong. Sign the temp file
# BEFORE the rename so what lands is signed the moment it is visible.
install: release ## Build universal release and install to ~/.local/bin (atomic, signed, verified)
	@$(MAKE) --no-print-directory _install-from BIN=.build/apple/Products/Release
	@echo "Installed v$(VERSION) to $(INSTALL_DIR)"

install-fast: ## Fast native-arch build + install to ~/.local/bin (atomic, signed, verified)
	swift build -c release
	@$(MAKE) --no-print-directory _install-from BIN="$$(swift build -c release --show-bin-path)"
	@echo "Installed v$(VERSION) (native arch) to $(INSTALL_DIR)"

# Internal: atomically install + sign both binaries from $(BIN).
_install-from:
	@set -e; \
	for b in banktivity-cli banktivity-mcp; do \
	  cp "$(BIN)/$$b" "$(INSTALL_DIR)/$$b.new"; \
	  codesign -fs - "$(INSTALL_DIR)/$$b.new"; \
	  mv -f "$(INSTALL_DIR)/$$b.new" "$(INSTALL_DIR)/$$b"; \
	done
	@$(MAKE) --no-print-directory verify

# Proves the installed binaries actually EXECUTE — the only check that catches the
# in-place-overwrite failure described above. File-exists, +x, and `codesign --verify`
# all pass on a binary the kernel refuses to run. Exit 137 == 128+SIGKILL.
verify: ## Verify installed binaries exec (catches the invalid-signature SIGKILL)
	@fail=0; \
	for b in banktivity-cli banktivity-mcp; do \
	  $(INSTALL_DIR)/$$b --version >/dev/null 2>&1 </dev/null; rc=$$?; \
	  if [ $$rc -eq 137 ]; then \
	    echo "  FAIL  $$b: SIGKILLed at exec (invalid code signature)"; \
	    echo "        fix: codesign -fs - $(INSTALL_DIR)/$$b"; \
	    fail=1; \
	  else \
	    echo "  ok    $$b: execs (exit $$rc)"; \
	  fi; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "verify: binaries exec cleanly"

package: release ## Build release and create tarball
	cd .build/apple/Products/Release && \
	codesign -fs - banktivity-cli && \
	codesign -fs - banktivity-mcp && \
	tar czf /tmp/banktivity-swift-mcp-v$(VERSION)-macos-universal.tar.gz banktivity-cli banktivity-mcp
	@echo "Package: /tmp/banktivity-swift-mcp-v$(VERSION)-macos-universal.tar.gz"
	@shasum -a 256 /tmp/banktivity-swift-mcp-v$(VERSION)-macos-universal.tar.gz

clean: ## Remove build artifacts
	rm -rf .build
