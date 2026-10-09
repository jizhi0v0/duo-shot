# DuoShot

English · [简体中文](README.zh-CN.md)

A menu-bar screenshot and screen-recording app for macOS. Native AppKit and
ScreenCaptureKit, no Dock icon, no account, no telemetry.

## Features

**Capture**
- Area, window under the pointer, fullscreen, and "previous area again".
- Scrolling capture: you scroll, DuoShot stitches. It never scrolls anything
  itself, so it needs no Accessibility permission.
- Optional frozen screen while selecting, capture delay, cursor, menu bar and
  child windows (menus, popovers) on or off.
- Window captures can be padded onto the display's actual wallpaper, with a
  shadow.

**Record**
- Area or fullscreen to MP4, with system audio, microphone (choose the input
  device), cursor and click highlighting, and a selectable frame rate.
- Trim a take and export it as a GIF.

**Edit**
- Arrow, line, rectangle, text, marker, highlighter, redact and crop. Each mark
  keeps its own colour and weight, and every edit can be undone.
- Sensitive text such as email addresses, IP addresses, phone numbers, card
  numbers and API keys is detected and can be redacted.

**After the capture**
- A floating preview card: drag it into another app, copy, edit, or discard.
- Copy Text: on-device OCR with Vision.
- Search Captures (⌘F from the menu) finds old screenshots by the words in them.
- Optional share links through a Cloudflare Worker that you deploy yourself
  (see [`Worker/`](Worker/README.md)).

### Default shortcuts

| Action | Shortcut |
| --- | --- |
| Capture Area | ⇧⌘A |
| Capture Window Under Pointer | ⇧⌘S |
| Record Area (press again to stop) | ⇧⌘Y |
| Scrolling Capture | ⇧⌘L |

Capture Fullscreen, Capture Previous Area and Record Fullscreen ship unbound.
Every shortcut can be changed in Settings.

## Requirements

- macOS 26 or later, Apple silicon or Intel.
- **Screen Recording** permission, requested on first capture.
- **Microphone** permission, requested only if you turn on voice-over for a
  recording.

## Install

Download `DuoShot.zip` from the [latest release](../../releases/latest), unzip
it, and move `DuoShot.app` to `/Applications`. Releases are signed with a
Developer ID and notarized by Apple.

## Privacy

- Captures stay on your Mac. OCR and sensitive-text detection run locally with
  Apple's Vision framework.
- DuoShot makes no network requests unless you set up share links. Uploads then
  go only to the server you configured, authenticated with a token that is
  stored in your Keychain.
- There is no analytics, crash reporting or update check.

## Build from source

You need Xcode 26 (Swift 6) and a **Developer ID Application** certificate.
The app is signed by hand rather than through an Xcode project. Its Screen
Recording grant is tied to the signature's Designated Requirement, so an ad-hoc
signature would lose the permission on every rebuild.

```bash
make verify     # build, bundle, sign, and check the Designated Requirement
make install    # replace /Applications/DuoShot.app and relaunch it
make test       # headless self-test suite (takes over the screen for a few minutes)
make help       # all targets
```

To sign with your own certificate, create an untracked `local.mk`:

```make
TEAM_ID := ABCDE12345
SIGN_ID := Developer ID Application: Your Name (ABCDE12345)
```

`make dist` builds a universal binary, notarizes it and writes
`dist/DuoShot.zip`. It expects a notarytool keychain profile
(`xcrun notarytool store-credentials DuoShot`).

[`CLAUDE.md`](CLAUDE.md) holds the project's conventions: concurrency rules,
self-test discipline, and the image editor's invariants. Read it before you
change anything substantial.

## Repository layout

| Path | What it is |
| --- | --- |
| `Sources/DuoShot/` | The app |
| `Packages/Linkdrop/` | Upload client for share links (Swift package, MIT) |
| `Worker/` | The share-link backend: a Cloudflare Worker with R2 storage |
| `Scripts/` | Standalone probes and repro scripts used while debugging |

## License

[MIT](LICENSE) © 2026 Bo Li
