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

    func update(text: String, spectrum: [Double]) {
        model.spectrum = spectrum

        // Only when it changed: the band wants twenty updates a second, and laying out
        // a panel-tall block of text that often to say the same words is waste.
        guard model.text != text else { return }
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

        let ceiling = availableTextHeight(for: panel)
        if abs(model.maxTextHeight - ceiling) > 0.5 {
            model.maxTextHeight = ceiling
        }

        content.layoutSubtreeIfNeeded()
        let height = max(content.fittingSize.height, Self.minimumHeight)
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
        let container = DragHandleView()
        let hosting = NSHostingView(rootView: DictationOverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
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
    var opacity: Double = 0.75

    /// Loudness per frequency band, 0 to 1, low to high — one per bar.
    var spectrum: [Double] = []

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
        VStack(alignment: .leading, spacing: 10) {
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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: DictationOverlayController.width)
        .frame(minHeight: DictationOverlayController.minimumHeight)
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        // Text and glass fade together, so the whole panel recedes as one thing
        // rather than leaving words floating over nothing.
        .opacity(model.opacity)
    }

    private var displayText: String {
        if model.isProcessing { return "Processing…" }
        return model.text.isEmpty ? "Listening…" : model.text
    }
}

/// The ribbon's outline, as a shape, so Liquid Glass can be cut to it.
private struct RibbonShape: Shape {
    let amplitudes: [Double]

    func path(in rect: CGRect) -> Path {
        ListeningBar.ribbon(amplitudes: amplitudes, in: rect.size)
    }
}

/// A band of moving colour across the top of the panel showing your voice's spectrum.
///
/// It replaced an icon beside the text, which took a quarter of the width and made
/// every line wrap sooner — so the panel grew taller to say the same thing. This sits
/// above the words and leaves them the full width.
///
/// Each bar is one slice of the frequency range, read off the microphone, so the band
/// shows the shape of the voice rather than only its volume — and a silent room is a
/// flat line. That is the question the panel exists to answer: is it hearing me.
///
/// The colours are the system's own blue, purple and pink, so they follow light and
/// dark mode without being told to.
private struct ListeningBar: View {
    let spectrum: [Double]
    let isProcessing: Bool

    private static let pointCount = 48
    private static let height: CGFloat = 22

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let amplitudes = (0..<Self.pointCount).map { amplitude(index: $0, time: time) }
            let shape = RibbonShape(amplitudes: amplitudes)
            let stops = isProcessing ? Self.processingStops : Self.voiceStops

            ZStack {
                shape.fill(
                    LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
                )

                // The same Liquid Glass the panel is made of, cut to the ribbon.
                // `glassEffect` takes any shape, not just a rounded rectangle, so the
                // ribbon gets the real thing — the specular edge and the refraction of
                // what is behind it — rather than a colour pretending to be lit.
                Color.clear.glassEffect(.regular, in: shape)
            }
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
    }

    /// One closed shape through every band, mirrored about the centre line.
    ///
    /// Forty-eight separate bars read as a meter however they were coloured, and
    /// blurring them only made a blurry meter. A single curve carries the same numbers
    /// and reads as one moving thing, which is what the panel is trying to be.
    fileprivate static func ribbon(amplitudes: [Double], in size: CGSize) -> Path {
        guard amplitudes.count > 1 else { return Path() }

        let middle = size.height / 2
        let reach = middle - 2
        let resting: CGFloat = 1.2
        let step = size.width / CGFloat(amplitudes.count - 1)

        let top = amplitudes.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * step,
                y: middle - (resting + (reach - resting) * CGFloat(value))
            )
        }
        let bottom = top.reversed().map { CGPoint(x: $0.x, y: middle + (middle - $0.y)) }

        var path = Path()
        append(top, to: &path, starting: true)
        append(bottom, to: &path, starting: false)
        path.closeSubpath()
        return path
    }

    /// Curve through the points rather than joining them, so the shape has no corners.
    fileprivate static func append(_ points: [CGPoint], to path: inout Path, starting: Bool) {
        guard let first = points.first, let last = points.last else { return }

        if starting {
            path.move(to: first)
        } else {
            path.addLine(to: first)
        }

        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.addLine(to: last)
    }

    /// One point per frequency band, straight from the microphone.
    ///
    /// Nothing here invents movement. Every point is the loudness of its own slice of
    /// the spectrum, so vowels swell the left of the ribbon, an "s" lifts the right,
    /// and a silent room is a thin line. Only the AI pass, which has no audio to show,
    /// still falls back to a moving shape.
    private func amplitude(index: Int, time: TimeInterval) -> Double {
        if isProcessing {
            return 0.55 * (sin(time * 3.2 + Double(index) * 0.45) * 0.18 + 0.82)
        }
        return index < spectrum.count ? Self.curve(spectrum[index]) : 0
    }

    /// Muted azure through the middle, out through indigo to a dusty lavender.
    ///
    /// Symmetric, because the ribbon swells from the centre line in both directions,
    /// so it is the same colour where it meets zero however thick it is. The ends fade
    /// rather than stopping, so the edges dissolve instead of being cut off.
    ///
    /// Carried under the glass rather than in front of it, so it needs more colour
    /// than a flat fill would: the glass mutes what is behind it and hands back the
    /// shine. The system pink is still gone — it shouted at this size — but a
    /// washed-out ramp under glass only reads as grey.
    private static let azure = Color(red: 0.24, green: 0.52, blue: 0.96)
    private static let indigo = Color(red: 0.42, green: 0.40, blue: 0.92)
    private static let lavender = Color(red: 0.70, green: 0.46, blue: 0.94)

    private static let voiceStops: [Gradient.Stop] = [
        .init(color: lavender.opacity(0.35), location: 0.0),
        .init(color: lavender.opacity(0.75), location: 0.14),
        .init(color: indigo, location: 0.34),
        .init(color: azure, location: 0.5),
        .init(color: indigo, location: 0.66),
        .init(color: lavender.opacity(0.75), location: 0.86),
        .init(color: lavender.opacity(0.35), location: 1.0)
    ]

    private static let amber = Color(red: 0.85, green: 0.62, blue: 0.36)

    private static let processingStops: [Gradient.Stop] = [
        .init(color: amber.opacity(0.35), location: 0.0),
        .init(color: amber, location: 0.5),
        .init(color: amber.opacity(0.35), location: 1.0)
    ]

    /// Spread the quiet end of the range and compress the loud one.
    ///
    /// Loudness is already measured in decibels, so the band would be linear in
    /// something logarithmic. Bending it again gives the quiet-to-middle stretch most
    /// of the height, which is where speech spends its time and where the movement is
    /// worth watching; the top compresses, so a strong band fills the bar without the
    /// difference between loud and louder eating the whole scale.
    private static func curve(_ level: Double) -> Double {
        log10(1 + 9 * min(max(level, 0), 1))
    }
}
#endif
