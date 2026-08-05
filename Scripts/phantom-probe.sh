#!/bin/bash
# Which window is under the outline the user cannot see?
#
# Two halves that have so far been run separately, and neither settles it alone:
#
#   - `ghost-window-probe.swift` says what appeared, where, and how much of it
#     was actually drawn — but not what the picker did with it.
#   - DuoShot's own `Log.overlay` debug stream says which window the pointer
#     resolved to — but only by name, and an app can own several windows.
#
# Measured 2026-08-05, that gap is exactly what was missing: `hover 1591,151 ->
# Surge` while the two Surge windows on record covered neither that x nor that y.
# So there is a third one, invisible, and only a simultaneous reading names it.
#
# Both are wall-clock stamped so the two logs interleave.
#
#   Scripts/phantom-probe.sh [seconds]
#
# Reproduce while it runs: expand the menu, press the capture hotkey, put the
# pointer on the empty outline and LEAVE IT THERE. Do not press Escape — the
# phantom is gone the moment the overlay is.

set -u
SECONDS_TO_RUN="${1:-30}"
OUT="${TMPDIR:-/tmp}/phantom-probe"
mkdir -p "$OUT"

log stream --style compact --level debug \
    --predicate 'subsystem == "com.boli.duoshot" AND category == "overlay"' \
    > "$OUT/overlay.log" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null' EXIT

# Layer floor 0: the last run ruled out "it is something above the app range",
# so nothing is assumed about where this window lives.
swift "$(dirname "$0")/ghost-window-probe.swift" "$SECONDS_TO_RUN" 0 \
    | tee "$OUT/windows.log"

kill $LOG_PID 2>/dev/null
sleep 0.3

echo
echo "=== picker: hovers and drops, same clock ==="
grep -E "hover|picker (loaded|dropped|re-ranked)" "$OUT/overlay.log" \
    | sed 's/.*\[com.boli.duoshot:overlay\] //' \
    | tail -50
echo
echo "full logs: $OUT"
