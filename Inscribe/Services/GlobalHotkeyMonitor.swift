import Foundation
import Observation

#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import os

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

private let fnKeyCode = CGKeyCode(kVK_Function)
private let escapeKeyCode = CGKeyCode(kVK_Escape)

/// Modifier bits we compare against, ignoring caps lock and device-specific noise.
private let relevantModifiers: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift
]

/// What a tapped keystroke turned out to mean.
private enum HotkeyAction: Sendable {
    case activate, deactivate, toggle, cancel, undo
}

/// Everything the tap callback reads, kept where the tap's own thread can reach it.
private struct TapState: Sendable {
    var trigger: HotkeyTrigger = .globe
    var undoTrigger: HotkeyTrigger?
    var activationMode: HotkeyActivationMode = .pushToTalk
    var suppressTriggerKey = true
    var isRecording = false
    var isKeyDown = false
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

    // MARK: - Configuration

    /// The key that activates recording.
    var trigger: HotkeyTrigger = .globe {
        didSet {
            let value = trigger
            tapState.withLock { $0.trigger = value }
        }
    }

    /// Hold-to-talk or press-to-toggle.
    var activationMode: HotkeyActivationMode = .pushToTalk {
        didSet {
            let value = activationMode
            tapState.withLock { $0.activationMode = value }
        }
    }

    /// Optional second binding that takes back the last insertion.
    var undoTrigger: HotkeyTrigger? {
        didSet {
            let value = undoTrigger
            tapState.withLock { $0.undoTrigger = value }
        }
    }

    /// Swallow the trigger keystroke so it does not reach the focused app.
    ///
    /// Reliable for ordinary key combinations. For the Globe key the system's
    /// "Press 🌐 to" behaviour is handled below the event tap, so setting that to
    /// "Do Nothing" in System Settings is the dependable fix.
    var suppressTriggerKey = true {
        didSet {
            let value = suppressTriggerKey
            tapState.withLock { $0.suppressTriggerKey = value }
        }
    }

    /// Whether a dictation is running, which is the only time Escape should cancel.
    ///
    /// Pushed in rather than pulled: the tap answers on its own thread, and asking the
    /// main actor at keystroke time is exactly the wait this class exists to avoid.
    var isRecording = false {
        didSet {
            let value = isRecording
            tapState.withLock { $0.isRecording = value }
        }
    }

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

    // MARK: - Tap Internals

    /// Read and written on the tap's thread, seeded from the main actor.
    private let tapState = OSAllocatedUnfairLock(initialState: TapState())

    /// Carries decisions from the tap thread to the main actor in order.
    private let emit: AsyncStream<HotkeyAction>.Continuation

    nonisolated(unsafe) private var pump: Task<Void, Never>?

    // deinit is nonisolated and has to tear the tap down, so this carries the
    // isolation opt-out rather than the whole class.
    nonisolated(unsafe) private var host: TapHost?

    // MARK: - Lifecycle

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyAction.self)
        emit = continuation
        pump = Task { @MainActor [weak self] in
            for await action in stream {
                self?.perform(action)
            }
        }
    }

    deinit {
        emit.finish()
        pump?.cancel()
        host?.invalidate()
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

        // Seeded before the tap exists, so the first keystroke cannot beat the config.
        let seed = TapState(
            trigger: trigger,
            undoTrigger: undoTrigger,
            activationMode: activationMode,
            suppressTriggerKey: suppressTriggerKey,
            isRecording: isRecording,
            isKeyDown: false
        )
        tapState.withLock { $0 = seed }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastError = "Could not create the event tap. Grant Accessibility access and try again."
            isRunning = false
            return false
        }

        host = TapHost(tap: tap)
        isRunning = true
        lastError = nil
        print("[GlobalHotkeyMonitor] Event tap installed on its own thread, trigger=\(trigger), mode=\(activationMode.rawValue)")
        return true
    }

    /// Remove the event tap.
    func stop() {
        host?.invalidate()
        host = nil
        tapState.withLock { $0.isKeyDown = false }
        isRunning = false
    }

    // MARK: - Tap Thread

    /// Decide what a tapped keystroke means. Returns true when it should be swallowed.
    ///
    /// Runs on the tap's thread and touches nothing but the lock, so a busy main actor
    /// can never hold up a keystroke. Any resulting action is queued for the main actor.
    fileprivate nonisolated func decide(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        let (swallow, action) = tapState.withLock { state -> (Bool, HotkeyAction?) in
            switch type {
            case .flagsChanged:
                guard case .globe = state.trigger, keyCode == fnKeyCode else { return (false, nil) }

                // On a flagsChanged for the Fn key, the Fn bit tells press from release.
                if flags.contains(.maskSecondaryFn) {
                    guard !state.isKeyDown else { return (state.suppressTriggerKey, nil) }
                    state.isKeyDown = true
                    return (state.suppressTriggerKey, edge(pressed: true, mode: state.activationMode))
                } else {
                    guard state.isKeyDown else { return (state.suppressTriggerKey, nil) }
                    state.isKeyDown = false
                    return (state.suppressTriggerKey, edge(pressed: false, mode: state.activationMode))
                }

            case .keyDown:
                // Escape abandons an in-flight recording without producing text.
                if keyCode == escapeKeyCode, state.isRecording { return (true, .cancel) }

                // Checked before the record trigger so the two can never collide.
                if case let .combo(undoKey, undoModifiers) = state.undoTrigger,
                   keyCode == undoKey,
                   flags.intersection(relevantModifiers) == undoModifiers.intersection(relevantModifiers),
                   !isRepeat {
                    return (true, .undo)
                }

                guard case let .combo(triggerKey, triggerModifiers) = state.trigger,
                      keyCode == triggerKey,
                      flags.intersection(relevantModifiers) == triggerModifiers.intersection(relevantModifiers)
                else { return (false, nil) }

                // Ignore the repeat stream produced by holding the key.
                guard !isRepeat, !state.isKeyDown else { return (state.suppressTriggerKey, nil) }
                state.isKeyDown = true
                return (state.suppressTriggerKey, edge(pressed: true, mode: state.activationMode))

            case .keyUp:
                guard case let .combo(triggerKey, _) = state.trigger,
                      keyCode == triggerKey,
                      state.isKeyDown
                else { return (false, nil) }

                state.isKeyDown = false
                return (state.suppressTriggerKey, edge(pressed: false, mode: state.activationMode))

            default:
                return (false, nil)
            }
        }

        if let action { emit.yield(action) }
        return swallow
    }

    /// Re-enable a tap that macOS switched off.
    ///
    /// `.tapDisabledByUserInput` is routine. A timeout is not: it means the callback
    /// missed its deadline, and every keystroke queued behind it was dropped — so it
    /// gets said out loud rather than quietly patched over.
    fileprivate nonisolated func tapWasDisabled(byTimeout: Bool) {
        print("[GlobalHotkeyMonitor] Tap disabled by \(byTimeout ? "TIMEOUT" : "user input"), re-enabling")
        host?.reenable()
    }

    // MARK: - Main Actor

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .activate: onActivate?()
        case .deactivate: onDeactivate?()
        case .toggle: onToggle?()
        case .cancel: onCancel?()
        case .undo: onUndo?()
        }
    }
}

/// Translate a physical press or release into the action the current mode wants.
private func edge(pressed: Bool, mode: HotkeyActivationMode) -> HotkeyAction? {
    switch mode {
    case .pushToTalk:
        pressed ? .activate : .deactivate
    case .toggle:
        // Only the press edge matters; the release is the user letting go.
        pressed ? .toggle : nil
    }
}

// MARK: - Tap Thread Host

/// Owns the tap and the thread it runs on.
///
/// The tap must not share a run loop with anything that can block. On the main run
/// loop one synchronous SwiftData save is enough to push the callback past the system's
/// deadline, at which point macOS drops the keystrokes queued behind it and switches
/// the tap off — for every app on the machine, not just this one.
private final class TapHost: @unchecked Sendable {
    private let tap: CFMachPort
    private let lock = NSLock()
    private var loop: CFRunLoop?

    init(tap: CFMachPort) {
        self.tap = tap

        nonisolated(unsafe) let tap = tap
        let host = self

        let thread = Thread {
            guard let loop: CFRunLoop = CFRunLoopGetCurrent() else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            host.publish(loop)

            CFRunLoopRun()

            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        thread.name = "com.inscribe.hotkey-tap"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
    }

    func reenable() {
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func invalidate() {
        CGEvent.tapEnable(tap: tap, enable: false)
        // Invalidating the port would end the run loop on its own, by leaving the
        // thread with no sources. Stopping it explicitly just gets there sooner.
        if let loop = currentLoop() { CFRunLoopStop(loop) }
        CFMachPortInvalidate(tap)
    }

    private func publish(_ loop: CFRunLoop) {
        lock.lock()
        defer { lock.unlock() }
        self.loop = loop
    }

    private func currentLoop() -> CFRunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return loop
    }
}

// MARK: - C Callback

/// Runs on the tap's own thread. Reads what it needs from the event, decides, and
/// returns — the work the decision causes happens on the main actor afterwards.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.tapWasDisabled(byTimeout: type == .tapDisabledByTimeout)
        return nil
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    let swallow = monitor.decide(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    return swallow ? nil : Unmanaged.passUnretained(event)
}
#endif
