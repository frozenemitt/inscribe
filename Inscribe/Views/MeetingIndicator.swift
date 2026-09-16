import SwiftUI

#if os(macOS)
import AppKit

/// A small panel that stays on screen for the length of a meeting.
///
/// A meeting runs for an hour with nothing to show it is still listening. The
/// menu bar icon changes shape, which tells you a meeting is open, not that the
/// microphone is still hearing anything — and the difference between those two only
/// becomes apparent when you play the recording back.
///
/// Deliberately small and mute: the band, the clock, and nothing else. A dictation
/// panel is worth reading for the twenty seconds it exists; this one has to be
/// bearable for an hour.
@MainActor
final class MeetingIndicatorController {

    private var panel: NSPanel?
    private var glassView: NSGlassEffectView?
    private let model = MeetingIndicatorModel()
    private let settings: AppSettings
    private var moveObserver: (any NSObjectProtocol)?
    /// Held so the desktop-change notifications keep arriving for the life of the app.
    private var spaceObserver: (any NSObjectProtocol)?

    /// What the panel's two buttons do. Set by whoever owns the meeting.
    var onPauseOrResume: (() -> Void)?
    var onStop: (() -> Void)?

    static let width: CGFloat = 232
    static let height: CGFloat = 64

    /// Visible over full-screen apps and on every desktop: a meeting is usually a
    /// full-screen call, and that is exactly when the indicator is wanted.
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        // Said again at the start of every meeting, not once when the panel was built.
        // Same reasoning as the dictation panel: a panel that has lost this is drawn on
        // one desktop and is invisible on every other, and only quitting the app builds
        // a new one.
        panel?.collectionBehavior = Self.collectionBehavior
        position(panel)
        applyTint()
        panel?.orderFrontRegardless()
    }

    func update(spectrum: [Double], seconds: TimeInterval, isPaused: Bool) {
        model.spectrum = spectrum
        model.isPaused = isPaused
        model.seconds = seconds
        model.contentOpacity = settings.overlayContentOpacity
        applyTint()
    }

    func hide() {
        panel?.orderOut(nil)
        model.spectrum = []
    }

    /// Thin the pane, not the clock. Same reasoning as the dictation panel: the
    /// content is a sibling above the glass, so fading the glass leaves it alone.
    private func applyTint() {
        guard let glassView else { return }
        let wanted = settings.overlayOpacity
        guard abs(glassView.alphaValue - wanted) > 0.001 else { return }
        glassView.alphaValue = wanted
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow. On a light desktop a drop shadow around a dark panel reads as a
        // dark border drawn round it — and it is invisible in dark mode, which is why
        // the edge only ever looked wrong in one of the two.
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        model.pauseOrResume = { [weak self] in self?.onPauseOrResume?() }
        model.stop = { [weak self] in self?.onStop?() }

        let hosting = NSHostingView(rootView: MeetingIndicatorView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.style = .clear
        glass.cornerRadius = Self.height / 2
        glass.tintColor = NSColor.black.withAlphaComponent(0.22)
        self.glassView = glass

        let container = NSView()
        container.addSubview(glass)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.settings.meetingIndicatorOriginX = panel.frame.origin.x
                self.settings.meetingIndicatorOriginY = panel.frame.origin.y
            }
        }

        // Said again whenever the user changes desktop.
        //
        // show() runs once per meeting, so a panel that lost its collection behaviour
        // after the meeting began would stay on one desktop for the rest of the hour,
        // which is the whole failure this panel exists to prevent. A desktop change is
        // the only moment that costs anything and it happens a few times an hour. The
        // window server applies the assignment within a frame, and the panel does not
        // have to be reordered, so nothing blinks.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.collectionBehavior = Self.collectionBehavior
            }
        }

        return panel
    }

    /// Where the user left it, or the top right — out of the way of the thing the
    /// meeting is actually about.
    private func position(_ panel: NSPanel?) {
        guard let panel else { return }

        if let x = settings.meetingIndicatorOriginX, let y = settings.meetingIndicatorOriginY,
           NSScreen.screens.contains(where: {
               $0.frame.intersects(NSRect(x: x, y: y, width: Self.width, height: Self.height))
           }) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - Self.width - 24,
            y: frame.maxY - Self.height - 24
        ))
    }
}

@MainActor
@Observable
final class MeetingIndicatorModel {
    var spectrum: [Double] = []
    var isPaused = false
    var seconds: TimeInterval = 0
    var contentOpacity: Double = 1.0

    /// Handed in by the controller so the buttons can reach the meeting.
    var pauseOrResume: () -> Void = {}
    var stop: () -> Void = {}
}

private struct MeetingIndicatorView: View {
    @Bindable var model: MeetingIndicatorModel

    var body: some View {
        VStack(spacing: 6) {
            ListeningBar(spectrum: model.spectrum, isProcessing: false)
                // Everything that is not a button lets the click through to the window,
                // which is what drags the panel. SwiftUI content swallowing the mouse
                // is why the dictation panel needed a drag view underneath it.
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                Image(systemName: model.isPaused ? "pause.fill" : "record.circle")
                    .font(.caption)
                    .foregroundStyle(model.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))

                Text(clock)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Button(action: model.pauseOrResume) {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                }
                .help(model.isPaused ? "Resume" : "Pause")

                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                }
                .help("Stop and save")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.primary)
        }
        .opacity(model.contentOpacity)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: MeetingIndicatorController.width, height: MeetingIndicatorController.height)
        .environment(\.colorScheme, .dark)
    }

    private var clock: String {
        let total = Int(model.seconds)
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
#endif
