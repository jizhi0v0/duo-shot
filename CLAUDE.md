# DuoShot — working notes for agents

A menu-bar screenshot and screen-recording app. Swift 6, macOS 26 minimum, built
with SwiftPM and bundled/signed by hand (`Makefile`). The comments in this repo
carry the reasoning; this file carries the conventions that are not visible from
any single file, and the process rules that were paid for in wasted rounds.

## The loop

```
make verify        # build + bundle + sign + assert the Designated Requirement
make test          # the whole headless regression suite
make install       # replace /Applications/DuoShot.app AND restart it
```

- `make install` is not optional after a code change you want to *use*. Copying
  the bundle does not touch the running process, and the old build goes on
  serving the hotkeys — which reads as "the fix didn't work", not as "the app
  wasn't restarted".
- `make run` execs the inner binary with stdout attached. Fine for iterating,
  useless for TCC: a shell-spawned process is attributed to its responsible
  *ancestor*, so it reports `granted` where the same bundle launched by
  LaunchServices reports `denied`. Use `make tcc-check` / `make mic-check`.
- Never change the signing flags in a way that alters the Designated
  Requirement. The screen-recording grant is keyed on it; `make verify` is the
  assertion and it must stay green.
- Building here uses the newest SDK. `#available` does *not* protect against
  using a symbol that only exists in a newer SDK — that is a compile-time
  problem. `make check-26` compiles on a Mac running the minimum.

## Concurrency

- `.defaultIsolation(MainActor)` plus `NonisolatedNonsendingByDefault`. The
  module is ~90% AppKit, so main-actor is the default and the exceptions are
  meant to be conspicuous.
- Off-main work needs an explicit `@concurrent`, and the type it lives on needs
  `nonisolated`. Pixel work (`Redaction`, `ImageEncoder`, `ImagePadding`,
  `ImageEdit`) is all `nonisolated` for that reason: a 5K bitmap is tens of
  megabytes and none of that belongs on the main thread.
- `@unchecked Sendable` is confined to `SCKBridge` (plus `CaptureResult` and the
  self-test's own boxes). Do not add another. To move an image across an
  isolation boundary, send `Data` or a `URL` — not a `CGImage`.

## Self-tests

Every check that can run without a human at the mouse lives in
`Sources/DuoShot/App/SelfTest.swift` behind a `--selftest-*` flag and is listed
in `make test`. Conventions that are load-bearing:

- **The exit code is the only verdict.** Matching on printed text as well meant
  two sources of truth, and they disagreed.
- **A test that cannot fail is not a test.** `make test` runs an explicit
  negative control (`exclusion negative control`) whose *passing* is reported as
  BROKEN. Hold new checks to the same standard: before you believe a green one,
  revert the fix and watch it go red. This is the single highest-value habit in
  this repo, and skipping it is how eighty green checks came to prove nothing.
- **UI wiring must be exercised, not inspected.** A hit-testing bug made the
  Redact button dead while every geometry assertion about it passed. Use the
  synthesized-event helpers (`click`, `drag`, `press`) and assert on the
  *consequence*, not on the view tree.
- `INCONCLUSIVE` means the run asserted nothing (usually the screen was moving).
  It exits 0. Re-run it; do not count it.
- Do **not** measure a view with `cacheDisplay(in:to:)`. It re-lays out while
  measuring and changes the very frame under test — three rounds of conclusions
  were built on numbers it had corrupted. Photograph the real window instead
  (`photographEditor`, or `coordinator.engine.capture`).
- Two traps in the harness itself: `perform(Selector(...))` on a method that is
  not `@objc` crashes, and a synthesized drag delivered into `NSTextView`
  enters AppKit's modal tracking loop and hangs the run for ten minutes.

## The image editor

`ImageEdit` (model + renderer, `Output/`) and `ImageEditor` (UI, `Preview/`).
The rules that are easy to break from either side:

- **Coordinates**: image *points*, origin bottom-left — the space the user drew
  in, which on a 2× capture is not the bitmap's pixels. `ImageEdit.render` holds
  the one scale that separates them.
- **The list is the edit.** The whole list is flattened onto the staged file
  from the capture's original bytes after every change, which is what makes ⌘Z
  work on an operation that destroys pixels. Never edit in place.
- **Text is anchored by the top-left of its first line's box**, never by the
  baseline: descent varies by script, so a baseline anchor moves when you type a
  Latin letter after a Han one. `textLineHeight` and `textBaselineFromTop` are
  the single source of truth, and `EditCanvas` pins TextKit to them through
  `NSLayoutManagerDelegate`. Both the editor and the renderer read the same
  numbers — "roughly the font's line height" is not a number.
- **The typing box must not re-rasterise glyphs that are already on screen.**
  Clicking existing text keeps the original bitmap pixels; the box contributes
  only caret, selection and the dashed frame (`showsAnnotation`,
  `originalString`, `revealsAfterPreviewUpdate`). New glyphs appear only after
  the content actually changes and the clean preview has landed. Two
  rasterisations of "the same" text are never the same, and the visible result
  is text that thickens or shifts the instant you click it.
- `TypingView` overrides `scrollRangeToVisible`/`scroll`/`scrollToVisible` to do
  nothing. It lives inside the scroll view holding the picture, so asking to be
  revealed slid the whole capture — reported, correctly, as "the text jumps when
  I click it".

## Debugging protocol

Bobby reports UI bugs in Chinese, with screenshots and screen recordings, saved
in the folder named by the `saveDirectory` preference. Those files are evidence.
Read their pixels.

**The trigger: the second time the same symptom is reported, stop changing
code.** "依旧如此" / "还是会" means the mechanism model is wrong, not that the fix
was incomplete. One more plausible explanation is worth nothing at that point.
On the text-jitter bug this rule was ignored six times running; every fix
corrected a real defect and none of them was the reported one.

Then, in order:

1. **Turn the complaint into a measurement that can tell good from bad.**
   偏移/上移 → ink bounding box origin. 变粗/变重 → ink coverage. 收缩/字间距 →
   per-glyph pitch, or per-pixel replacement rate. "抖一下" at one moment →
   extract the recording's frames and diff the same region across consecutive
   ones. If you cannot state what value means "bug present", you do not have a
   measurement.
2. **Check the metric is not blind to the symptom.** Whole-block ink bounds hold
   steady while the second glyph shrinks and the baseline lifts — the outer
   edges do not move. That metric passed every round while the bug was visible
   on screen. This is the mistake that costs the most.
3. **Record the bad state before touching code**, from a real capture.
4. **Look for the observation that kills the hypothesis, not one that confirms
   it.** "Is this line being composited twice?" is a yes/no question a 100-line
   standalone script answers in twenty minutes (`Scripts/text-handoff-probe.swift`
   is the surviving example; `Scripts/mic-recording-repro.sh` is the other
   shape — a batch repro for an intermittent failure, because one run proves
   nothing).
5. **Make the new test fail first**, by reverting the fix.
6. **Report three things**: what was reproduced, what changed, what is still
   unverified. Never "N checks green, installed" — that reads as "fixed" when it
   may only mean a self-written test agrees with a self-written fix.

Do not: ship several fixes in one round (they may all be real and the symptom
still there, with no way to tell which mattered); reach for a refactor as a
substitute for localising; or keep guessing past two failed rounds. Saying "I
cannot reproduce this, please record it" is cheaper than a third guess.
