import Foundation
import Observation

#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import os
import OSLog

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
    /// The Globe key turned out to be a modifier for another key, so the recording it
    /// started was never meant. Cancelled without the stop sound.
    case abandon
    /// The settings screen is waiting for a new binding, and this was the keystroke.
    case capture(keyCode: CGKeyCode, modifiers: CGEventFlags)
}

/// Everything the tap callback reads, kept where the tap's own thread can reach it.
private struct TapState: Sendable {
    var trigger: HotkeyTrigger = .globe
    var undoTrigger: HotkeyTrigger?
    var activationMode: HotkeyActivationMode = .pushToTalk
    var suppressTriggerKey = true
    var isRecording = false
    var isKeyDown = false
    var isCapturing = false
    /// Another key went down while Globe was held: Fn+Delete, Fn+arrow, a Globe
    /// shortcut. The release that follows must not act as a dictation's release.
    var globeUsedAsModifier = false
    /// Whether this Globe press started a recording rather than stopped one. Only a
    /// start can be taken back when the press turns out to be a modifier.
    var pressStartedRecording = false
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

    /// Says whether the tap exists, whether it is enabled, and whether macOS switched
    /// it off. No keystroke is ever written here.
    nonisolated static let log = Logger(subsystem: "com.inscribe.app", category: "Hotkey")

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
    /// A recording started by the Globe key should be dropped quietly: the key was
    /// being used as a modifier.
    var onAbandon: (() -> Void)?
    /// A keystroke arrived while the settings screen was recording a new binding.
    var onCapture: ((CGKeyCode, CGEventFlags) -> Void)?

    // MARK: - Tap Internals

    /// Read and written on the tap's thread, seeded from the main actor.
    private let tapState = OSAllocatedUnfairLock(initialState: TapState())

    /// Carries decisions from the tap thread to the main actor in order.
    private let emit: AsyncStream<HotkeyAction>.Continuation

    @ObservationIgnored nonisolated(unsafe) private var pump: Task<Void, Never>?

    /// When the last release was acted on, so a press hard on its heels can be named
    /// for what it is.
    private var lastRelease: ContinuousClock.Instant?

    /// A press this soon after a release did not come from a human hand.
    private static let chatterWindow: Duration = .milliseconds(250)

    // deinit is nonisolated and has to tear the tap down, so this carries the
    // isolation opt-out rather than the whole class.
    @ObservationIgnored nonisolated(unsafe) private var host: TapHost?

    /// The tap port, kept separately from the host that runs it.
    ///
    /// macOS can switch a tap off in the same millisecond it is created, and the
    /// callback saying so arrives on the tap's own thread — which `TapHost.init`
    /// starts before returning, so `host` is still nil when it lands. Re-enabling
    /// through `host` dropped that first call and the tap stayed dead for the life of
    /// the app, while `isRunning` went on reporting it as listening.
    ///
    /// Read on the tap's thread and replaced on the main thread, so it lives behind a
    /// lock.
    private let tapPort = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)

    // MARK: - Lifecycle

    /// The one monitor in the process.
    ///
    /// `ScribeApp` wires the launch callback inside its `init`, which captures a copy
    /// of the App struct — and a `@State` default built in that copy is not the
    /// instance SwiftUI installs. Launch armed one monitor while the menu bar and the
    /// Settings screen observed another, so the tap was created against an object
    /// nothing else could see, and every screen reported "Not listening" while the
    /// Globe key did nothing. One instance makes the two the same object.
    static let shared = GlobalHotkeyMonitor()

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
        tapPort.withLockUnchecked { $0 = nil }
    }

    // MARK: - Public API

    /// Install the event tap. Returns false when Accessibility trust is missing.
    @discardableResult
    func start() -> Bool {
        stop()

        guard AccessibilityPermission.isTrusted else {
            lastError = "Accessibility access is required to detect the hotkey."
            isRunning = false
            Self.log.error("not trusted, no tap")
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
            Self.log.error("tapCreate returned nil")
            return false
        }

        // Assigned before the host exists, so the thread the host starts can always
        // find it.
        tapPort.withLockUnchecked { $0 = tap }
        let host = TapHost(tap: tap)
        self.host = host

        // A tap can be created and still never switch on — after a reinstall, the
        // Accessibility grant belongs to the old binary — and it then hears nothing.
        // This used to report "Listening" regardless, and since every retry only runs
        // when the monitor says it is not running, nothing ever rebuilt it.
        guard host.waitUntilEnabled() else {
            Self.log.error("tap never switched on — Accessibility is probably not granted to this build")
            stop()
            lastError = "The hotkey could not switch on. In System Settings → Privacy & Security → Accessibility, remove Inscribe and add it again."
            return false
        }

        isRunning = true
        lastError = nil
        Self.log.notice("tap installed, trigger=\(String(describing: self.trigger), privacy: .public), mode=\(self.activationMode.rawValue, privacy: .public), suppress=\(self.suppressTriggerKey, privacy: .public)")
        return true
    }

    /// Remove the event tap.
    func stop() {
        host?.invalidate()
        host = nil
        tapPort.withLockUnchecked { $0 = nil }
        tapState.withLock { $0.isKeyDown = false }
        isRunning = false
    }

    /// Report the next keystrokes to `handler` instead of acting on them, so the
    /// settings screen can record a new binding.
    ///
    /// Read from the tap rather than from an `NSEvent` monitor in the settings window:
    /// the tap sees every keystroke on the machine, so the user's chosen combination
    /// is captured whether or not that window happens to hold keyboard focus. Every
    /// keystroke is swallowed while this is on, so none of them leak into the app
    /// behind the settings window.
    func beginCapture(_ handler: @escaping (CGKeyCode, CGEventFlags) -> Void) {
        onCapture = handler
        if !isRunning { start() }
        tapState.withLock { $0.isCapturing = true }
    }

    /// Go back to treating keystrokes as hotkeys.
    func endCapture() {
        tapState.withLock { $0.isCapturing = false }
        onCapture = nil
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
            // Recording a new binding takes the keyboard whole, so the combination the
            // user presses cannot also fire the old hotkey or type into another app.
            // Modifiers on their own pass through: they are the user still assembling
            // the combination, and the Globe key must not start a recording here.
            if state.isCapturing {
                guard type == .keyDown, !isRepeat else { return (type == .keyDown, nil) }
                return (true, .capture(keyCode: keyCode, modifiers: flags))
            }

            switch type {
            case .flagsChanged:
                guard case .globe = state.trigger, keyCode == fnKeyCode else { return (false, nil) }

                // On a flagsChanged for the Fn key, the Fn bit tells press from release.
                if flags.contains(.maskSecondaryFn) {
                    guard !state.isKeyDown else { return (state.suppressTriggerKey, nil) }
                    state.isKeyDown = true
                    state.globeUsedAsModifier = false
                    state.pressStartedRecording = !state.isRecording
                    return (state.suppressTriggerKey, edge(pressed: true, mode: state.activationMode))
                } else {
                    guard state.isKeyDown else { return (state.suppressTriggerKey, nil) }
                    state.isKeyDown = false
                    if state.globeUsedAsModifier {
                        state.globeUsedAsModifier = false
                        return (state.suppressTriggerKey, nil)
                    }
                    return (state.suppressTriggerKey, edge(pressed: false, mode: state.activationMode))
                }

            case .keyDown:
                // Escape abandons an in-flight recording without producing text.
                if keyCode == escapeKeyCode, state.isRecording { return (true, .cancel) }

                // Any other key while Globe is held means Globe is a modifier — Fn+Delete,
                // Fn+arrow keys, a Globe shortcut — and the recording its press started
                // was never wanted. The key itself goes through to the app untouched.
                // A press that stopped a toggle recording has already delivered it, so
                // there is nothing to take back.
                if case .globe = state.trigger, state.isKeyDown, !state.globeUsedAsModifier {
                    state.globeUsedAsModifier = true
                    let wasStart = state.activationMode == .pushToTalk || state.pressStartedRecording
                    return (false, wasStart ? .abandon : nil)
                }

                // Checked before the record trigger so the two can never collide. The
                // auto-repeat of a held undo shortcut is swallowed with it; letting it
                // through sent the combination on to the app in front.
                if case let .combo(undoKey, undoModifiers) = state.undoTrigger,
                   keyCode == undoKey,
                   flags.intersection(relevantModifiers) == undoModifiers.intersection(relevantModifiers) {
                    return (true, isRepeat ? nil : .undo)
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
        // A tap switched off by user input is routine; a timeout means the callback
        // missed its deadline and keystrokes were dropped, which is not.
        if byTimeout {
            Self.log.error("tap disabled by TIMEOUT, re-enabling")
        } else {
            Self.log.notice("tap disabled by user input, re-enabling")
        }
        guard let port = tapPort.withLockUnchecked({ $0 }) else {
            Self.log.error("no tap port to re-enable")
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            Self.log.error("tap would not switch back on")
        }

        // A release that happened while the tap was off never arrived, which left the
        // key marked as held: the next press was swallowed as a repeat, and the
        // recording ran on until the release after that. Ask the hardware instead.
        releaseIfKeyIsUp()
    }

    /// Send the release the tap missed, if the trigger key is no longer down.
    private nonisolated func releaseIfKeyIsUp() {
        let (trigger, held) = tapState.withLock { ($0.trigger, $0.isKeyDown) }
        guard held else { return }

        let isDown: Bool = switch trigger {
        case .globe:
            CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        case let .combo(keyCode, _):
            CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
        guard !isDown else { return }

        let action = tapState.withLock { state -> HotkeyAction? in
            guard state.isKeyDown else { return nil }
            state.isKeyDown = false
            if state.globeUsedAsModifier {
                state.globeUsedAsModifier = false
                return nil
            }
            return edge(pressed: false, mode: state.activationMode)
        }
        if let action {
            Self.log.notice("trigger key was released while the tap was off — releasing now")
            emit.yield(action)
        }
    }

    // MARK: - Main Actor

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .activate:
            // Named, not acted on. The Globe key spent part of one morning sending a
            // release and another press every hundred and twenty milliseconds while
            // held, which ended each recording as fast as it could start — and looked
            // from outside exactly like the key doing nothing. Holding the release back
            // to defend against it cost a quarter of a second on every dictation, for a
            // fault that stopped on its own, so the defence is gone and only the
            // reading of it remains.
            if let lastRelease, ContinuousClock.now - lastRelease < Self.chatterWindow {
                Self.log.error("a press followed a release within \(Self.chatterWindow, privacy: .public) — the Globe key is chattering")
            }
            onActivate?()

        case .deactivate:
            lastRelease = .now
            onDeactivate?()

        case .toggle:
            onToggle?()
        case .cancel: onCancel?()
        case .abandon: onAbandon?()
        case .undo: onUndo?()
        case let .capture(keyCode, modifiers): onCapture?(keyCode, modifiers)
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
    private var enabled = false
    private let ready = DispatchSemaphore(value: 0)

    init(tap: CFMachPort) {
        self.tap = tap

        nonisolated(unsafe) let tap = tap
        let host = self

        let thread = Thread {
            guard let loop: CFRunLoop = CFRunLoopGetCurrent() else {
                GlobalHotkeyMonitor.log.error("tap thread has no run loop")
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let isEnabled = CGEvent.tapIsEnabled(tap: tap)
            host.publish(loop, enabled: isEnabled)

            // The one line worth keeping: a tap that reports itself installed but not
            // enabled receives nothing.
            GlobalHotkeyMonitor.log.notice("tap enabled=\(isEnabled, privacy: .public)")

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

    /// Whether the tap switched on, once its thread has tried.
    ///
    /// Blocks the caller for the few milliseconds the thread takes to start, and at
    /// most half a second. A thread that has not answered by then counts as a tap
    /// that did not switch on.
    func waitUntilEnabled() -> Bool {
        guard ready.wait(timeout: .now() + .milliseconds(500)) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    private func publish(_ loop: CFRunLoop, enabled: Bool) {
        lock.lock()
        self.loop = loop
        self.enabled = enabled
        lock.unlock()
        ready.signal()
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
