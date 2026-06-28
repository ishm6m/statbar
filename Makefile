# StatBar build pipeline.
#
#   make            assemble build/StatBar.app + ad-hoc re-sign (local launch)
#   make run        build the above, then launch it
#   make beta       local build, verify, versioned + checksummed zip for testers
#   make release    Developer ID signed + notarized .app/.dmg (needs DEV_ID etc.)
#   make clean      remove build artifacts
#
# `make` (the local target) re-runs whenever anything that goes INTO the bundle
# changes — sources, Info.plist, entitlements, resources — and ALWAYS finishes
# by re-signing via scripts/resign_local.sh. Developers never hand-resign.

APP    := build/StatBar.app
STAMP  := build/.statbar.signed
SOURCES := $(shell find Sources -type f) \
           $(shell find Resources -type f) \
           Info.plist StatBar.entitlements Package.swift

.PHONY: app run beta release clean
.DEFAULT_GOAL := app

app: $(STAMP)

# The stamp tracks the last successful assemble+resign. If any bundle input is
# newer than the stamp, rebuild and re-sign, then refresh the stamp.
$(STAMP): $(SOURCES)
	scripts/build_local.sh
	@mkdir -p build && touch $(STAMP)

run: app
	open "$(APP)"

# Beta artifact for testers: local build, hard-verify the signature, then hand
# off to package_beta.sh (versioned name, SHA-256 sidecar, round-trip verify).
# Separate recipe lines so fail-fast applies — any failure aborts non-zero.
beta:
	scripts/build_local.sh
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	scripts/package_beta.sh

release:
	scripts/build_release.sh

clean:
	rm -rf build/StatBar.app build/StatBar.dmg build/StatBar-v*.zip build/StatBar-v*.zip.sha256 build/StatBar.app.zip $(STAMP)
