import SwiftUI

#if os(macOS)
import AppKit

/// A floating panel showing what Inscribe is hearing, while you hold the key.
///
/// Feedback used to be a sound and a menu bar icon, which tells you recording started
/// but not whether the words are landing. Seeing the text arrive is the difference
/// between trusting the dictation and repeating yourself.
@MainActor
final class DictationOverlayController {

    private var panel: NSPanel?
    private let model = OverlayModel()

    // MARK: - Presentation

    static let minimumHeight: CGFloat = 92

    func show() {
        model.text = ""
        model.isProcessing = false

        if panel == nil {
            panel = makePanel()
        }

        if let panel, panel.frame.height != Self.minimumHeight {
            var frame = panel.frame
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

    func showProcessing() {
        model.isProcessing = true
    }

    func hide() {
        panel?.orderOut(nil)
        model.text = ""
        model.isProcessing = false
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true

        // Visible over full-screen apps and on every desktop: a call is usually
        // full-screen, and that is exactly when the overlay is wanted.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationOverlayView(model: model))

        return panel
    }

    /// Bottom centre of the screen holding the pointer, above the Dock.
    private func position(_ panel: NSPanel?) {
        guard let panel else { return }

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
}

// MARK: - View

private struct DictationOverlayView: View {
    @Bindable var model: OverlayModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.isProcessing ? "brain" : "waveform")
                .font(.title2)
                .foregroundStyle(model.isProcessing ? .orange : .red)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(displayText)
                .font(.title3)
                .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                // Up to five lines, and the oldest words are the ones dropped: what
                // you just said is what you want to check.
                .lineLimit(5)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 460)
        .frame(minHeight: DictationOverlayController.minimumHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var displayText: String {
        if model.isProcessing { return "Processing…" }
        return model.text.isEmpty ? "Listening…" : model.text
    }
}
#endif
