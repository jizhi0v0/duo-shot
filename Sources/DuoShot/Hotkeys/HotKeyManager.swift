import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Chosen over `CGEventTap` for one decisive reason: **it needs no Accessibility
/// permission**. A screenshot tool already asks for Screen Recording; making the
/// user grant Accessibility as well, for nothing but keystrokes, is a bad trade.
///
/// The API is widely described online as "deprecated since 10.8". That is wrong.
/// It is absent from `CarbonEvents.h` in the SDK but exposed to Swift through the
/// `Carbon.HIToolbox` module and present in the .tbd; verified by compiling and
/// running against the macOS 27.0 SDK with a deployment target of 26.0 — returns
/// `noErr`, no deprecation diagnostic.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    struct Registration {
        let action: HotKeyAction
        let combo: KeyCombo
        let reference: EventHotKeyRef
        let handler: () -> Void
    }

    enum RegistrationError: Error, LocalizedError {
        case alreadyBound(to: HotKeyAction)
        case carbon(OSStatus)

        var errorDescription: String? {
            switch self {
            case .alreadyBound(let action): "already used by \(action.title)"
            case .carbon(let status): "RegisterEventHotKey failed (\(status))"
            }
        }
    }

    private(set) var registrations: [UInt32: Registration] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    // MARK: - Handler

    /// One shared Carbon handler for every hotkey, dispatched by `EventHotKeyID.id`.
    func installHandler() throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(), duoShotHotKeyHandler, 1, &spec, nil, &handlerRef)
        guard status == noErr else { throw RegistrationError.carbon(status) }
        Log.hotkeys.notice("carbon hot-key handler installed")
    }

    fileprivate func handle(id: UInt32) {
        guard let registration = registrations[id] else { return }
        Log.hotkeys.notice("fired \(registration.action.rawValue, privacy: .public)")
        registration.handler()
    }

    // MARK: - Registration

    @discardableResult
    func register(
        _ action: HotKeyAction, combo: KeyCombo, handler: @escaping () -> Void
    ) throws -> UInt32 {
        if let existing = registrations.first(where: { $0.value.combo == combo }) {
            throw RegistrationError.alreadyBound(to: existing.value.action)
        }
        try installHandler()

        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else {
            throw RegistrationError.carbon(status)
        }

        registrations[id] = Registration(
            action: action, combo: combo, reference: reference, handler: handler)
        Log.hotkeys.notice("""
            registered \(action.rawValue, privacy: .public) \
            as \(combo.displayString, privacy: .public)
            """)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.reference)
    }

    /// Releases every binding.
    ///
    /// Required while the shortcut recorder is open: a combo we have already
    /// registered globally never reaches a local event monitor, so without this
    /// the user cannot re-record their own existing shortcut.
    func unregisterAll() {
        for id in registrations.keys { unregister(id) }
    }

    func combo(for action: HotKeyAction) -> KeyCombo? {
        registrations.values.first { $0.action == action }?.combo
    }

    func unregister(_ action: HotKeyAction) {
        for (id, registration) in registrations where registration.action == action {
            unregister(id)
        }
    }

    /// `'DUOS'`
    private static let signature = OSType(0x4455_4F53)
}

/// Carbon requires a bare C function pointer, so this cannot capture anything
/// and cannot be `@MainActor`.
private let duoShotHotKeyHandler: EventHandlerUPP = { _, eventRef, _ in
    guard let eventRef else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }

    // Carbon hot-key events are delivered through the main run loop's event
    // target, so we are provably on the main thread. `assumeIsolated` rather
    // than a hop to DispatchQueue.main: the hop costs a frame of latency and,
    // more importantly, breaks any synchronous read of NSEvent.modifierFlags at
    // fire time.
    dispatchPrecondition(condition: .onQueue(.main))
    MainActor.assumeIsolated {
        HotKeyManager.shared.handle(id: hotKeyID.id)
    }
    return noErr
}
