import SwiftUI

#if os(macOS)
import AppKit

/// A floating panel showing what Inscribe is hearing, while you hold the key.
///
/// Feedback used to be a sound and a menu bar icon, which tells you recording started
/// but not whether the words are landing. Seeing the text arrive is the difference
/// between trusting the dictation and repeating yourself.
///
/// It is glass rather than an opaque card, and the user sets how solid: the panel sits
/// over the thing being dictated into, and a pane you can read through lets you keep
/// both in view. Drag it anywhere; where you leave it is where it comes back.
@MainActor
final class DictationOverlayController {

    private var panel: NSPanel?
    private let model = OverlayModel()
    private let settings: AppSettings
    /// Held so the panel's move notifications keep arriving for the life of the app.
    private var moveObserver: (any NSObjectProtocol)?

    static let minimumHeight: CGFloat = 92
    static let width: CGFloat = 460

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Presentation

    func show() {
        model.text = ""
        model.isProcessing = false
        model.opacity = settings.overlayOpacity

        if panel == nil {
            panel = makePanel()
        }

        // Back to one line's worth, so each dictation grows from the same place.
        if let panel, panel.frame.height != Self.minimumHeight {
            var frame = panel.frame
            frame.origin.y = frame.maxY - Self.minimumHeight
            frame.size.height = Self.minimumHeight
            panel.setFrame(frame, display: false)
        }

        position(panel)
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key status would pull
        // focus out of the app being dictated into, which is where the text must land.
        panel?.orderFrontRegardless()
    }

    func update(text: String) {
        model.text = text
        growToFit()
    }

    func showProcessing() {
        model.isProcessing = true
    }

    func hide() {
        panel?.orderOut(nil)
        model.text = ""
        model.isProcessing = false
    }

    /// Forget a dragged position, so the panel returns to the bottom of the screen.
    ///
    /// A panel dragged to a screen that is later unplugged would otherwise open
    /// somewhere the user cannot see, with no way back to it.
    func resetPosition() {
        settings.overlayOriginX = nil
        settings.overlayOriginY = nil
        position(panel)
    }

    /// Match the panel's height to the text, growing upward from a fixed bottom edge.
    ///
    /// The panel used to be 92 points tall whatever it held, so a dictation past a
    /// line and a half showed its last two lines and hid everything before them.
    private func growToFit() {
        guard let panel, let content = panel.contentView else { return }

        content.layoutSubtreeIfNeeded()
        let height = max(content.fittingSize.height, Self.minimumHeight)
        guard abs(panel.frame.height - height) > 0.5 else { return }

        // An NSWindow's origin is its bottom-left corner, so keeping it fixed while
        // the height grows opens the panel upward, away from the Dock.
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating

        // Draggable, which means it also takes the clicks that land on it. That is the
        // trade for being able to move it out of the way mid-sentence: it is a small
        // target, it never takes focus, and the alternative is a panel you cannot move.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        // Visible over full-screen apps and on every desktop: a call is usually
        // full-screen, and that is exactly when the overlay is wanted.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationOverlayView(model: model))

        // Remember where it was left. The panel moves while the user drags it, so this
        // fires often; writing a preference is cheap and the last one wins.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.settings.overlayOriginX = panel.frame.origin.x
                self.settings.overlayOriginY = panel.frame.origin.y
            }
        }

        return panel
    }

    /// Where the user left it, or the bottom centre of the screen holding the pointer.
    private func position(_ panel: NSPanel?) {
        guard let panel else { return }

        if let x = settings.overlayOriginX, let y = settings.overlayOriginY,
           NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(x: x, y: y, width: Self.width, height: Self.minimumHeight)) }) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 90
        ))
    }
}

/// Text the overlay is showing.
@MainActor
@Observable
final class OverlayModel {
    var text = ""
    var isProcessing = false
    var opacity: Double = 0.75
}

// MARK: - View

private struct DictationOverlayView: View {
    @Bindable var model: OverlayModel

    /// Five lines of the text style actually in use, so it follows the system font
    /// size rather than a number that happens to look right today.
    static let visibleTextHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .title3)
        return ceil(font.ascender - font.descender + font.leading) * 5
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.isProcessing ? "brain" : "waveform")
                .font(.title2)
                .foregroundStyle(model.isProcessing ? .orange : .red)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            // Clipped to the last five lines rather than truncated to five.
            //
            // `lineLimit(5)` with head truncation keeps the first four lines and puts
            // the ellipsis inside the fifth, so a long dictation showed its opening
            // and hid the words being spoken. Letting the text take its full height
            // inside a bottom-aligned frame pushes the old lines off the top instead,
            // which is the way round you need while you are still talking.
            Text(displayText)
                .font(.title3)
                .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: Self.visibleTextHeight, alignment: .bottom)
                .clipped()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: DictationOverlayController.width)
        .frame(minHeight: DictationOverlayController.minimumHeight)
        // Glass behind, text in front, so fading the pane never costs legibility.
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .opacity(model.opacity)
        }
    }

    private var displayText: String {
        if model.isProcessing { return "Processing…" }
        return model.text.isEmpty ? "Listening…" : model.text
    }
}
#endif
