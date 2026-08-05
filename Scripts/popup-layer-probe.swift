#!/usr/bin/env swift
// Why can't the window picker capture a menu-bar app's popup panel?
//
// Two candidate mechanisms, and they need different fixes, so they have to be
// told apart before anything is changed:
//
//   A. the panel's window layer is outside the picker's pickable set
//      (`WindowPickerModel.isPickable(layer:)` allows 0...8, 20, 24), or
//   B. the panel dismisses itself the moment DuoShot's overlay takes key, so
//      by the time the user aims at it there is nothing left to aim at.
//
// This samples the window list ~5×/s and prints a timeline: when the target
// window appears, at what layer, and whether it is still there once the overlay
// (a window at the shielding level, 2147483628) shows up.
//
//   swift Scripts/popup-layer-probe.swift DuoUpdater [seconds]
//
// Open the popup, then press the window-capture hotkey while it is open.

import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst()
let needle = args.first ?? "DuoUpdater"
let seconds = Double(args.dropFirst().first ?? "") ?? 45

struct Snapshot: Equatable {
    var layer: Int
    var alpha: Double
    var size: String
    var onScreen: Bool
}

func sample() -> (target: Snapshot?, overlayUp: Bool) {
    let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var target: Snapshot?
    var overlayUp = false
    for info in list {
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        var bounds = CGRect.zero
        if let dict = info[kCGWindowBounds as String] {
            CGRectMakeWithDictionaryRepresentation(dict as! CFDictionary, &bounds)
        }
        if owner == "DuoShot", layer > 1_000_000 { overlayUp = true }
        guard owner.localizedCaseInsensitiveContains(needle) else { continue }
        // The status-item button itself is a small tile in the menu bar; the
        // popup is the big one. Keep the biggest window the app owns.
        let snapshot = Snapshot(
            layer: layer,
            alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
            size: "\(Int(bounds.width))x\(Int(bounds.height))",
            onScreen: true)
        if bounds.width * bounds.height > 20_000 { target = snapshot }
    }
    return (target, overlayUp)
}

print("watching '\(needle)' for \(Int(seconds))s — open the popup, then press the hotkey")

// Wall clock, not elapsed: the point is to line these up against DuoShot's own
// `Log.overlay` stream, which is where the picker says what it dropped and why.
let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

let start = Date()
var last: (Snapshot?, Bool)?
while Date().timeIntervalSince(start) < seconds {
    let now = sample()
    if last == nil || last!.0 != now.target || last!.1 != now.overlayUp {
        let t = clock.string(from: Date())
        let overlay = now.overlayUp ? "OVERLAY UP " : "           "
        if let s = now.target {
            print("\(t) \(overlay)\(needle): layer \(s.layer)  alpha \(s.alpha)  \(s.size)")
        } else {
            print("\(t) \(overlay)\(needle): (no window ≥20k px on screen)")
        }
        last = now
    }
    usleep(200_000)
}
print("done")
