import SwiftUI

#if os(macOS)
import AppKit

/// The ribbon's outline, as a shape, so Liquid Glass can be cut to it.
struct RibbonShape: Shape {
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
struct ListeningBar: View {
    let spectrum: [Double]
    let isProcessing: Bool

    private static let pointCount = 48
    private static let height: CGFloat = DictationOverlayController.bandHeight

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let amplitudes = (0..<Self.pointCount).map { amplitude(index: $0, time: time) }
            let shape = RibbonShape(amplitudes: amplitudes)
            let stops = isProcessing ? Self.processingStops : Self.voiceStops

            let fill = LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)

            ZStack {
                // Two halos rather than one: a wide dim wash for falloff and a tight
                // bright one at the edge. A single broad blur reads as haze; the pair
                // reads as something burning.
                shape.fill(fill)
                    .blur(radius: 11)
                    .opacity(0.45)
                    .blendMode(.plusLighter)

                shape.fill(fill)
                    .blur(radius: 3)
                    .opacity(0.9)
                    .blendMode(.plusLighter)

                shape.fill(fill)
            }
            .compositingGroup()
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
            let thickness = resting + (reach - resting) * CGFloat(value)
            return CGPoint(
                x: CGFloat(index) * step,
                y: middle - thickness * taper(index, of: amplitudes.count)
            )
        }
        let bottom = top.reversed().map { CGPoint(x: $0.x, y: middle + (middle - $0.y)) }

        var path = Path()
        append(top, to: &path, starting: true)
        append(bottom, to: &path, starting: false)
        path.closeSubpath()
        return path
    }

    /// Pinch the first and last few points down to nothing.
    ///
    /// The ribbon used to begin and end at whatever its outermost band happened to be
    /// doing, so both ends were a cut edge. A raised cosine over the outer quarter
    /// brings it to a point instead, and the shape enters and leaves like a feather.
    private static func taper(_ index: Int, of count: Int) -> CGFloat {
        let width = Double(count) / 4
        let distance = Double(min(index, count - 1 - index))
        guard distance < width else { return 1 }
        return CGFloat(0.5 - 0.5 * cos(.pi * distance / width))
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

    /// White at the centre line, taking on colour as the ribbon swells away from it.
    ///
    /// This is the way round Siri does it, and it was backwards here: colour sat in
    /// the middle and the edges faded, so a quiet moment was a dim coloured thread
    /// instead of a bright white one. Now silence is a clean white line and colour
    /// only appears where the voice pushes the shape outward — the loudness writes
    /// itself in hue as well as in height.
    ///
    /// Symmetric, because the ribbon swells both ways from the centre. The ends fade
    /// so the edges dissolve rather than being cut off.
    private static let azure = Color(red: 0.24, green: 0.60, blue: 1.00)
    private static let violet = Color(red: 0.62, green: 0.38, blue: 1.00)

    private static let voiceStops: [Gradient.Stop] = [
        .init(color: violet.opacity(0.4), location: 0.0),
        .init(color: violet, location: 0.16),
        .init(color: azure, location: 0.36),
        .init(color: .white, location: 0.47),
        .init(color: .white, location: 0.53),
        .init(color: azure, location: 0.64),
        .init(color: violet, location: 0.84),
        .init(color: violet.opacity(0.4), location: 1.0)
    ]

    private static let amber = Color(red: 1.00, green: 0.70, blue: 0.32)

    private static let processingStops: [Gradient.Stop] = [
        .init(color: amber.opacity(0.4), location: 0.0),
        .init(color: amber, location: 0.22),
        .init(color: .white, location: 0.47),
        .init(color: .white, location: 0.53),
        .init(color: amber, location: 0.78),
        .init(color: amber.opacity(0.4), location: 1.0)
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
