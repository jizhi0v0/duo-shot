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
- **Two machines, and which one you are on changes what a green build means.**
  One runs Xcode beta with the newest SDK; the other (`CHECK_HOST`, set in the
  untracked `local.mk`) runs the deployment minimum. Check before concluding anything:
  `sw_vers -productVersion`, `xcrun --show-sdk-version --sdk macosx`. On the
  minimum machine an ordinary `make verify` already *is* the cross-SDK check,
  and `make check-26` is a no-op that rsyncs to itself. On the newest-SDK
  machine it is the only thing standing between you and a build everybody else
  cannot compile.
- A symbol newer than the deployment target needs **both** guards.
  `#available(macOS 27.0, *)` is a runtime check — the symbol still has to
  exist at compile time, and one that is absent from the 26 SDK fails the build
  outright. Swift has no `#if sdk(...)`, so the compiler version stands in for
  it: `#if compiler(>=6.4)` around the `#available`. Both 27-only calls in the
  tree (`NSGlassEffectView.effectIsInteractive`,
  `SCRecordingOutputConfiguration.mixesAudioWithMicrophone`) are written that
  way, and each says in a comment what is lost when the block is compiled out.

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

- **A mark carries its own `Ink`** (colour + weight) as a defaulted associated
  value on the enum case. Defaults are what let a hundred existing call sites
  keep saying `.arrow(a, b)`; pattern *matches* still have to name the extra
  binding. Nothing reads the toolbar at render time — an arrow drawn in red
  stays red when the next one is blue, the same rule the text size already had.
- **`EditMetrics`, not `HUDMetrics`.** The editor's chrome is furniture in a
  window that is worked in; `HUDMetrics` sizes a bar that appears over the
  screen for a few seconds. They were shared, and the editor looked like a HUD
  doing a job it was not built for. `HUDPill.Sizing.editor` is the matching
  pill geometry.
- **The two bands are the same height**, even though the top one holds two rows
  and the bottom one holds one. Unequal bands put the picture half the
  difference below the middle of the *window* — invisible until a crop leaves a
  small picture floating in a large one. The slack goes above the footer.
- **A resize keeps the window's centre**, not its top left. The top-left rule is
  about a window being dragged by its corner; a crop shrinks it with nothing
  under the pointer, and it walked off towards the corner.
- **Share Link is gated on `ShareService.shared.isConfigured`**, not on
  `canShare(fileAt:)` — the latter asks whether the file *type* could be
  uploaded, which for a PNG is always yes. It is the one control in the chrome
  that is hidden rather than dimmed, same as the preview card's upload button.
- **The window's minimum width comes from the bar** (`minimumContentWidth`),
  measured from a real `EditToolbar`. It was a number typed out beside it, and
  the moment the bar grew a second row a small capture opened with the leftmost
  tool sliced off by the edge of its own window.
- **That floor is `contentMinSize` as well as an opening size.** The bar does not
  reflow, it clips, and a viewer with no minimum could be dragged to 300 points
  wide — losing the tools at both ends of the row and Done with them. Note when
  testing this: `setFrame` ignores `contentMinSize`; AppKit enforces it on a
  user's drag. So squeeze to the window's own `contentMinSize` and assert that
  *that* size is enough, rather than to an arbitrary small frame.
- **Escape means "out of here", once.** Box, then selection, then the window. It
  used to put the *tool* down as a middle step, which with nine tools meant it
  almost never reached the window — reported as "esc 没法直接退出 window". V
  puts the pointer back and says so on a button.
- **A re-opened annotation is suspended, not removed.** `takeText` leaves the
  entry in the list and `visibleEdits` hides it while the box stands in for it.
  It used to remove it and rely on the commit to put it back, so Escape and
  changing tool both deleted the note — with the preview a render behind, so
  nothing said so until later. Anything that ends the box goes through
  `onTypingFinished`.
- **Anything that writes commits the box first** (`copyOut`, `saveAs`,
  `shareOut`). The box's words are not in the list until it commits, so Copy
  used to export the picture without the note being typed onto it.
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

The maintainer reports UI bugs in Chinese, with screenshots and screen recordings, saved
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
