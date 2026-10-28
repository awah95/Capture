import AppKit
import SwiftUI

/// The setup checklist, spec §10.6.
///
/// Provider-key rows precede the three fixed permission rows. Keys are answered here,
/// inline, rather than by a system prompt. The
/// permissions are requested from this screen deliberately, so a prompt can never
/// land in the middle of someone's first sentence.
struct FirstRunView: View {
    @ObservedObject var controller: FirstRunController
    @ObservedObject var keyModel: GroqKeyFieldModel
    @ObservedObject var openRouterKeyModel: ProviderKeyFieldModel
    /// Called when the user dismisses the checklist.
    var onClose: () -> Void

    @FocusState private var keyFieldFocused: Bool
    @FocusState private var openRouterKeyFieldFocused: Bool

    /// The rows scroll; the header and the buttons do not.
    ///
    /// The checklist is not a fixed-height screen even though it always has four rows:
    /// the key row grows by a whole line when validation reports a failure, and the
    /// row detail text wraps differently at every width. A pinned frame clipped that
    /// growth, and pinning the footer inside the same scroll would have let the only
    /// way out of the window scroll off the bottom of it.
    var body: some View {
        ZStack {
            CapturPalette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(controller.prerequisites) { prerequisite in
                            row(for: prerequisite)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollBounceBehavior(.basedOnSize)

                HStack(spacing: 10) {
                    Button {
                        controller.refresh()
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    Text(controller.needsSetup
                         ? "You can return from the menu bar."
                         : "Captur is ready to use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(controller.needsSetup ? "Not now" : "Done") { onClose() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 620, maxWidth: .infinity,
               minHeight: 440, idealHeight: 600, maxHeight: .infinity)
        .tint(CapturPalette.accent)
        .onAppear {
            controller.refresh()
            controller.onRevealKeyField = { keyFieldFocused = true }
            controller.onRevealOpenRouterKeyField = { openRouterKeyFieldFocused = true }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CapturMark()
            CapturPageHeader(
                title: "Set up Captur",
                subtitle: controller.needsSetup
                    ? "Connect the services and permissions Captur needs before your first dictation."
                    : "Everything is in place. Hold your push-to-talk key and start speaking."
            )

            Text(controller.needsSetup ? "SETUP NEEDED" : "READY")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(controller.needsSetup ? Color.secondary : CapturPalette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .capturSurface(inset: true, radius: 6)
                .accessibilityLabel(controller.needsSetup ? "Setup needed" : "Ready")
        }
    }

    @ViewBuilder
    private func row(for prerequisite: Prerequisite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon(prerequisite.isSatisfied)
                    .frame(width: 32, height: 32)
                    .capturSurface(inset: true, radius: 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(Self.title(for: prerequisite.id)).fontWeight(.medium)
                        Text(prerequisite.isSatisfied ? "Ready" : "Required")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(prerequisite.isSatisfied ? CapturPalette.accent : .secondary)
                    }
                    Text(Self.detail(for: prerequisite.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(Self.actionTitle(for: prerequisite.id, isSatisfied: prerequisite.isSatisfied)) {
                    controller.request(prerequisite.id)
                }
            }

            // The key row carries its own answer. The other three can only be
            // answered by macOS.
            if prerequisite.id == .groqKey {
                GroqKeyField(model: keyModel, focus: $keyFieldFocused)
                    .padding(.leading, 44)
            } else if prerequisite.id == .openRouterKey {
                ProviderKeyField(model: openRouterKeyModel, focus: $openRouterKeyFieldFocused)
                    .padding(.leading, 44)
            }
        }
        .padding(14)
        .capturSurface(radius: 10)
    }

    private func statusIcon(_ isSatisfied: Bool) -> some View {
        Image(systemName: isSatisfied ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(isSatisfied ? CapturPalette.accent : Color.secondary)
            .imageScale(.large)
            .accessibilityLabel(isSatisfied ? "Done" : "Not done")
    }

    // MARK: Copy

    static func title(for kind: Prerequisite.Kind) -> String {
        switch kind {
        case .groqKey: return "Groq API key"
        case .openRouterKey: return "OpenRouter API key"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    static func detail(for kind: Prerequisite.Kind) -> String {
        switch kind {
        case .groqKey:
            return "Used for Groq transcription and modes configured to use Groq. "
                + "It is stored in your Keychain."
        case .openRouterKey:
            return "Used by Clean or another automatic mode configured for OpenRouter. "
                + "It is stored in your Keychain."
        case .microphone:
            return "Without it there is nothing to transcribe."
        case .accessibility:
            return "Lets Captur put the text where your cursor is, instead of leaving it on the clipboard."
        case .inputMonitoring:
            return "Lets Captur see your push-to-talk key go down while another app is in front. "
                + "Push-to-talk does nothing without it."
        }
    }

    static func actionTitle(for kind: Prerequisite.Kind, isSatisfied: Bool) -> String {
        switch kind {
        case .groqKey, .openRouterKey: return isSatisfied ? "Replace" : "Add key"
        case .microphone, .accessibility, .inputMonitoring:
            return isSatisfied ? "Open Settings" : "Grant"
        }
    }
}

/// A window of its own, because there is no main window yet.
///
/// Spec §10.6 says the checklist opens "instead of Home", but Home lands with
/// `MainWindowController` in Task 21. Hosting `FirstRunView` in a standalone window
/// makes the checklist fully usable now; Task 21 can drop the same view into the
/// sidebar window and delete this controller without touching `FirstRunController`,
/// `GroqKeyField` or any of the copy.
@MainActor
final class FirstRunWindowController: NSWindowController, NSWindowDelegate {

    private let controller: FirstRunController

    init(controller: FirstRunController,
         keyModel: GroqKeyFieldModel,
         openRouterKeyModel: ProviderKeyFieldModel) {
        self.controller = controller

        var close: () -> Void = {}
        let hosting = NSHostingController(
            rootView: FirstRunView(controller: controller,
                                   keyModel: keyModel,
                                   openRouterKeyModel: openRouterKeyModel,
                                   onClose: { close() }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set up Captur"
        // `.resizable` matters more than it looks: the key row's failure messages and
        // the wrapped row detail make the natural height depend on both the width and
        // what has gone wrong, and a fixed window turns any underestimate into
        // permanently unreachable content.
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 600))
        window.contentMinSize = NSSize(width: 520, height: 440)
        window.center()
        super.init(window: window)
        window.delegate = self
        close = { [weak self] in self?.dismiss() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Brings the checklist forward and re-reads status first, so a user coming back
    /// from System Settings sees the truth rather than the state they left.
    func present() {
        controller.reopen()
        CapturWindowPresentation.present(self)
    }

    func dismiss() {
        controller.dismiss()
        window?.orderOut(nil)
        CapturWindowPresentation.restoreAccessoryPolicy(excluding: window)
    }

    /// The red button and "Not now" mean the same thing.
    func windowWillClose(_ notification: Notification) {
        controller.dismiss()
        CapturWindowPresentation.restoreAccessoryPolicy(excluding: window)
    }
}
