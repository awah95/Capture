import AppKit
import SwiftUI

/// Shared workspace colors resolve through the current native appearance, including
/// the user's Light/Dark/System choice. Content always uses semantic label colors.
enum CapturPalette {
    static let canvas = adaptive(light: 0xF4F4F5, dark: 0x18181B)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202023)
    static let inset = adaptive(light: 0xF7F7F8, dark: 0x1B1B1E)
    static let border = adaptive(light: 0xDEDEE3, dark: 0x38383E)
    static let accent = adaptive(light: 0x7050B4, dark: 0xBCA3EB)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// An opaque, fine-edged content surface. Native materials remain in navigation
/// chrome; text and charts keep a stable background in every accessibility setting.
struct CapturSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var inset = false
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(inset ? CapturPalette.inset : CapturPalette.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(contrast == .increased ? Color.primary.opacity(0.55) : CapturPalette.border,
                                  lineWidth: contrast == .increased ? 1.5 : 0.75)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func capturSurface(inset: Bool = false, radius: CGFloat = 12) -> some View {
        modifier(CapturSurface(inset: inset, radius: radius))
    }
}

struct CapturCard<Content: View>: View {
    let title: String
    var symbol: String?
    var caption: String?
    private let content: Content

    init(_ title: String, symbol: String? = nil, caption: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 13, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            content
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .capturSurface()
    }
}

struct CapturPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .semibold))
                .tracking(-0.6).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapturMark: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(CapturPalette.accent)
            .frame(width: 32, height: 32)
            .capturSurface(inset: true, radius: 9)
            .accessibilityHidden(true)
    }
}
