import AppKit

/// The mouse clicks made while a take is running, for the click timeline.
///
/// Two `NSEvent` monitors, because each sees half: the global monitor gets
/// events delivered to *other* applications, the local one those delivered to
/// DuoShot's own windows. Measured on a machine with no Accessibility or Input
/// Monitoring grant, together they caught 20 of 20 clicks including 0 ms ones,
/// with `timestamp` within 0.1–3.9 ms of when the event was posted and the
/// position exact. Polling `NSEvent.pressedMouseButtons` missed fast clicks
/// outright, and a listen-only `CGEventTap` without Input Monitoring was
/// silently given nothing. Mouse buttons only — never a key.
final class ClickRecorder {
    nonisolated struct Event: Sendable {
        /// `NSEvent.timestamp`: seconds on the host clock (mach absolute time),
        /// the clock ScreenCaptureKit stamps frames with.
        let timestamp: Double
        /// Global points, origin top-left of the main display — the space the
        /// command line and `kCGWindowBounds` speak.
        let locationInCGGlobal: CGPoint
        let isDown: Bool
        let button: String
        let clickCount: Int
    }

    private(set) var events: [Event] = []
    private var global: Any?
    private var local: Any?

    private static let mask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
    ]

    func start() {
        guard global == nil else { return }
        events.removeAll()
        global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.note(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.note(event) }
            return event
        }
    }

    /// Stops listening and hands over what was heard.
    func stop() -> [Event] {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
        return events
    }

    private func note(_ event: NSEvent) {
        // A global event has no window and its location is already in screen
        // coordinates; a local one is in its window's.
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? event.locationInWindow
        let isDown: Bool
        let button: String
        switch event.type {
        case .leftMouseDown: (isDown, button) = (true, "left")
        case .leftMouseUp: (isDown, button) = (false, "left")
        case .rightMouseDown: (isDown, button) = (true, "right")
        case .rightMouseUp: (isDown, button) = (false, "right")
        case .otherMouseDown: (isDown, button) = (true, "other")
        default: (isDown, button) = (false, "other")
        }
        events.append(Event(
            timestamp: event.timestamp, locationInCGGlobal: DisplayGeometry.flipped(location),
            isDown: isDown,
            button: button, clickCount: event.clickCount))
    }
}
