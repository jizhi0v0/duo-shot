APP_NAME  := DuoShot
BUNDLE_ID := com.boli.duoshot
TEAM_ID   := RS59HDH7Y3
SIGN_ID   := Developer ID Application: BO LI ($(TEAM_ID))
CONFIG    ?= release

APP       := build/$(APP_NAME).app
CONTENTS  := $(APP)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RES_DIR   := $(CONTENTS)/Resources
EXEC      := $(MACOS_DIR)/$(APP_NAME)
# Hardened Runtime denies the microphone outright, with NO prompt, unless the
# binary claims com.apple.security.device.audio-input. Measured 2026-07-31:
# --selftest-microphone reported `before=not determined after=denied` on a
# launchd-parented launch, i.e. attribution was already correct and the
# entitlement was the whole story. NSMicrophoneUsageDescription is necessary but
# not sufficient -- it only supplies the prompt's text.
#
# Every signing target must pass this: an unentitled re-sign silently breaks
# recording audio again, and the failure looks like a TCC problem, not a signing
# one. Entitlements do not participate in the Designated Requirement, so this
# cannot cost the screen-recording grant -- `verify` is the assertion.
#
# Keep the file comment-free. AMFI's plist parser is not plutil's: a comment
# anywhere in it fails the sign with "AMFIUnserializeXML: syntax error".
ENTITLEMENTS := Resources/DuoShot.entitlements

.PHONY: all build bundle sign verify run launch logs selftest mic-check install dist clean help

all: verify

help:
	@echo "make build     - swift build ($(CONFIG))"
	@echo "make bundle    - assemble build/$(APP_NAME).app"
	@echo "make sign      - codesign with Developer ID"
	@echo "make verify    - assert the Designated Requirement has not drifted (guards TCC)"
	@echo "make run       - verify, then exec the inner binary with stdout attached"
	@echo "make launch    - verify, then 'open' the .app via LaunchServices"
	@echo "make selftest  - headless capture checks"
	@echo "make logs      - stream os_log for $(BUNDLE_ID)"
	@echo "make install   - copy to /Applications"
	@echo "make dist      - notarization-ready build (real timestamp) + zip"

build:
	swift build -c $(CONFIG)

# --- bundle ------------------------------------------------------------------
# Assembled by hand on purpose. No SwiftPM resources anywhere in this project:
# .process()/.copy() would emit DuoShot_DuoShot.bundle, which is nested code and
# must be signed inside-out. Not worth it for one .icns.
bundle: build
	@set -eu; \
	BIN="$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)"; \
	test -x "$$BIN" || { echo "missing product: $$BIN"; exit 1; }; \
	rm -rf "$(APP)"; \
	mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"; \
	cp "$$BIN" "$(EXEC)"; \
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"; \
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"; \
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(RES_DIR)/"; fi; \
	plutil -replace CFBundleVersion -string "$$(date +%Y%m%d%H%M)" "$(CONTENTS)/Info.plist"; \
	plutil -lint "$(CONTENTS)/Info.plist" >/dev/null; \
	echo "bundled $(APP)"

# --- signing -----------------------------------------------------------------
# --identifier is passed explicitly so the Designated Requirement can never drift
# on an Info.plist parse hiccup. --timestamp=none for the dev loop: the timestamp
# needs a network round-trip and does NOT participate in the DR, so it cannot
# affect TCC. `make dist` uses a real timestamp.
sign: bundle
	@codesign --force \
		--sign "$(SIGN_ID)" \
		--identifier $(BUNDLE_ID) \
		--options runtime \
		--entitlements $(ENTITLEMENTS) \
		--timestamp=none \
		"$(APP)"
	@echo "signed $(APP)"

# --- the target that actually protects the TCC grant -------------------------
# The screen-recording grant is keyed on the Designated Requirement. For a
# Developer ID signature the DR contains no cdhash, so it is byte-identical
# across rebuilds -- and that invariant IS the test. Build twice and diff.
verify: sign
	@codesign --verify --strict --verbose=2 "$(APP)" 2>&1 | sed 's/^/  /'
	@codesign -d -r- "$(APP)" 2>/dev/null > build/actual-requirements.txt
	@if diff -u Resources/expected-requirements.txt build/actual-requirements.txt; then \
		echo "  DR stable: $$(cat build/actual-requirements.txt)"; \
	else \
		echo "!! Designated Requirement drifted -- the TCC grant WILL be lost."; \
		exit 1; \
	fi
	@otool -l "$(EXEC)" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print "  minos " $$2; exit}'

# --- running -----------------------------------------------------------------
# Run the INNER binary for the dev loop: stdout/stderr stay attached, so crashes
# and print() are immediately visible, and Bundle.main still resolves to the .app.
#
# CAVEAT, measured on this machine: TCC attributes a shell-spawned process to its
# responsible *ancestor*. Launched from a terminal whose parent app already holds
# Screen Recording, this binary reports `granted`; the identical bundle launched
# via LaunchServices reports `denied`. So `make run` is for iterating on code --
# never for deciding whether DuoShot itself holds the grant. Use `make tcc-check`.
run: verify
	@echo "--- $(EXEC) ---"
	@"$(EXEC)"

launch: verify
	open "$(APP)"

# The honest TCC test: LaunchServices launch (parent is launchd, so DuoShot is
# its own responsible process), result read back out of os_log.
#
# `-n` is required. Without it `open` reuses an already-running instance and
# silently drops --args, so you keep reading a stale log line and think it passed.
tcc-check: verify
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@open -n -a "$(CURDIR)/$(APP)" --args --selftest-permission
	@sleep 3
	@/usr/bin/log show --predicate 'subsystem == "$(BUNDLE_ID)"' --last 15s --info --debug --style compact 2>/dev/null \
		| grep selftest-permission | tail -1 | sed 's/^/  /' \
		| grep . || echo "  FAIL: no log entry in the last 15s -- the app did not launch"

# The microphone grant, asked for the only way that works.
#
# Same attribution rule as tcc-check, and it bites harder here: measured
# 2026-07-31, a shell-launched request put the prompt in front of the terminal's
# ancestor process instead of the user, and SCStream.startCapture with
# captureMicrophone = true then hung forever waiting on an answer nobody could
# give. Launch via LaunchServices so the prompt says DuoShot.
mic-check: verify
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@open -n -a "$(CURDIR)/$(APP)" --args --selftest-microphone
	@echo "  answer the microphone prompt if one appears, then:"
	@sleep 8
	@/usr/bin/log show --predicate 'subsystem == "$(BUNDLE_ID)"' --last 20s --info --debug --style compact 2>/dev/null \
		| grep selftest-microphone | tail -1 | sed 's/^/  /' \
		| grep . || echo "  FAIL: no log entry in the last 20s -- the app did not launch"

selftest: verify
	@"$(EXEC)" --selftest-permission || true
	@"$(EXEC)" --selftest-capture build/selftest-fullscreen.png

# The whole regression suite. Every check that can run without a human at the
# mouse.
#
# Pass/fail is the self-test's exit code, full stop. Matching on the printed text
# as well meant two sources of truth that could disagree -- and they did: an
# INCONCLUSIVE run (screen content moving, geometry verified fine) exits 0 but
# failed the string match.
#
# Note every line of the recipe body is backslash-continued into ONE shell
# invocation. A comment line without a trailing backslash silently splits it, and
# shell variables stop surviving across the break. Note two of these deliberately turn off `sharingType = .none`: with it
# on, the panels are invisible to ScreenCaptureKit outright and the exclusion
# assertions cannot fail, so a "pass" would prove nothing.
TEST_OUT := build/selftest-output
.PHONY: test
test: verify
	@mkdir -p $(TEST_OUT)
	@set -e; \
	fail=0; \
	run() { name="$$1"; shift; printf '  %-26s ' "$$name"; \
		if out="$$("$(EXEC)" "$$@" 2>&1)"; then status=""; else status=" [exit $$?]"; fail=1; fi; \
		line="$$(printf '%s\n' "$$out" | grep -E '^result' | head -1 | sed 's/result: *//')"; \
		if [ -z "$$line" ]; then line="$$(printf '%s\n' "$$out" | tail -1)"; fi; \
		printf '%s%s\n' "$$line" "$$status"; }; \
	run "sourceRect semantics"   --selftest-sourcerect-space; \
	run "rect pipeline"          --selftest-rect 400,300,640,400; \
	run "overlay exclusion"      --selftest-overlay 400,300,640,400 --sharing-default; \
	run "output pipeline"        --selftest-output $(TEST_OUT); \
	run "preview panel"          --selftest-preview $(TEST_OUT) --sharing-default; \
	run "window mode"            --selftest-window $(TEST_OUT); \
	run "fullscreen menu bar"    --selftest-fullscreen $(TEST_OUT); \
	run "preferences"            --selftest-preferences; \
	run "settings window"        --selftest-settings-window $(TEST_OUT); \
	run "settings tab resize"    --selftest-settings-resize; \
	run "overlay lifecycle"      --selftest-lifecycle 10; \
	run "preview stack + scroll" --selftest-preview-stack $(TEST_OUT) --count 14; \
	run "recording area"         --selftest-record $(TEST_OUT) --seconds 2 --rect 400,300,640,400; \
	run "recording fullscreen"   --selftest-record $(TEST_OUT) --seconds 2; \
	run "hud recorded (readOnly)" --selftest-record-hud $(TEST_OUT) --seconds 2; \
	run "hud absent (.none)"     --selftest-record-hud $(TEST_OUT) --seconds 2 --sharing-none; \
	run "plain window recorded"  --selftest-record-hud $(TEST_OUT) --seconds 2 --plain-window --hud-first; \
	run "menu-bar item recorded" --selftest-record-hud $(TEST_OUT) --seconds 2 --status-item --hud-first; \
	run "recording flow"         --selftest-record-flow $(TEST_OUT) --seconds 2; \
	printf '  %-26s ' "exclusion negative control"; \
	if "$(EXEC)" --selftest-overlay 400,300,640,400 --sharing-default --no-exclude >/dev/null 2>&1; \
		then echo "BROKEN — the control passed, so the exclusion test cannot fail"; fail=1; \
		else echo "fails as required"; fi; \
	echo; \
	if [ $$fail -eq 0 ]; then echo "  all green"; else echo "  FAILURES"; exit 1; fi

.PHONY: soak
soak: verify
	@"$(EXEC)" --selftest-soak $${N:-500}

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug --style compact

install: verify
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@echo "installed /Applications/$(APP_NAME).app"

dist: bundle
	@codesign --force \
		--sign "$(SIGN_ID)" \
		--identifier $(BUNDLE_ID) \
		--options runtime \
		--entitlements $(ENTITLEMENTS) \
		--timestamp \
		"$(APP)"
	@mkdir -p dist
	@ditto -c -k --keepParent "$(APP)" "dist/$(APP_NAME).zip"
	@echo "dist/$(APP_NAME).zip"
	@echo "On the second Mac, either notarize this or run:"
	@echo "  xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"

clean:
	rm -rf .build build dist
