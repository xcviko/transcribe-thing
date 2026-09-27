# transcribe-thing: SwiftPM -> build/transcribe-thing.app
#   make app            release bundle, signed with SIGN_IDENTITY (see below)
#   make run            build and launch through LaunchServices
#   make install        copy the bundle to /Applications
#   make release VERSION=x.y.z   signed zip + draft notes in dist/; prints (never runs) the publish commands
CONFIG        ?= release
APP           := build/transcribe-thing.app
BUNDLE_ID     := dev.transcribe-thing.app
INSTALL_DIR   ?= /Applications
SNAPSHOT_DIR  ?= build/snapshots
# The stable self-signed certificate from the README when the keychain has it, else ad-hoc ("-"). Matched by
# name, not with `-v`: a self-signed root is never "valid" (CSSMERR_TP_NOT_TRUSTED), yet codesign uses it fine.
# Evaluated only by the targets that sign.
SIGN_CERT     := transcribe-thing Developer
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -qF '"$(SIGN_CERT)"' && echo '$(SIGN_CERT)' || echo -)

.PHONY: all build app run run-log install uninstall release sounds icon test snapshots reset-tcc clean

all: app

build:
	swift build -c $(CONFIG)

app:
	SIGN_IDENTITY='$(SIGN_IDENTITY)' ./scripts/build-app.sh $(CONFIG)

# Through `open` so macOS attributes permission prompts to transcribe-thing, not to the terminal.
run: app
	-pkill -x transcribe-thing; sleep 0.3
	open $(APP)

# Same, with transcribe-thing's stdout/stderr in this terminal.
run-log: app
	-pkill -x transcribe-thing; sleep 0.3
	open -W --stdout $$(tty) --stderr $$(tty) $(APP)

install: app
	-pkill -x transcribe-thing; sleep 0.3
	rm -rf "$(INSTALL_DIR)/transcribe-thing.app"
	ditto $(APP) "$(INSTALL_DIR)/transcribe-thing.app"
	@echo "Installed $(INSTALL_DIR)/transcribe-thing.app"

uninstall:
	-pkill -x transcribe-thing
	rm -rf "$(INSTALL_DIR)/transcribe-thing.app"

# Never pushes or publishes: scripts/release.sh prints the git push and gh release create commands to run yourself.
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 64; }
	SIGN_IDENTITY='$(SIGN_IDENTITY)' ./scripts/release.sh $(VERSION)

sounds:
	python3 scripts/gen-sounds.py Resources/Sounds
	python3 scripts/analyze-sounds.py Resources/Sounds

icon:
	swift scripts/gen-icon.swift Resources

test:
	swift test

# ONLY=<prefix> and APPEARANCE=light|dark narrow the set.
snapshots:
	swift build
	"$$(swift build --show-bin-path)/transcribe-thing" --snapshots $(SNAPSHOT_DIR) $(if $(ONLY),--only $(ONLY)) $(if $(APPEARANCE),--appearance $(APPEARANCE))

# Ad-hoc rebuilds change the code hash, so macOS stops honoring old Accessibility grants (a stable certificate avoids it).
reset-tcc:
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset Microphone $(BUNDLE_ID)
	-tccutil reset ListenEvent $(BUNDLE_ID)

clean:
	rm -rf build
	swift package clean
