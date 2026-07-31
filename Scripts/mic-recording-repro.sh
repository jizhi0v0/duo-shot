#!/bin/bash
# Repro harness for the intermittent microphone-recording failure.
#
# Observed 2026-07-31: with `captureMicrophone = true`, `SCRecordingOutput`
# sometimes fails outright --
#
#   writer failed: The operation couldn't be completed.
#   (com.apple.ReplayKit.RPRecordingErrorDomain error -5814.)
#
# -- and sometimes finalises the file seconds early, leaving a take far shorter
# than it should be. Roughly 2 runs in 10 on the first sample, so a single run
# proves nothing in either direction and eyeballing it is hopeless. This runs a
# batch and tallies.
#
# Every launch goes through LaunchServices, not the shell. TCC attributes a
# shell-launched process to its responsible ancestor, and this binary then
# reports the microphone grant as `not determined` and quietly records without
# it -- i.e. the shell-run version of this script would measure nothing at all.
# The output path must be absolute for the same reason: the launched process
# does not reliably inherit this shell's working directory.
#
# Usage:  Scripts/mic-recording-repro.sh [runs] [seconds-per-take]
#         make mic-repro RUNS=20

set -euo pipefail

RUNS="${1:-10}"
SECONDS_PER_TAKE="${2:-5}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DuoShot.app"
OUT="$ROOT/build/mic-repro"
BUNDLE_ID="com.boli.duoshot"
EXEC_NAME="DuoShot.app/Contents/MacOS/DuoShot"

test -x "$APP/Contents/MacOS/DuoShot" || { echo "build it first: make sign"; exit 1; }
mkdir -p "$OUT"

# A take of N seconds plus start latency, finalisation and process teardown.
# Generous on purpose: cutting a run short would be scored as a failure and the
# whole point is not to invent any.
SETTLE=$(( SECONDS_PER_TAKE + 8 ))

echo "app:      $APP"
echo "runs:     $RUNS x ${SECONDS_PER_TAKE}s (allowing ${SETTLE}s each)"
echo

START="$(date +"%Y-%m-%d %H:%M:%S")"

for run in $(seq 1 "$RUNS"); do
	printf '  run %2d/%s ' "$run" "$RUNS"
	pkill -f "$EXEC_NAME" 2>/dev/null || true
	sleep 1
	open -n -a "$APP" --args --selftest-record "$OUT" --seconds "$SECONDS_PER_TAKE" --mic
	sleep "$SETTLE"
	# A run that hangs is itself a symptom -- the -5814 failure left the process
	# alive with no recording -- so it is killed rather than waited on, and the
	# log below is what says whether it got anywhere.
	if pgrep -f "$EXEC_NAME" >/dev/null 2>&1; then
		printf 'still running, killing '
		pkill -f "$EXEC_NAME" 2>/dev/null || true
	fi
	echo "done"
done

echo
echo "=== outcomes ==="
log show --predicate "subsystem == \"$BUNDLE_ID\"" --start "$START" \
	--info --debug --style compact 2>/dev/null \
	| grep -E "recording (display|area) started|writer failed|recording finished" \
	| sed -E 's/.*\[com\.boli\.duoshot:record\] //' \
	| tee "$OUT/outcomes.txt"

echo
started=$(grep -c "started" "$OUT/outcomes.txt" || true)
failed=$(grep -c "writer failed" "$OUT/outcomes.txt" || true)
finished=$(grep -c "recording finished" "$OUT/outcomes.txt" || true)
# A take that finished well under its requested length is the *other* symptom,
# and it does not log an error at all -- it has to be read off the duration.
short=$(grep "recording finished" "$OUT/outcomes.txt" \
	| grep -cE "0:0[0-$(( SECONDS_PER_TAKE > 2 ? SECONDS_PER_TAKE - 2 : 0 ))]" || true)

# Started minus finished. The third symptom, and the one with no error and no
# file: measured on the first batch, a take reported `startCapture 7851.7 ms`
# and then never finished at all.
stranded=$(( started - finished - failed ))
(( stranded < 0 )) && stranded=0

echo "=== tally over $RUNS runs ==="
echo "  takes started:      $started"
echo "  writer failed:      $failed   <- RPRecordingErrorDomain, the loud symptom"
echo "  takes finished:     $finished"
echo "  finished too short: $short   <- the silent symptom (< $(( SECONDS_PER_TAKE - 1 ))s)"
echo "  started, no finish: $stranded   <- hung; check the startCapture timings above"
echo
echo "full log: $OUT/outcomes.txt"
