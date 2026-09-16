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

    /// The pane behind the content, faded on its own so the words stay readable.
    private var glassView: NSGlassEffectView?

    private let model = OverlayModel()
    private let settings: AppSettings
    /// Held so the panel's move notifications keep arriving for the life of the app.
    private var moveObserver: (any NSObjectProtocol)?

    /// Measured to size the panel: the glass view around it reports nothing useful.

    static let minimumHeight: CGFloat = 92
    static let width: CGFloat = 460
    static let bandHeight: CGFloat = 22
    static let contentSpacing: CGFloat = 10
    static let verticalPadding: CGFloat = 28

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Presentation

    func show() {
        model.text = ""
        model.isProcessing = false

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
        applyOpacity()
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key status would pull
        // focus out of the app being dictated into, which is where the text must land.
        panel?.orderFrontRegardless()
    }

    func update(text: String, spectrum: [Double]) {
        model.spectrum = spectrum
        applyOpacity()

        // Only when it changed: the band wants twenty updates a second, and laying out
        // a panel-tall block of text that often to say the same words is waste.
        guard model.text != text else { return }
        model.text = text
        growToFit()
    }

    /// Fade the whole panel, glass included.
    ///
    /// The pane thins; the words do not.
    ///
    /// Three ways to do this and only one of them works. Tint only darkens the
    /// material, so nothing showed through at any setting. The window's alpha thins
    /// everything including the text, which defeats the panel. Fading the glass view
    /// alone is the answer, and it needs the content to be a sibling drawn on top of
    /// the glass rather than living inside it — a view's alpha takes its subviews
    /// with it.
    ///
    /// The tint itself is set once when the panel is built. Assigning it twenty times
    /// a second makes the material recomposite on every tick and the panel goes
    /// muddy.
    private func applyOpacity() {
        guard let glassView else { return }

        let wanted = settings.overlayOpacity
        guard abs(glassView.alphaValue - wanted) > 0.001 else { return }
        glassView.alphaValue = wanted
        model.paneOpacity = wanted
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
        guard let panel else { return }

        let ceiling = availableTextHeight(for: panel)
        if abs(model.maxTextHeight - ceiling) > 0.5 {
            model.maxTextHeight = ceiling
        }

        // The text measures itself and says how tall it is. Asking the view hierarchy
        // stopped working once the glass view was in it: the glass pins its content to
        // its own bounds, which come from the panel, so every view was being told its
        // height by the one thing that wanted to be told. The panel stopped growing.
        let height = max(
            model.textHeight + Self.bandHeight + Self.contentSpacing + Self.verticalPadding,
            Self.minimumHeight
        )
        guard abs(panel.frame.height - height) > 0.5 else { return }

        // An NSWindow's origin is its bottom-left corner, so keeping it fixed while
        // the height grows opens the panel upward, away from the Dock.
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// The room between the panel's bottom edge and the top of the screen it is on.
    ///
    /// The panel grows upward, so this is its ceiling. Dragging it higher leaves less
    /// room and the oldest lines start dropping off sooner, which is the honest
    /// behaviour: it can only show what fits.
    private func availableTextHeight(for panel: NSPanel) -> CGFloat {
        guard let screen = panel.screen ?? NSScreen.main else {
            return DictationOverlayView.lineHeight * 5
        }
        let room = screen.visibleFrame.maxY - 12 - panel.frame.minY - Self.chromeHeight
        return max(room, DictationOverlayView.lineHeight)
    }

    /// The panel's own padding, above and below the text.
    private static let chromeHeight: CGFloat = 28

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

        // The SwiftUI content swallows the mouse, so `isMovableByWindowBackground`
        // never sees a click and the panel could not be dragged at all. This view sits
        // under the content, takes every hit, and drags the window itself. Safe
        // because the panel is display-only: there is nothing in it to click.
        let hosting = NSHostingView(rootView: DictationOverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The glass the panel is made of. AppKit's own view rather than SwiftUI's
        // modifier: this one samples the windows behind the panel, which is where the
        // lensing comes from and what the SwiftUI version had no access to inside a
        // borderless transparent panel.
        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        // Clear rather than regular: the regular style is mostly frost, and frost is
        // what hides the refraction. Clear blurs far less and lets the edge bend what
        // is behind it, which is the part that reads as glass rather than as fog.
        glass.style = .clear
        // Refraction in Liquid Glass lives in the rim, not the interior, so a curve
        // this gentle put almost none of the panel inside it. A larger radius gives
        // the effect somewhere to happen.
        glass.cornerRadius = 26
        // Set once. Reassigning it per frame makes the material recomposite and the
        // panel darkens as it goes.
        glass.tintColor = NSColor.black.withAlphaComponent(0.22)
        self.glassView = glass

        // The content sits on top of the glass rather than inside it. As the glass
        // view's `contentView` it would inherit the glass's alpha, and thinning the
        // pane would thin the dictation with it.
        let container = DragHandleView()
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

/// Drags the panel from anywhere inside it.
private final class DragHandleView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Text the overlay is showing.
@MainActor
@Observable
final class OverlayModel {
    var text = ""
    var isProcessing = false
    /// Loudness per frequency band, 0 to 1, low to high — one per bar.
    var spectrum: [Double] = []

    /// How tall the text has laid itself out, which is what sizes the panel.
    var textHeight: CGFloat = 0

    /// How solid the pane behind is, so the rim drawn on top can match it.
    var paneOpacity: Double = 0.75

    /// How tall the text may grow before older lines are pushed off the top. Set from
    /// the room left between the panel's bottom edge and the top of its screen.
    var maxTextHeight: CGFloat = DictationOverlayView.lineHeight * 5
}

// MARK: - View

private struct DictationOverlayView: View {
    @Bindable var model: OverlayModel

    /// One line of the text style actually in use, so everything below follows the
    /// system font size rather than a number that happens to look right today.
    static let lineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .title3)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DictationOverlayController.contentSpacing) {
            ListeningBar(spectrum: model.spectrum, isProcessing: model.isProcessing)

            // Clipped to the newest lines rather than truncated.
            //
            // `lineLimit` with head truncation keeps the first lines and puts the
            // ellipsis inside the last, so a long dictation showed its opening and hid
            // the words being spoken. Letting the text take its full height inside a
            // bottom-aligned frame pushes the old lines off the top instead, which is
            // the way round you need while you are still talking.
            Text(displayText)
                .font(.title3)
                .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: model.maxTextHeight, alignment: .bottom)
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    model.textHeight = height
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, DictationOverlayController.verticalPadding / 2)
        .frame(width: DictationOverlayController.width)
        .frame(minHeight: DictationOverlayController.minimumHeight)
        // No background here. The glass is an NSGlassEffectView behind this view.
        //
        // The rim is drawn rather than sampled: a light edge, brightest where a light
        // above and to the left would catch it, fading around the curve. That is the
        // specular highlight the material renders faintly on a shape this large, and
        // drawing it is the honest way to get the read at this size.
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.55),
                            .white.opacity(0.12),
                            .white.opacity(0.04),
                            .white.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                // The rim is the pane's edge, so it thins with the pane. Left solid it
                // outlines a panel that is no longer there.
                .opacity(model.paneOpacity)
        )
        // Rendered dark throughout, so the text comes out light and the glass picks
        // its dark treatment, rather than each part being told separately.
        .environment(\.colorScheme, .dark)
    }

    private var displayText: String {
        if model.isProcessing { return "Processing…" }
        return model.text.isEmpty ? "Listening…" : model.text
    }
}

#endif
