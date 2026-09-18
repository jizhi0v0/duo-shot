import AppKit
import Darwin

/// A window-server space of the overlay's own, so the overlay is on screen the
/// instant the shortcut fires — including halfway through a swipe between
/// desktops.
///
/// Reported 2026-09-11 as "按下的瞬间应该冻结 … 如果在按下瞬间冻结，我们就不会看见
/// space2 已经切过去了". A window on every desktop (`.canJoinAllSpaces`) rides
/// the desktop being left for as long as a swipe lasts, and turns up on the new
/// one only when the swipe ends. Measured with three panels configured exactly
/// like `OverlayPanel` — ordered in once, re-ordered every 400 ms, or kept in
/// and alpha-toggled — all three slid off with the old desktop and snapped back
/// at the end. The overlay itself, raised mid-swipe, sat at x = −1786, off
/// screen, until the swipe landed half a second later: the user watched space 2
/// arrive, and then got a frozen frame from before it had.
///
/// Alcove's notch windows do not move during a swipe (0 samples moved across
/// five swipes, against NotchBadge's 96), and Alcove imports the calls used
/// here. A panel added to a space of our own with them stayed put through four
/// swipes, one of them held halfway, and one ordered in 52 times mid-swipe was
/// at its place every time. The recipe is Alcove's imports plus boring.notch's
/// `CGSSpace.swift`; the declarations are NUIKit's `CGSInternal/CGSSpace.h`.
///
/// **Private API, and the only use of it in DuoShot.** No documentation and no
/// compatibility promise, so every call is looked up at run time: if any one is
/// missing the overlay behaves exactly as it did before — on every desktop, and
/// late during a swipe — rather than failing to appear.
enum OverlaySpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, UnsafeMutableRawPointer?, CFDictionary?) -> Int
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct Calls {
        let connection: Int32
        let space: Int
        let add: AddWindowsToSpaces
        let copySpaces: CopySpacesForWindows?
    }

    /// Created on first use and kept for the life of the process: one space
    /// serves every presentation, and the window server drops it with our
    /// connection when the process exits.
    private static let calls: Calls? = makeCalls()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // RTLD_DEFAULT, which Swift does not import: every loaded image.
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static func makeCalls() -> Calls? {
        guard let main = symbol("CGSMainConnectionID", as: MainConnection.self),
              let create = symbol("CGSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = symbol("CGSShowSpaces", as: ShowSpaces.self),
              let add = symbol("CGSAddWindowsToSpaces", as: AddWindowsToSpaces.self)
        else {
            Log.overlay.error("private space calls missing; the overlay stays on every desktop")
            return nil
        }
        let connection = main()
        // The flag must be 1: boring.notch found that anything else has Finder
        // draw the desktop icons into the new space.
        let space = create(connection, UnsafeMutableRawPointer(bitPattern: 1), nil)
        guard space != 0 else {
            Log.overlay.error("CGSSpaceCreate returned no space; the overlay stays on every desktop")
            return nil
        }
        // The value the swipe probe used and saw stay put: above every desktop.
        setLevel(connection, space, Int32.max)
        show(connection, [space] as CFArray)
        return Calls(
            connection: connection, space: space, add: add,
            copySpaces: symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self))
    }

    /// Moves `window` into the overlay's space. Call once it is on screen.
    static func adopt(_ window: NSWindow) {
        guard let calls else { return }
        calls.add(calls.connection, [window.windowNumber] as CFArray, [calls.space] as CFArray)
    }

    /// Whether `window` is on screen and on none of the desktops — what
    /// `adopt` does to it — for `--selftest-window`.
    ///
    /// Not "is it in our space": `CGSCopySpacesForWindows` never names a space
    /// made with `CGSSpaceCreate`, under any mask. Measured 2026-09-11 on 27.0
    /// and on 26.6 alike, a panel ordered in and then added: every documented
    /// mask, 7 included, returned `[]` before the add and after it, while all
    /// bits set returned `[1]` before and `[]` after. So all bits, and the
    /// question it can answer: has the window left the desktops?
    static func isOutsideTheDesktops(_ window: NSWindow) -> Bool {
        guard window.isVisible, let calls, let copySpaces = calls.copySpaces,
              let spaces = copySpaces(calls.connection, 0x7fff_ffff, [window.windowNumber] as CFArray)?
                  .takeRetainedValue() as? [Int]
        else { return false }
        return spaces.isEmpty
    }
}
