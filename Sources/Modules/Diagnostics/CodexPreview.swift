import AppKit
import SwiftUI

/// The real settings and modes UI with temporary preferences/stores and synthetic text.
/// No composition root, microphone, history, Keychain, hotkey registration, or insertion.
@MainActor
final class CodexPreview: NSObject, NSWindowDelegate {
    private static var current: CodexPreview?
    private let root: URL
    private let suite: String
    private var window: NSWindow?

    private init(root: URL, suite: String) {
        self.root = root
        self.suite = suite
    }

    static func show() {
        do {
            let root = try CodexCLIService.scratchDirectory()
            let suite = "Capture-Codex-Preview-" + UUID().uuidString
            let preview = CodexPreview(root: root, suite: suite)
            current = preview
            let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
            settings.codexCLIEnabled = true
            let integration = CodexIntegration(settings: settings)
            let client = RoutingRefinementClient(configuration: {
                await MainActor.run { integration.configuration }
            })
            let runner = ModePreviewRunner(refinement: client, apiKey: { _ in nil }, vocabularyTerms: { [] }, clipboard: { nil })
            let model = ModesViewModel(store: ModeStore(directory: root),
                lastDictation: { .init(rawText: "um send the sample report thursday no friday", targetAppName: nil) },
                preview: { mode, source in await runner.run(mode: mode, source: source) },
                modesAffectPipeline: true, codex: integration)
            model.select(modeID: Mode.clean.id)
            model.setDraftProvider(.codexCLI)
            let view = TabView {
                ScrollView {
                    CodexSettingsSection(integration: integration, settings: settings).padding(24)
                }.tabItem { Label("Codex settings", systemImage: "terminal") }
                ModesView(model: model).tabItem { Label("Modes", systemImage: "slider.horizontal.3") }
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Capture — isolated Codex preview"
            window.contentView = NSHostingView(rootView: view)
            window.delegate = preview
            window.isReleasedWhenClosed = false
            preview.window = window
            window.center()
            NSApplication.shared.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            print("Codex preview failed: \(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        Self.current = nil
        NSApplication.shared.terminate(nil)
    }
}
