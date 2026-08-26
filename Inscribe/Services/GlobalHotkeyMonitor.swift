import Foundation
import Observation

#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// How a hotkey starts and stops a recording.
enum HotkeyActivationMode: String, CaseIterable, Identifiable, Sendable {
    /// Hold the key to record, release to transcribe.
    case pushToTalk
    /// Press once to start, press again to stop.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: "Hold to talk"
        case .toggle: "Press to start, press to stop"
        }
    }
}

/// Which key activates recording.
enum HotkeyTrigger: Equatable, Sendable {
    /// The Globe / Fn key on its own.
    case globe
    /// A conventional key plus modifiers, e.g. ⌃⌥⌘C.
    case combo(keyCode: CGKeyCode, modifiers: CGEventFlags)
}

/// System-wide hotkey monitor built on a CGEventTap.
///
/// Carbon's `RegisterEventHotKey` cannot bind the Globe/Fn key and gives no key-up
/// callback, so it supports neither of the two things we need. An event tap sees the
/// raw `.flagsChanged` stream, which carries both.
///
/// Requires Accessibility trust — `CGEvent.tapCreate` returns nil without it.
@MainActor
@Observable
final class GlobalHotkeyMonitor {

    // MARK: - Observable State

    private(set) var isRunning = false
    private(set) var lastError: String?

    /// True while the trigger key is physically held down.
    private(set) var isKeyDown = false

    // MARK: - Configuration

    /// The key that activates recording. Changing it restarts the tap.
    var trigger: HotkeyTrigger = .globe {
        didSet {
            guard trigger != oldValue, isRunning else { return }
            restart()
        }
    }

    /// Hold-to-talk or press-to-toggle.
    var activationMode: HotkeyActivationMode = .pushToTalk

    /// Swallow the trigger keystroke so it does not reach the focused app.
    ///
    /// Reliable for ordinary key combinations. For the Globe key the system's
    /// "Press 🌐 to" behaviour is handled below the event tap, so setting that to
    /// "Do Nothing" in System Settings is the dependable fix.
    var suppressTriggerKey = true

    // MARK: - Callbacks

    /// Recording should begin.
    var onActivate: (() -> Void)?
    /// Recording should end and transcribe. Push-to-talk only.
    var onDeactivate: (() -> Void)?
    /// Recording should flip state. Toggle mode only.
    var onToggle: (() -> Void)?
    /// The user cancelled with Escape while recording.
    var onCancel: (() -> Void)?

    /// The undo shortcut was pressed.
    var onUndo: (() -> Void)?

    /// Optional second binding that takes back the last insertion.
    var undoTrigger: HotkeyTrigger?

    /// Asked by the tap to decide whether Escape should currently cancel.
    var isRecordingProvider: (() -> Bool)?

    // MARK: - Tap Internals

    // Written only on the main actor, but deinit is nonisolated and has to tear the
    // tap down, so these carry the isolation opt-out rather than the whole class.
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    private static let fnKeyCode: CGKeyCode = CGKeyCode(kVK_Function)
    private static let escapeKeyCode: CGKeyCode = CGKeyCode(kVK_Escape)

    /// Modifier bits we compare against, ignoring caps lock and device-specific noise.
    private static let relevantModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift
    ]

    // MARK: - Lifecycle

    init() {}

    deinit {
        // The tap holds no MainActor state that needs teardown on the main actor;
        // invalidate directly so we do not capture self in an escaping closure.
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    // MARK: - Public API

    /// Install the event tap. Returns false when Accessibility trust is missing.
    @discardableResult
    func start() -> Bool {
        stop()

        guard AccessibilityPermission.isTrusted else {
            lastError = "Accessibility access is required to detect the hotkey."
            isRunning = false
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: context
        ) else {
            lastError = "Could not create the event tap. Grant Accessibility access and try again."
            isRunning = false
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        lastError = nil
        print("[GlobalHotkeyMonitor] Event tap installed, trigger=\(trigger), mode=\(activationMode.rawValue)")
        return true
    }

    /// Remove the event tap.
    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        isKeyDown = false
        isRunning = false
    }

    private func restart() {
        guard isRunning else { return }
        start()
    }

    /// Re-enable a tap that macOS switched off after a slow callback.
    fileprivate func reenableAfterTimeout() {
        guard let eventTap else { return }
        print("[GlobalHotkeyMonitor] Tap disabled by timeout, re-enabling")
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    // MARK: - Event Handling

    /// Decide what a tapped keystroke means. Returns true when it should be swallowed.
    ///
    /// Takes plain values rather than the `CGEvent`: the event is not `Sendable` and
    /// must not cross from the tap's thread into the main actor.
    fileprivate func handle(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        switch type {
        case .flagsChanged:
            return handleFlagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:
            return handleKeyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        case .keyUp:
            return handleKeyUp(keyCode: keyCode)
        default:
            return false
        }
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard case .globe = trigger else { return false }
        guard keyCode == Self.fnKeyCode else { return false }

        // On a flagsChanged for the Fn key, the Fn bit tells press from release.
        let isPressed = flags.contains(.maskSecondaryFn)

        if isPressed {
            guard !isKeyDown else { return suppressTriggerKey }
            isKeyDown = true
            fire(pressed: true)
        } else {
            guard isKeyDown else { return suppressTriggerKey }
            isKeyDown = false
            fire(pressed: false)
        }

        return suppressTriggerKey
    }

    private func handleKeyDown(keyCode: CGKeyCode, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        // Escape abandons an in-flight recording without producing text.
        if keyCode == Self.escapeKeyCode, isRecordingProvider?() == true {
            onCancel?()
            return true
        }

        // Checked before the record trigger so the two can never collide.
        if case let .combo(undoKey, undoModifiers) = undoTrigger,
           keyCode == undoKey,
           flags.intersection(Self.relevantModifiers) == undoModifiers.intersection(Self.relevantModifiers),
           !isRepeat {
            onUndo?()
            return true
        }

        guard case let .combo(triggerKey, triggerModifiers) = trigger else { return false }
        guard keyCode == triggerKey else { return false }

        let pressed = flags.intersection(Self.relevantModifiers)
        guard pressed == triggerModifiers.intersection(Self.relevantModifiers) else { return false }

        // Ignore the repeat stream produced by holding the key.
        guard !isRepeat else { return suppressTriggerKey }

        guard !isKeyDown else { return suppressTriggerKey }
        isKeyDown = true
        fire(pressed: true)
        return suppressTriggerKey
    }

    private func handleKeyUp(keyCode: CGKeyCode) -> Bool {
        guard case let .combo(triggerKey, _) = trigger else { return false }
        guard keyCode == triggerKey, isKeyDown else { return false }

        isKeyDown = false
        fire(pressed: false)
        return suppressTriggerKey
    }

    /// Translate a physical press or release into the callback the current mode wants.
    private func fire(pressed: Bool) {
        switch activationMode {
        case .pushToTalk:
            if pressed {
                onActivate?()
            } else {
                onDeactivate?()
            }
        case .toggle:
            // Only the press edge matters; the release is the user letting go.
            if pressed {
                onToggle?()
            }
        }
    }
}

// MARK: - C Callback

/// Runs on the tap's run loop thread. Keep it short — a slow callback makes macOS
/// disable the tap, which is why `.tapDisabledByTimeout` is handled here.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            monitor.reenableAfterTimeout()
        }
        return nil
    }

    // Everything the handler needs is read here, on the tap's own thread, so the
    // non-Sendable CGEvent itself never crosses into the main actor.
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    // The tap source is attached to the main run loop, so this is already the main
    // thread; the hop is a formality the compiler needs, not a thread change.
    let shouldSwallow = MainActor.assumeIsolated {
        monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }

    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
#endif
