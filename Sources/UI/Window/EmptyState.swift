import SwiftUI

/// One line of copy plus, where there is one, the action that resolves it.
///
/// Spec §10.6. Every empty state in this app is the same shape on purpose: a blank
/// pane teaches nothing, and four differently-worded blank panes teach four different
/// wrong things. The strings live here as named constructors so the four call sites
/// (Home, History, Stats) cannot drift apart.
struct EmptyState: View {
    let message: String
    var symbol: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(CapturPalette.accent)
                    .frame(width: 56, height: 56)
                    .capturSurface(inset: true, radius: 16)
            }

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // Without this the copy truncates to one line inside a narrow stat tile
                // — seen on Home, where the hero read "Run the 60-second typing te…".
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

// MARK: - The four states, spec §10.6

extension EmptyState {

    /// Copy strings, exposed so a view test or a Settings preview can assert on them
    /// rather than re-typing them.
    enum Copy {
        // Names the gesture, not the key. Push-to-talk is rebindable — including to a
        // chord like ⌘⇧D — and this string has no access to the binding, so naming a
        // specific key here is a sentence that goes wrong the moment the user changes it.
        static let noDictations = "Hold your push-to-talk key and say something. It'll appear here."
        static let noTypingBaseline = "Run the 60-second typing test to see time saved."
        static let noSearchMatches = "No matches."
        static let tooFewDictationsForStats = "A few more dictations and this gets interesting."
    }

    /// Home and History, before the first dictation. Deliberately the same sentence in
    /// both places: they are the same absence.
    static var noDictations: EmptyState {
        EmptyState(message: Copy.noDictations, symbol: "waveform")
    }

    static func noTypingBaseline(runTest: @escaping () -> Void) -> EmptyState {
        EmptyState(message: Copy.noTypingBaseline,
                   symbol: "keyboard",
                   actionTitle: "Run typing test",
                   action: runTest)
    }

    /// History, with a query that matched nothing. No symbol and no button — the
    /// action that resolves it is the search field the user is already looking at.
    static var noSearchMatches: EmptyState {
        EmptyState(message: Copy.noSearchMatches)
    }

    static var tooFewDictationsForStats: EmptyState {
        EmptyState(message: Copy.tooFewDictationsForStats, symbol: "chart.bar")
    }
}
