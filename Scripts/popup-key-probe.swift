#!/usr/bin/env swift
// Does taking the keyboard kill a menu-bar popup?
//
// Measured 2026-08-05 with `Scripts/popup-pick-probe.sh`: the picker offers the
// popup, and 131 ms later — one poll tick — `reRank` puts it behind the menu
// bar and the hover falls through to the maximized window behind. A window at
// layer 101 cannot rank behind the menu bar while it is on screen, so it was
// already gone from `CGWindowListCopyWindowInfo`. The popup had closed.
//
// What is *not* established is why. The overlay is a non-activating panel that
// takes key status and re-takes it every 120 ms
// (`OverlayPanel.canBecomeKey`, `OverlayController.restoreKeyboardIfLost`), and
// that is the obvious suspect — but "the popup died while the overlay was up"
// is a correlation, and the overlay does several things at once.
//
// So: the same panel, twice, differing in exactly one thing — whether it takes
// the keyboard. Nothing else here captures, enumerates or draws.
//
//   swift Scripts/popup-key-probe.swift Surge [rounds]
//
// Reported as intermittent ("sometimes the window under the pointer can be
// picked, sometimes not"), so it repeats: one run proves nothing either way.
// Open the popup when prompted; the probe raises the panel itself.

import AppKit

let args = CommandLine.arguments.dropFirst()
let needle = args.first ?? "Surge"
let rounds = Int(args.dropFirst().first ?? "") ?? 3

/// A panel built to the same recipe as `OverlayPanel`, minus everything that is
/// not the variable under test.
final class ProbePanel: NSPanel {
    private let wantsKey: Bool
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, wantsKey: Bool) {
        self.wantsKey = wantsKey
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        // Order matters here for the same reason it does in OverlayPanel:
        // isFloatingPanel resets the level.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.25)
        hasShadow = false
        hidesOnDeactivate = false
        worksWhenModal = true
    }
}

/// Window IDs the app owns that are big enough to be the popup.
func popupWindows() -> Set<CGWindowID> {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    var found: Set<CGWindowID> = []
    for entry in list {
        let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
        guard owner.localizedCaseInsensitiveContains(needle) else { continue }
        guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
        var bounds = CGRect.zero
        if let dict = entry[kCGWindowBounds as String] {
            CGRectMakeWithDictionaryRepresentation(dict as! CFDictionary, &bounds)
        }
        guard bounds.width * bounds.height >= 20_000 else { continue }
        found.insert(CGWindowID(number.uint32Value))
    }
    return found
}

@MainActor
func waitForPopup() async -> Set<CGWindowID>? {
    for _ in 0..<300 {
        let windows = popupWindows()
        if !windows.isEmpty {
            // Let it finish appearing before anything is asked of it.
            try? await Task.sleep(for: .milliseconds(400))
            let settled = popupWindows()
            if !settled.isEmpty { return settled }
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
}

@MainActor
func waitForPopupToClose() async {
    for _ in 0..<300 {
        if popupWindows().isEmpty { return }
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// Raises the panel over the live popup and reports how long the popup lasts.
///
/// Returns nil when the popup was still there at the end — which is the
/// outcome that means "this variant does not kill it".
@MainActor
func trial(wantsKey: Bool, popup: Set<CGWindowID>) async -> Int? {
    guard let screen = NSScreen.main else { return nil }
    let panel = ProbePanel(screen: screen, wantsKey: wantsKey)
    panel.orderFrontRegardless()
    if wantsKey { panel.makeKeyAndOrderFront(nil) }

    var died: Int?
    let step = 50
    for tick in 0...(1500 / step) {
        // The overlay does not merely take key once; it takes it back every
        // 120 ms. Reproduce that, or the variant is not the one under test.
        if wantsKey, tick % 2 == 0, !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        try? await Task.sleep(for: .milliseconds(step))
        if popupWindows().isDisjoint(with: popup) {
            died = tick * step
            break
        }
    }

    panel.orderOut(nil)
    return died
}

@MainActor
func run() async {
    print("""
        \(rounds) round(s) against '\(needle)'.
        Each round opens the popup twice: once under a panel that does NOT take \
        the keyboard, once under one that does. Everything else is identical.

        """)

    var noKeyDeaths = 0
    var keyDeaths = 0
    for round in 1...rounds {
        for wantsKey in [false, true] {
            let label = wantsKey ? "takes key    " : "no key       "
            print("round \(round) \(label): open the popup…", terminator: "")
            fflush(stdout)
            guard let popup = await waitForPopup() else {
                print(" popup never appeared — skipped")
                continue
            }
            let died = await trial(wantsKey: wantsKey, popup: popup)
            if let died {
                print(" DIED after \(died) ms")
                if wantsKey { keyDeaths += 1 } else { noKeyDeaths += 1 }
            } else {
                print(" survived 1500 ms")
            }
            await waitForPopupToClose()
        }
    }

    print("""

        no key    : \(noKeyDeaths)/\(rounds) died
        takes key : \(keyDeaths)/\(rounds) died
        """)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task {
    await run()
    exit(0)
}
RunLoop.main.run()
