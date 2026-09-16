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

    static let width: CGFloat = 188
    static let height: CGFloat = 54

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        position(panel)
        applyTint()
        panel?.orderFrontRegardless()
    }

    func update(spectrum: [Double], seconds: TimeInterval, isPaused: Bool) {
        model.spectrum = spectrum
        model.isPaused = isPaused
        model.seconds = seconds
        applyTint()
    }

    func hide() {
        panel?.orderOut(nil)
        model.spectrum = []
    }

    private func applyTint() {
        panel?.alphaValue = settings.overlayOpacity
        glassView?.tintColor = NSColor.black.withAlphaComponent(0.22)
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
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: MeetingIndicatorView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.style = .clear
        glass.cornerRadius = Self.height / 2
        glass.contentView = hosting
        self.glassView = glass

        let container = MeetingDragHandleView()
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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

private final class MeetingDragHandleView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
@Observable
final class MeetingIndicatorModel {
    var spectrum: [Double] = []
    var isPaused = false
    var seconds: TimeInterval = 0
}

private struct MeetingIndicatorView: View {
    @Bindable var model: MeetingIndicatorModel

    var body: some View {
        VStack(spacing: 6) {
            ListeningBar(spectrum: model.spectrum, isProcessing: false)

            HStack(spacing: 6) {
                Image(systemName: model.isPaused ? "pause.fill" : "record.circle")
                    .font(.caption)
                    .foregroundStyle(model.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))

                Text(clock)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
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
