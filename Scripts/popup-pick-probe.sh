#!/bin/bash
# Why does the popup lose the hover to the window behind it?
#
# It is offered — the highlight lands on it for a moment — and then something
# takes it away. Two candidates, and they need different fixes:
#
#   E. the popup dismisses, so the re-enumeration drops it and the hover falls
#      through to whatever is behind (the picker re-enumerates every ~0.5 s), or
#   F. the popup is still on screen and the picker demotes it — a re-rank every
#      120 ms puts a bigger window in front of it.
#
# Runs two instruments against one wall clock: the window server's own view of
# the panel (is it still there, at what alpha) and DuoShot's `Log.overlay`
# stream, which names every window the picker drops and the rule that dropped it.
#
#   Scripts/popup-pick-probe.sh [seconds]
#
# Open the popup, press the window-capture hotkey, and hold the pointer over the
# popup until the highlight jumps to the window behind it.

set -u
SECONDS_TO_RUN="${1:-45}"
OUT="${TMPDIR:-/tmp}/popup-pick-probe"
mkdir -p "$OUT"

log stream --style compact --level debug \
    --predicate 'subsystem == "com.boli.duoshot" AND category == "overlay"' \
    > "$OUT/overlay.log" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null' EXIT

swift "$(dirname "$0")/popup-layer-probe.swift" DuoUpdater "$SECONDS_TO_RUN" \
    | tee "$OUT/windows.log"

kill $LOG_PID 2>/dev/null
sleep 0.3

echo
echo "=== picker log (hover changes, loads and drops) ==="
grep -E "hover|picker (loaded|dropped|re-ranked)" "$OUT/overlay.log" | tail -60
echo
echo "full logs: $OUT"
