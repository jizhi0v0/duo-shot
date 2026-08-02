APP_NAME  := DuoShot
BUNDLE_ID := com.boli.duoshot
TEAM_ID   := RS59HDH7Y3
SIGN_ID   := Developer ID Application: BO LI ($(TEAM_ID))
CONFIG    ?= release
MACOS_MIN ?= 26.0
NOTARY_PROFILE ?= DuoShot

APP       := build/$(APP_NAME).app
CONTENTS  := $(APP)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RES_DIR   := $(CONTENTS)/Resources
EXEC      := $(MACOS_DIR)/$(APP_NAME)
UNIVERSAL_EXEC := build/universal/$(APP_NAME)
ARM64_SCRATCH  := .build/universal-arm64
X86_64_SCRATCH := .build/universal-x86_64
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

.PHONY: all build universal bundle sign dr-check verify run launch logs selftest mic-check install dist clean help

all: verify

help:
	@echo "make build     - swift build ($(CONFIG))"
	@echo "make universal - build arm64 + x86_64 and merge them (dist only)"
	@echo "make bundle    - assemble build/$(APP_NAME).app from this machine's slice"
	@echo "make sign      - codesign with Developer ID"
	@echo "make verify    - assert the Designated Requirement has not drifted (guards TCC)"
	@echo "make run       - verify, then exec the inner binary with stdout attached"
	@echo "make launch    - verify, then 'open' the .app via LaunchServices"
	@echo "make selftest  - headless capture checks"
	@echo "make logs      - stream os_log for $(BUNDLE_ID)"
	@echo "make install   - copy to /Applications, restarting a running instance"
	@echo "make dist      - sign, notarize, staple, validate and zip"
	@echo "make check-26  - compile against an older macOS SDK on $(CHECK_HOST)"
	@echo "make share-check - typecheck + test the share Worker (needs node)"
	@echo "make share-selftest - run the app's share pipeline against a local wrangler dev"

build:
	swift build -c $(CONFIG)

# SwiftPM builds one target triple at a time. A released app has to carry both
# slices while macOS 26 still runs on Intel Macs, so build into isolated scratch
# directories and merge only the executable that goes into the bundle.
universal:
	@set -eu; \
	ARM_TRIPLE="arm64-apple-macosx$(MACOS_MIN)"; \
	INTEL_TRIPLE="x86_64-apple-macosx$(MACOS_MIN)"; \
	swift build -c $(CONFIG) --triple "$$ARM_TRIPLE" --scratch-path "$(ARM64_SCRATCH)"; \
	swift build -c $(CONFIG) --triple "$$INTEL_TRIPLE" --scratch-path "$(X86_64_SCRATCH)"; \
	ARM_BIN="$$(swift build -c $(CONFIG) --triple "$$ARM_TRIPLE" \
		--scratch-path "$(ARM64_SCRATCH)" --show-bin-path)/$(APP_NAME)"; \
	INTEL_BIN="$$(swift build -c $(CONFIG) --triple "$$INTEL_TRIPLE" \
		--scratch-path "$(X86_64_SCRATCH)" --show-bin-path)/$(APP_NAME)"; \
	test -x "$$ARM_BIN"; test -x "$$INTEL_BIN"; \
	mkdir -p "$$(dirname "$(UNIVERSAL_EXEC)")"; \
	lipo -create "$$ARM_BIN" "$$INTEL_BIN" -output "$(UNIVERSAL_EXEC)"; \
	lipo "$(UNIVERSAL_EXEC)" -verify_arch arm64 x86_64; \
	echo "universal $$(lipo -archs "$(UNIVERSAL_EXEC)")"

# --- bundle ------------------------------------------------------------------
# Assembled by hand on purpose. No SwiftPM resources anywhere in this project:
# .process()/.copy() would emit DuoShot_DuoShot.bundle, which is nested code and
# must be signed inside-out. Not worth it for one .icns.
#
# Bundles this machine's own slice. `dist` overrides both variables below to
# bundle the lipo'd binary instead -- deliberately, because the second slice
# costs a second full compile and `make verify` is the innermost loop in this
# project. It runs dozens of times a day and not one of those runs is a release.
BUNDLE_DEPS ?= build
BUNDLE_EXEC ?= $$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)

bundle: $(BUNDLE_DEPS)
	@set -eu; \
	BIN="$(BUNDLE_EXEC)"; \
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
# Factored out of `verify` because it has to run twice on a release: `dist`
# signs a second time, with --timestamp, which is a different codesign
# invocation from the one `verify` checked. The build that actually ships is
# the last one that should be taken on trust.
dr-check:
	@codesign --verify --strict --verbose=2 "$(APP)" 2>&1 | sed 's/^/  /'
	@codesign -d -r- "$(APP)" 2>/dev/null > build/actual-requirements.txt
	@if diff -u Resources/expected-requirements.txt build/actual-requirements.txt; then \
		echo "  DR stable: $$(cat build/actual-requirements.txt)"; \
	else \
		echo "!! Designated Requirement drifted -- the TCC grant WILL be lost."; \
		exit 1; \
	fi

verify: sign dr-check
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

# Batch repro for the intermittent microphone-recording failure. See the script;
# a single run proves nothing, which is the whole reason it exists.
.PHONY: mic-repro
mic-repro: verify
	@Scripts/mic-recording-repro.sh $${RUNS:-10} $${TAKE:-5}

# --- cross-SDK build check ----------------------------------------------------
# Compiles the source against an OLDER macOS SDK on another Mac.
#
# Not a nicety. `Info.plist` sets a 26.0 minimum, but this machine builds with
# Xcode beta and the 27 SDK, so anything that exists only in 27 compiles here and
# fails for everyone else. `#available` does NOT protect against it -- that is a
# runtime check, and the symbol still has to exist at compile time. Measured
# 2026-07-31: `SCRecordingOutputConfiguration.mixesAudioWithMicrophone` shipped
# guarded by `#available(macOS 27.0, *)` alone and broke the build on a Mac mini
# running 26.5 with Xcode 26. It was found by accident. This makes it a command.
#
# Only `swift build` runs remotely. Signing needs the login keychain, and a
# non-interactive ssh session cannot reach it -- codesign fails with
# errSecInternalComponent. Testing the *behaviour* of an older OS is a separate
# job: sign here, `ditto` the bundle across, and let it inherit the TCC grant,
# which works because the Designated Requirement contains no path and no cdhash.
CHECK_HOST ?= bobby@mac-mini.example.ts.net
CHECK_DIR  ?= ~/duo-shot-sdkcheck

.PHONY: check-26
check-26:
	@echo "syncing to $(CHECK_HOST):$(CHECK_DIR)"
	@rsync -az --delete \
		--exclude '.build' --exclude 'build' --exclude '.git' --exclude 'dist' \
		--exclude 'Worker/node_modules' --exclude 'Worker/.wrangler' \
		./ "$(CHECK_HOST):$(CHECK_DIR)/"
	@echo "remote SDK:"
	@ssh -o BatchMode=yes "$(CHECK_HOST)" \
		'sw_vers -productVersion | sed "s/^/  macOS /"; swift --version 2>&1 | head -1 | sed "s/^/  /"'
	@ssh -o BatchMode=yes "$(CHECK_HOST)" \
		'cd $(CHECK_DIR) && swift build -c $(CONFIG) 2>&1 | grep -E "error:|warning: .*deprecat|Build complete" | head -30'
	@ssh -o BatchMode=yes "$(CHECK_HOST)" 'cd $(CHECK_DIR) && swift build -c $(CONFIG) >/dev/null 2>&1' \
		&& echo "  OK -- builds against the older SDK" \
		|| { echo "  FAILED -- see the errors above"; exit 1; }

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
	fail=0; incon=0; \
	run() { name="$$1"; shift; printf '  %-26s ' "$$name"; \
		if out="$$("$(EXEC)" "$$@" 2>&1)"; then status=""; else status=" [exit $$?]"; fail=1; fi; \
		line="$$(printf '%s\n' "$$out" | grep -E '^(result|verdict)' | head -1 | sed 's/^[a-z]*: *//')"; \
		if [ -z "$$line" ]; then line="$$(printf '%s\n' "$$out" | tail -1)"; fi; \
		case "$$out" in *INCONCLUSIVE*) incon=$$((incon+1));; esac; \
		printf '%s%s\n' "$$line" "$$status"; }; \
	run "sourceRect semantics"   --selftest-sourcerect-space; \
	run "rect pipeline"          --selftest-rect 400,300,640,400; \
	run "overlay exclusion"      --selftest-overlay 400,300,640,400 --sharing-default; \
	run "output pipeline"        --selftest-output $(TEST_OUT); \
	run "preview panel"          --selftest-preview $(TEST_OUT) --sharing-default; \
	run "window mode"            --selftest-window $(TEST_OUT); \
	run "fullscreen menu bar"    --selftest-fullscreen $(TEST_OUT); \
	run "preferences"            --selftest-preferences; \
	run "edit menu (paste)"      --selftest-edit-menu; \
	run "copy text (OCR)"        --selftest-copy-text $(TEST_OUT); \
	run "sensitive text"         --selftest-sensitive $(TEST_OUT); \
	run "selection zones"        --selftest-selection-zones; \
	run "pixel mapping"          --selftest-pixel-mapping; \
	run "latch cancellation"     --selftest-latch-cancel; \
	run "settings window"        --selftest-settings-window $(TEST_OUT); \
	run "settings tab resize"    --selftest-settings-resize; \
	run "overlay lifecycle"      --selftest-lifecycle 10; \
	run "selection toolbar"      --selftest-selection-toolbar; \
	run "overlay sharing"        --selftest-overlay-sharing; \
	run "hud appearance"         --selftest-hud-appearance $(TEST_OUT); \
	run "recording border"       --selftest-region-outline $(TEST_OUT); \
	run "selection loupe"        --selftest-loupe $(TEST_OUT); \
	run "preview stack + scroll" --selftest-preview-stack $(TEST_OUT) --count 14; \
	run "viewer window"          --selftest-viewer $(TEST_OUT); \
	run "image editor"           --selftest-edit $(TEST_OUT); \
	run "recording trim"         --selftest-trim $(TEST_OUT); \
	run "gif export"             --selftest-gif $(TEST_OUT); \
	run "capture history"        --selftest-history $(TEST_OUT); \
	run "recording area"         --selftest-record $(TEST_OUT) --seconds 2 --rect 400,300,640,400; \
	run "recording fullscreen"   --selftest-record $(TEST_OUT) --seconds 2; \
	run "hud recorded (readOnly)" --selftest-record-hud $(TEST_OUT) --seconds 2; \
	run "hud absent (.none)"     --selftest-record-hud $(TEST_OUT) --seconds 2 --sharing-none; \
	run "plain window recorded"  --selftest-record-hud $(TEST_OUT) --seconds 2 --plain-window --hud-first; \
	run "excluded by window ID"  --selftest-record-hud $(TEST_OUT) --seconds 2 --plain-window --hud-first --exclude-ids; \
	run "card kept out of take"  --selftest-preview-in-recording $(TEST_OUT) --seconds 3; \
	run "card leaks unexcluded"  --selftest-preview-in-recording $(TEST_OUT) --seconds 3 --no-exclude; \
	run "menu-bar item recorded" --selftest-record-hud $(TEST_OUT) --seconds 2 --status-item --hud-first; \
	run "recording flow"         --selftest-record-flow $(TEST_OUT) --seconds 2; \
	run "scroll stitcher"        --selftest-scroll-stitch $(TEST_OUT); \
	run "scroll capture flow"    --selftest-scroll-flow $(TEST_OUT); \
	printf '  %-26s ' "exclusion negative control"; \
	if "$(EXEC)" --selftest-overlay 400,300,640,400 --sharing-default --no-exclude >/dev/null 2>&1; \
		then echo "BROKEN — the control passed, so the exclusion test cannot fail"; fail=1; \
		else echo "fails as required"; fi; \
	printf '  %-26s ' "stitcher negative control"; \
	if "$(EXEC)" --selftest-scroll-stitch $(TEST_OUT) --broken >/dev/null 2>&1; \
		then echo "BROKEN — the control passed, so the stitch test cannot fail"; fail=1; \
		else echo "fails as required"; fi; \
	echo; \
	if [ $$incon -gt 0 ]; then \
		echo "  $$incon inconclusive — those asserted nothing; re-run with a still screen"; fi; \
	if [ $$fail -eq 0 ]; then echo "  all green"; else echo "  FAILURES"; exit 1; fi

.PHONY: soak
soak: verify
	@"$(EXEC)" --selftest-soak $${N:-500}

# --- share backend ------------------------------------------------------------
# The Worker in Worker/. Deliberately NOT part of `make test`: that target is
# offline, has no toolchain but Swift, and must stay runnable on a machine with
# no node installed. This one needs `npm install --prefix Worker` first.
#
# The suite itself is still offline -- it runs the real Worker in workerd
# against miniflare's local R2, so it costs nothing and touches no bucket.
.PHONY: share-check
share-check:
	@npm --prefix Worker run typecheck
	@npm --prefix Worker test

# The Swift side of sharing, against the real Worker.
#
# Starts `wrangler dev` (workerd + miniflare's local R2), points the app's
# self-test at it, tears it down. Offline, costs nothing, touches no bucket --
# and it is the same Worker code that gets deployed, not a mock.
#
# Worker/.dev.vars must override PUBLIC_BASE to the loopback address. Without
# that the Worker correctly returns links built from the *production* domain --
# it must, since it also serves on workers.dev -- and every download assertion
# fails against a host that is not this one. Cost half an hour on 2026-08-01.
.PHONY: share-selftest
share-selftest: build
	@set -eu; \
	if [ ! -f Worker/.dev.vars ]; then \
		printf 'UPLOAD_TOKEN="local-dev-token"\nPUBLIC_BASE="http://127.0.0.1:8787"\n' > Worker/.dev.vars; \
		echo "  wrote Worker/.dev.vars"; \
	fi; \
	pkill -f "wrangler dev" 2>/dev/null || true; \
	(cd Worker && WRANGLER_SEND_METRICS=false npx wrangler dev --port 8787 >/tmp/duoshot-wrangler-dev.log 2>&1 &) ; \
	trap 'pkill -f "wrangler dev" 2>/dev/null || true' EXIT; \
	curl -s --retry-connrefused --retry 40 --retry-delay 1 -o /dev/null http://127.0.0.1:8787/ || \
		{ echo "wrangler dev did not come up:"; tail -20 /tmp/duoshot-wrangler-dev.log; exit 1; }; \
	"$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" \
		--selftest-share --endpoint http://127.0.0.1:8787 --token local-dev-token

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug --style compact

# Replaces the bundle AND whatever is running from it.
#
# Copying over the bundle does not touch the live process, which goes on serving
# the hotkeys out of the code that was just replaced. There is nothing on screen
# to say so — the next screenshot simply behaves like the old build, which reads
# as the change not working rather than as the app not having been restarted.
# Cost a debugging round trip on 2026-08-01.
#
# `osascript` first so a take in progress is finalised rather than truncated;
# `killall` is the backstop for a hung or unresponsive instance. `killall`
# matches on the process name, so unlike `pkill -f` it cannot match the shell
# running this recipe. Both are best-effort: not running is the normal case.
install: verify
	@osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null || true
	@sleep 1
	@killall $(APP_NAME) 2>/dev/null && echo "stopped a running instance" || true
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@open -a "/Applications/$(APP_NAME).app"
	@echo "installed and relaunched /Applications/$(APP_NAME).app"

# One-time setup on a release machine:
#   xcrun notarytool store-credentials DuoShot
# Override the profile name with `make dist NOTARY_PROFILE=...`.
dist:
	@$(MAKE) verify BUNDLE_DEPS=universal BUNDLE_EXEC='$(UNIVERSAL_EXEC)'
	@codesign --force \
		--sign "$(SIGN_ID)" \
		--identifier $(BUNDLE_ID) \
		--options runtime \
		--entitlements $(ENTITLEMENTS) \
		--timestamp \
		"$(APP)"
	@$(MAKE) dr-check
	@mkdir -p dist
	@rm -f "dist/$(APP_NAME)-submit.zip" "dist/$(APP_NAME).zip"
	@ditto -c -k --keepParent "$(APP)" "dist/$(APP_NAME)-submit.zip"
	@xcrun notarytool submit "dist/$(APP_NAME)-submit.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(APP)"
	@xcrun stapler validate "$(APP)"
	@spctl --assess --type execute --verbose=2 "$(APP)"
	@ditto -c -k --keepParent "$(APP)" "dist/$(APP_NAME).zip"
	@rm -f "dist/$(APP_NAME)-submit.zip"
	@echo "notarized dist/$(APP_NAME).zip"

clean:
	rm -rf .build build dist
