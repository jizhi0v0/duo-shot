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
  untracked `local.mk`) runs the oldest *macOS* — 26.7 as of 2026-10-20 — but
  its default Xcode is 27 (Swift 6.4, 27 SDK), the same toolchain as the
  first. So on neither machine is an ordinary `make verify` a cross-SDK check.
  The old toolchain is a side-by-side Xcode 26.6 (`CHECK_XCODE`, default
  `/Applications/Xcode-26.6.app`, 17F113; Swift 6.3.3, macOS 26.5 SDK), and `make
  check-26` pins `DEVELOPER_DIR` to it, prints the compiler and SDK it got, and
  fails unless they are older than Swift 6.4 and a 26 SDK. It is the only thing
  standing between you and a build everybody else cannot compile; if it fails
  on the toolchain lines rather than the build, the check did not run. Check
  before concluding anything: `sw_vers -productVersion`,
  `xcrun --show-sdk-version --sdk macosx`.
- A symbol newer than the deployment target needs **both** guards.
  `#available(macOS 27.0, *)` is a runtime check — the symbol still has to
  exist at compile time, and one that is absent from the 26 SDK fails the build
  outright. Swift has no `#if sdk(...)`, so the compiler version stands in for
  it: `#if compiler(>=6.4)` around the `#available`. Both 27-only calls in the
  tree (`NSGlassEffectView.effectIsInteractive`,
  `SCRecordingOutputConfiguration.mixesAudioWithMicrophone`) are written that
  way, and each says in a comment what is lost when the block is compiled out.
- `make check-26` catches more than missing symbols. On 2026-09-11 it stopped a
  push over a self-test helper that called a closure parameter from inside
  another closure (`(0..<n).first { match(…) }`): Swift 6.3.3 on the 26 SDK
  rejects that as "sending … risks causing data races", and the newer compiler
  accepts it. From the newest-SDK machine, run it before every push, and on
  every unpushed commit rather than only the tip — a fix folded in later still
  leaves the commits before it uncompilable.

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
- **Assert where, not only how big.** `PixelCompare.opaqueBounds` mirrored y for
  as long as it existed, and `transparentBorderIsTrimmed`, which checked only the
  size of the trimmed result, passed throughout — while `trimmed` kept 44640 of
  its own fixture's 86400 ink pixels. A check on a crop, a rect or a composite
  asserts position, or which pixels survived, and not just dimensions.
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
- Three traps in the harness itself. `perform(Selector(...))` on a method that
  is not `@objc` crashes. A synthesized drag delivered into `NSTextView` enters
  AppKit's modal tracking loop and hangs the run for ten minutes. And the
  `click` helper calls `mouseDown` directly, which on an **`NSButton`** enters
  `NSCell.trackMouse(…untilMouseUp:)` — it pulls from an event queue no
  synthesized mouse-up is ever posted to. Use `hitTest` to prove the button is
  reachable and `performClick(nil)` to fire it (`--selftest-delete` does).
- A fixture that counts a colour builds it with `CGColor(srgbRed:…)`.
  `CGColor(red:green:blue:alpha:)` is generic RGB, and its magenta lands in an
  sRGB context as (255, 64, 255) — enough to fail a colour test for reasons that
  have nothing to do with the code under it.
- **Run the suite on the mini by default.** `make test` takes over the screen
  for minutes, and the maintainer works at the newest-SDK machine; `make test-mini` builds
  and signs there and runs on the mini. For a single check there is no target: `make verify` —
  and confirm it *succeeded*, because a failed build leaves the previous bundle
  in `build/` and shipping that tests the wrong code — then `ditto -c -k
  --keepParent build/DuoShot.app`, scp, `ditto -x -k` and `codesign --verify
  --strict` on the mini, and the flag over ssh. Only what needs the maintainer's real desktop
  (their Dock, a real app's tooltip) belongs on their machine, done by them. The
  mini's Dock is always visible, which makes it the only place the real
  Dock-capture checks run.
- **Some checks are red on the mini at pristine HEAD, and *which* ones drifts.**
  Measured three times: 2026-08-05 `rect pipeline` / `selection loupe` /
  `freeze mode` / `scroll capture flow`; 2026-08-09 only `sourceRect semantics`;
  2026-08-12 `faded window` / `occluded recovery` / `scroll capture flow`, plus
  `edit menu (paste)` INCONCLUSIVE. Almost no overlap between the three. On
  2026-09-11 it drifted within one afternoon: `scroll capture flow` passed
  several full runs, then failed 2/2 — and failed identically at HEAD.
  So **never attribute a red on the mini to your change, and never clear one
  either, without diffing against a detached-HEAD worktree in the same session**
  — `git worktree add <dir> --detach HEAD` then `make test-mini
  CHECK_DIR='~/duo-shot-headbase'`. Any list written down here is stale by the
  time you read it; the comparison is the only answer.
- Anything that builds the **status menu** reads `ShareSettings.shared`, whose
  initialiser reads the Keychain, which headless can block on a prompt nobody is
  there to answer. This is why `--selftest-share-card`, `--selftest-share-flow`
  and `--selftest-failure-notice-ui` are **not** in `make test`. Keep menu
  assertions out of the suite; put the coordinator-level contract in it instead.

## Window capture

- **Liquid glass cannot survive a window capture, and that is not a filter we
  chose wrong.** A window rendered in isolation has no backdrop left to sample,
  so a translucent surface falls back to its base tint. Measured 2026-09-01 on a
  glass panel with an opaque red window parked directly behind it, counting
  pixels of that red in the result:

      desktopIndependentWindow, child=false            0
      desktopIndependentWindow, child=true             0
      screencapture -l<windowid>   (macOS's own)       0
      SCContentFilter(display:including:)         432906
      the same rect as a region of the display    432906

  `screencapture -l` is the whole answer: **the platform's own window capture
  does exactly what ours does**, confirmed the same day on the real DuoUpdater
  popup — flat panel, nothing of the terminal behind it, while the same rectangle
  taken as a region shows the terminal through the glass. Do not go looking for
  the API that fixes this. The escape hatch is region capture, and it costs the
  rounded corners and the transparent surround, and puts whatever is behind the
  window into the file — unless the window's own shape is at hand. The Dock is
  captured as a region and then cut to the alpha of its window captured alone
  at the same instant (`CaptureEngine.shaped`), which keeps the real glass *and*
  the outline. The check for it compares colour with the flat isolated capture:
  59.2 apart on the mini's Dock (channel means, summed), 0 when the cut is fed
  its own flat pixels.
- **A probe with nothing distinctive behind the window is blind to all of the
  above.** Two captures of a dark panel over an ordinary desktop look the same
  and are not; that reading is what put a wrong "no difference here" in front of
  the maintainer for a round. Park something loud behind the window and count it.
  `Scripts/glass-stack-probe.swift` is that fixture — a `MenuBarExtra` app that
  opens its own panel by clicking its own status item, with a `.popover` inside
  it and an opaque red window parked behind it. It prints every filter and
  `screencapture -l` side by side.
- **A window capture is framed to the window *group*, not the window**, so a
  popover overhanging the edge makes the file larger than the outline the picker
  drew. That is deliberate and it is what the platform does: `screencapture -l`
  returned the identical 1008x600 union on the same fixture. The usual rule —
  nothing in the file that was not inside the outline — is about *other windows'*
  pixels, and does not reach a window's own attached panel.
- Leaving `SCScreenshotConfiguration.width`/`height` **unset** is not the same as
  setting them to the picked window's size. SCK grows the region to the group and
  fits it into whatever size it is given, so asking for the window's size returns
  the group squeezed into it under a point size that lies. See `captureGroup`.
- **A window can have something stacked on it that is not in its group.** A
  tooltip is its own window — Duo Updater's sits at layer 103 over a panel at
  101 — and `includeChildWindows` and `screencapture -l` both leave it out. The
  capture composites it anyway (`CaptureEngine.adornments`): same app, in
  front, a *strictly higher* layer, overlapping, and too small for the picker to
  offer on its own. Each condition is load-bearing. Same layer is Finder and
  Mail windows piled on each other; the size test is what tells a tooltip from
  `--selftest-occluded-recovery`'s occluder, which has a tooltip's layers
  exactly and was composited into the capture it exists to stay out of. The
  picker's outline grows by the same set, so it matches the file.
- **The overlay dismisses things.** Duo Updater's tooltip was gone within 0.75 s
  of the overlay appearing, and an auto-hidden Dock retracts once the pointer
  leaves it — three of four Dock picks photographed whatever was behind it. The
  file is what was on screen when the shortcut fired, so those are taken before
  the overlay goes up: `WindowRecovery.adornments` for a tooltip, the pre-overlay
  photograph for a region-captured window (`captureStrip`). The instant window
  shortcut opens no overlay and stays live.
- **An auto-hidden Dock reserves nothing out of `visibleFrame`**, hidden and
  revealed alike, so the Dock is located from its own window's pixels
  (`ShareableContentCache.dockShape`) for every Dock — the strip an
  always-visible one reserves was 11 pt short of what it draws, and is only the
  fallback now.
- **`opaqueBounds` rounds out; `tightBounds` does not.** A cell or two of slack
  on a downscale is the right error for trimming a window and the wrong one for
  a rect that is also an outline on screen or the size of a file: it came out
  as 12 pt of nothing around the Dock, in the outline and in the picture alike.

## Command-line capture

The `duoshot` tool asks the running app for pixels over a Unix socket
(`CLIServer`, `Sources/DuoShotCLIWire`). While that socket is open, any program
of this user's can capture the screen with DuoShot's grant — so:

- **The switch is session-only, never a preference.** `UserDefaults.standard`
  answers from the argument domain (`open … --args -allowsCommandLineCapture
  YES`) and from `defaults write` by any same-user process, so a stored "on"
  can be set from outside. It is off at every launch; only the Settings toggle
  turns it on.
- **The client lives outside DuoShot.app.** TCC judges any binary inside an app
  bundle as the enclosing app for folder access, whatever it was signed as:
  measured, a helper in `Contents/` with its own identifier logged
  `AUTHREQ_SUBJECT subject=<the app's id>` and read `~/Desktop` on the app's
  grant. From `build/duoshot` the same read prompts in the tool's own name.
- **An as-seen shot is two captures** — the isolated shape, then the region —
  and a panel closing between them returned a picture of what was behind it, cut
  to its outline, with alpha 1. The window is re-checked after the region and
  anything different exits 6. The alpha read before capturing is not enough.
- **`--selftest-*` is compiled out of what ships** (`SELFTEST=0`, `#if
  DUOSHOT_SELFTEST`). Launched through LaunchServices, DuoShot is its own TCC
  responsible process, so a self-test entry point in a release build is a
  capture-anything-to-any-path command for any same-user process.

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
Read their pixels. DuoShot's own `Log.capture` lines are the other half — read
them with `/usr/bin/log show --predicate 'subsystem == "com.jizhiovo.duoshot"'`. A
bare `log` in zsh is a shell builtin and prints nothing useful, which reads
exactly like "the app logged nothing"; it cost several rounds of empty reads
before anyone looked.

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
