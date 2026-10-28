import SwiftUI

// MARK: - Normalization

/// Spec §9: "Amplitude is normalized against a rolling noise floor so a quiet mic
/// still shows movement and a loud one does not clip flat."
///
/// The floor drops instantly and rises slowly, so a moment of silence recalibrates
/// what quiet means without a cough resetting it. The ceiling does the mirror image.
struct WaveformNormalizer {

    /// A floor and ceiling this close together means everything reads as full scale,
    /// so a minimum span keeps a dead-silent input from painting a full waveform.
    static let minimumSpan: Double = 0.02
    static let floorRise: Double = 0.002
    static let ceilingFall: Double = 0.02

    private var noiseFloor: Double = 0.02
    private var ceiling: Double = 0.08

    mutating func normalize(_ level: Double) -> Double {
        let value = min(max(level, 0), 1)

        if value < noiseFloor {
            noiseFloor = value
        } else {
            noiseFloor += (value - noiseFloor) * Self.floorRise
        }

        if value > ceiling {
            ceiling = value
        } else {
            ceiling += (value - ceiling) * Self.ceilingFall
        }

        let span = max(ceiling - noiseFloor, Self.minimumSpan)
        return min(max((value - noiseFloor) / span, 0), 1)
    }
}

// MARK: - Level buffer

/// The rolling buffer behind the bars.
///
/// Deliberately **not** an `ObservableObject`: at 30 Hz it would invalidate the whole
/// capsule thirty times a second. The `TimelineView` already redraws at 30 fps while
/// the waveform is live, and reads this on the way through.
///
/// Main-thread only. Levels arrive on the main actor by `AudioEngineControlling`'s
/// own contract.
final class WaveformLevelSource {

    static let barCount = 20
    /// Bar heights lerp toward their target at 0.35 per frame so the motion reads as
    /// fluid rather than jittery (§9).
    static let lerp: Double = 0.35

    private(set) var targets = [Double](repeating: 0, count: barCount)
    private(set) var displayed = [Double](repeating: 0, count: barCount)

    private var normalizer = WaveformNormalizer()
    private var lastFrame: Date?

    /// One metered level. The buffer scrolls; the *displayed* heights do not, so each
    /// bar chases whatever value now occupies its slot.
    func push(_ level: Double) {
        targets.removeFirst()
        targets.append(normalizer.normalize(level))
    }

    func advance() {
        for index in displayed.indices {
            displayed[index] += (targets[index] - displayed[index]) * Self.lerp
        }
    }

    /// Idempotent per frame: `TimelineView` can evaluate its body more than once for
    /// the same date, and a double lerp would make the motion frame-rate dependent.
    func advance(to date: Date) {
        guard date != lastFrame else { return }
        lastFrame = date
        advance()
    }

    func reset() {
        targets = [Double](repeating: 0, count: Self.barCount)
        displayed = [Double](repeating: 0, count: Self.barCount)
        normalizer = WaveformNormalizer()
        lastFrame = nil
    }
}

// MARK: - Canvas

/// 20 bars in a `Canvas`, at 30 fps **while live and not at all otherwise** — the
/// `TimelineView` exists only inside the `isLive` branch, so nothing ticks when the
/// waveform is frozen or absent.
struct WaveformCanvas: View {

    /// Design geometry from §9. The capsule's collapsed width leaves 58 pt for the
    /// bars, which is 30 pt less than 20 × 2.5 pt plus 19 × 2 pt gaps; the gap is
    /// compressed to fit rather than the bar count or the capsule's stated minimum
    /// being changed.
    static let designBarWidth: CGFloat = 2.5
    static let designGap: CGFloat = 2
    static let minimumGap: CGFloat = 0.8

    let source: WaveformLevelSource
    let isLive: Bool
    let color: Color

    var body: some View {
        if isLive {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let bars = frame(at: timeline.date)
                canvas(bars: bars)
            }
        } else {
            canvas(bars: source.displayed)
        }
    }

    private func frame(at date: Date) -> [Double] {
        source.advance(to: date)
        return source.displayed
    }

    private func canvas(bars: [Double]) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            Self.draw(bars: bars, in: &context, size: size, color: color)
        }
        .allowsHitTesting(false)
    }

    static func draw(bars: [Double], in context: inout GraphicsContext, size: CGSize, color: Color) {
        let count = max(bars.count, 1)
        let gap = max(minimumGap,
                      min(designGap, (size.width - CGFloat(count) * designBarWidth) / CGFloat(count - 1)))
        let barWidth = min(designBarWidth,
                           (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
        guard barWidth > 0 else { return }

        let pitch = barWidth + gap
        let inset = max(0, (size.width - (CGFloat(count) * barWidth + CGFloat(count - 1) * gap)) / 2)
        let minimumHeight = barWidth          // a dot rather than nothing when silent
        let maximumHeight = size.height

        for (index, value) in bars.enumerated() {
            let height = minimumHeight + (maximumHeight - minimumHeight) * CGFloat(min(max(value, 0), 1))
            let rect = CGRect(
                x: inset + CGFloat(index) * pitch,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }
    }
}
