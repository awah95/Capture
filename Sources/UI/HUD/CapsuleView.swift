import AppKit
import SwiftUI

/// The capsule itself. Spec §9: 30 pt tall, corner radius 15, 12 pt horizontal
/// padding, an `NSVisualEffectView` `.hudWindow` material behind it, and exactly one
/// spring — on width and content morphs, never on opacity.
struct CapsuleView: View {

    @ObservedObject var presenter: CapsulePresenter
    let levels: WaveformLevelSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let content = presenter.content
        HStack(spacing: CapsuleState.elementSpacing) {
            if content.showsPulsingDot {
                RecordingDot(color: content.tint.color, animates: !reduceMotion)
            }
            if let symbol = content.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(content.tint.color)
                    .frame(width: CapsuleState.symbolWidth)
            }
            if content.showsWaveform {
                // Monochrome, not the state tint.
                //
                // Spec §9 scopes red to "the recording dot and errors" — tinting the
                // waveform with it too made the whole capsule read as an alert rather
                // than as a recording, which is what it looked like on hardware. The
                // dot carries the state colour; the waveform is content.
                WaveformCanvas(source: levels,
                               isLive: content.waveformIsLive && !reduceMotion,
                               color: content.waveformIsLive ? .white : .white.opacity(0.62))
                    .frame(width: CapsuleState.waveformWidth,
                           height: CapsuleState.height - 12)
                    .opacity(content.waveformIsLive ? 1 : 0.3)
            }
            if let text = content.primaryText {
                Text(text)
                    .font(.system(size: CapsuleState.textPointSize, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color.white.opacity(0.94))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, CapsuleState.horizontalPadding)
        .frame(width: content.targetWidth, height: CapsuleState.height)
        .background {
            ZStack {
                CapsuleMaterial(reduceTransparency: reduceTransparency)
                Color.capturHUDGraphite.opacity(reduceTransparency ? 1 : 0.78)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: CapsuleState.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorSchemeContrast == .increased ? 0.36 : 0.15),
                              lineWidth: colorSchemeContrast == .increased ? 1 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: CapsuleState.cornerRadius, style: .continuous))
        .shimmer(active: content.showsShimmer,
                 reduceMotion: reduceMotion,
                 highContrast: colorSchemeContrast == .increased)
        .shadow(color: Color.black.opacity(reduceTransparency ? 0.28 : 0.42),
                radius: 18,
                y: 8)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: content)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Captur status")
        .accessibilityValue(Text(content.primaryText ?? "Ready"))
    }
}

// MARK: - Dot

/// 1.0 → 0.55 over 1.1 s, ease-in-out, **only while recording**. The animation is
/// attached to a state flag flipped once on appear, so it stops existing with the
/// view rather than being cancelled by hand.
private struct RecordingDot: View {

    let color: Color
    let animates: Bool
    @State private var dimmed = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(animates && dimmed ? 0.22 : 0.58), lineWidth: 1)
                .scaleEffect(animates && dimmed ? 1.28 : 1)
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
                .opacity(animates && dimmed ? 0.72 : 1)
        }
            .frame(width: CapsuleState.dotDiameter, height: CapsuleState.dotDiameter)
            .animation(animates ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : nil,
                       value: dimmed)
            .onAppear { dimmed = animates }
            .onChange(of: animates) { _, newValue in dimmed = newValue }
            .onDisappear { dimmed = false }
    }
}

// MARK: - Shimmer

/// An indeterminate sweep for the two open-ended phases. A Core Animation loop, not
/// a tick: when `active` is false the modifier is not in the tree at all.
///
/// **The clip is not decoration.** Found by running `--hud-parade` and photographing
/// the result: an unclipped overlay paints a rectangle over the capsule's rounded left
/// cap, so `transcribing` and `refining` — the two states every single dictation passes
/// through — rendered with a hard square notch bitten out of the left edge. It survived
/// review and a green suite because nothing in a unit test can see a corner.
private struct Shimmer: ViewModifier {

    let reduceMotion: Bool
    let highContrast: Bool
    @State private var travelling = false

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geometry in
                LinearGradient(
                    colors: [.clear,
                             Color.capturLavender.opacity(highContrast ? 0.62 : 0.34),
                             .clear],
                    startPoint: .leading,
                    endPoint: .trailing)
                    .frame(width: geometry.size.width * (reduceMotion ? 1 : 0.34))
                    .offset(x: reduceMotion ? 0 : (travelling ? geometry.size.width : -geometry.size.width * 0.34))
                    .opacity(reduceMotion ? 0.18 : 1)
                    .animation(reduceMotion ? nil : .linear(duration: 1.45).repeatForever(autoreverses: false),
                               value: travelling)
                    .onAppear { travelling = !reduceMotion }
                    .onChange(of: reduceMotion) { _, newValue in travelling = !newValue }
            }
            .clipShape(RoundedRectangle(cornerRadius: CapsuleState.cornerRadius,
                                        style: .continuous))
            .allowsHitTesting(false)
        )
    }
}

private extension View {
    @ViewBuilder
    func shimmer(active: Bool, reduceMotion: Bool, highContrast: Bool) -> some View {
        if active {
            modifier(Shimmer(reduceMotion: reduceMotion, highContrast: highContrast))
        } else {
            self
        }
    }
}

// MARK: - Material

/// `NSVisualEffectView`, `.hudWindow`, behind-window blending — the panel is
/// transparent, so the blur is the capsule.
private struct CapsuleMaterial: NSViewRepresentable {

    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = reduceTransparency ? .windowBackground : .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = reduceTransparency ? .windowBackground : .hudWindow
    }
}

// MARK: - Colour

extension CapsuleTint {
    /// Monochrome plus one accent; all four colours are system colours, so light and
    /// dark are handled by AppKit rather than by a second palette here.
    var color: Color {
        switch self {
        case .neutral: return Color.white.opacity(0.88)
        case .accent:  return .capturLavender
        case .warning: return Color(nsColor: .systemOrange)
        case .danger:  return Color(nsColor: .systemRed)
        case .success: return Color(nsColor: .systemGreen)
        }
    }
}

private extension Color {
    /// A single muted lavender links active HUD work to the workspace analytics
    /// without the neon gradient treatment that made the earlier concept feel generic.
    static let capturLavender = Color(red: 0.69, green: 0.55, blue: 0.84)
    static let capturHUDGraphite = Color(red: 0.095, green: 0.088, blue: 0.11)
}
