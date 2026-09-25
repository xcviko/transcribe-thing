# Murmur: SwiftPM -> build/Murmur.app
#   make app            release bundle, signed (ad-hoc unless SIGN_IDENTITY is set)
#   make run            build and launch through LaunchServices
#   make install        copy the bundle to /Applications
CONFIG        ?= release
APP           := build/Murmur.app
BUNDLE_ID     := dev.murmur.app
INSTALL_DIR   ?= /Applications
SNAPSHOT_DIR  ?= build/snapshots

.PHONY: all build app run run-log install uninstall sounds icon test snapshots reset-tcc clean

all: app

build:
	swift build -c $(CONFIG)

app:
	./scripts/build-app.sh $(CONFIG)

# Through `open` so macOS attributes permission prompts to Murmur, not to the terminal.
run: app
	-pkill -x Murmur; sleep 0.3
	open $(APP)

# Same, with Murmur's stdout/stderr in this terminal.
run-log: app
	-pkill -x Murmur; sleep 0.3
	open -W --stdout $$(tty) --stderr $$(tty) $(APP)

install: app
	-pkill -x Murmur; sleep 0.3
	rm -rf "$(INSTALL_DIR)/Murmur.app"
	ditto $(APP) "$(INSTALL_DIR)/Murmur.app"
	@echo "Installed $(INSTALL_DIR)/Murmur.app"

uninstall:
	-pkill -x Murmur
	rm -rf "$(INSTALL_DIR)/Murmur.app"

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
	"$$(swift build --show-bin-path)/Murmur" --snapshots $(SNAPSHOT_DIR) $(if $(ONLY),--only $(ONLY)) $(if $(APPEARANCE),--appearance $(APPEARANCE))

# Ad-hoc rebuilds change the code hash, so macOS stops honoring old Accessibility grants.
reset-tcc:
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset Microphone $(BUNDLE_ID)
	-tccutil reset ListenEvent $(BUNDLE_ID)

clean:
	rm -rf build
	swift package clean
