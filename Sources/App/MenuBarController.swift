import AppKit
import Combine
import QuartzCore

/// The status-bar item: the app's only permanent surface (Captur is `LSUIElement`,
/// so there is no Dock icon and no main menu).
///
/// It owns no pipeline reference. Phase arrives through `update(phase:)` — or through
/// `observe(_:)` for a publisher — and every command leaves through an injected
/// closure, so this class can be built, driven and reasoned about without the audio
/// stack existing.
@MainActor
final class MenuBarController: NSObject {

    /// Everything the menu can do. Window destinations are optional: a nil closure
    /// renders its item visibly disabled rather than hiding it. Keeping the landmarks
    /// stable makes the menu predictable during setup and in reduced app compositions.
    struct Actions {
        var startDictation: () -> Void
        var stopDictation: () -> Void
        var cancelDictation: () -> Void
        var showHistory: (() -> Void)?
        var showSettings: (() -> Void)?
        var showDiagnostics: () -> Void
        var showSetup: (() -> Void)?
        /// Whether the checklist is worth offering. Spec §10.6 says it "disappears from
        /// launch once every row is satisfied" and is reachable again from Settings —
        /// so a permanent menu entry for a finished setup is clutter, not a courtesy.
        /// A closure rather than a value because prerequisites change while the app is
        /// running, and `MenuShape` re-reads it on every rebuild.
        var needsSetup: () -> Bool = { false }
        /// `@MainActor` on the closure type, not just by convention: the default value
        /// touches `NSApplication.shared`, and an unannotated `() -> Void` default is
        /// evaluated outside the actor — a warning today and an error under Swift 6.
        var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
        /// Opens the daily dashboard. It is last, with a default, so existing injected
        /// action sets keep source compatibility while the main composition adopts it.
        var showOverview: (() -> Void)? = nil
    }

    private let actions: Actions
    /// A recording's icon follows the active mode's SF Symbol. Modes carry a symbol
    /// but no colour, and spec §9 reserves red for recording, so the *tint* is fixed
    /// and the *glyph* is what varies. Injected so Task 16 can hand in the real
    /// mode lookup without this file changing.
    private let modeSymbol: (String) -> String
    private let statusBar: NSStatusBar

    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?
    private var phase: PipelinePhase = .idle
    private var accessibilityObserver: (any NSObjectProtocol)?

    private static let pulseKey = "captur.recordingPulse"

    init(actions: Actions,
         modeSymbol: @escaping (String) -> String = { _ in "waveform.circle.fill" },
         statusBar: NSStatusBar = .system) {
        self.actions = actions
        self.modeSymbol = modeSymbol
        self.statusBar = statusBar
        super.init()
    }

    // MARK: Lifecycle

    func install() {
        guard statusItem == nil else { return }
        let item = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.wantsLayer = true
        statusItem = item
        item.button?.setAccessibilityLabel("Captur")
        item.button?.setAccessibilityHelp("Start dictation or open Captur controls")
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        accessibilityObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyIcon(self.iconSpec(for: self.phase))
            }
        }
        apply(phase: phase, previous: nil)
    }

    func remove() {
        stopPulse()
        if let statusItem { statusBar.removeStatusItem(statusItem) }
        statusItem = nil
        cancellable = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }

    /// Drives the icon and the menu from a phase publisher.
    func observe<P: Publisher>(_ publisher: P) where P.Output == PipelinePhase, P.Failure == Never {
        cancellable = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.update(phase: phase) }
    }

    /// The single entry point for state. Idempotent.
    func update(phase: PipelinePhase) {
        guard phase != self.phase else { return }
        let previous = self.phase
        self.phase = phase
        apply(phase: phase, previous: previous)
    }

    /// Re-evaluates non-pipeline inputs such as first-run prerequisites. Callers opt
    /// into this refresh when those values change; elapsed recording ticks continue
    /// through `update(phase:)` and retain the normal shape-based no-churn behavior.
    func refreshMenu() {
        statusItem?.menu = buildMenu(phase: phase)
    }

    /// Both surfaces are rebuilt only when their *own* input changes, not on every
    /// phase change.
    ///
    /// This matters because `.recording` carries `elapsed`, which the pipeline
    /// republishes every whole second — so a naive rebuild replaces `statusItem.menu`
    /// once a second for the length of a dictation. Swapping the menu object out from
    /// under an open menu dismisses it, and the user most likely to have it open is the
    /// one who started dictation from the menu bar and is reaching for "Stop Dictation".
    private func apply(phase: PipelinePhase, previous: PipelinePhase?) {
        let spec = iconSpec(for: phase)
        if previous == nil || spec != iconSpec(for: previous ?? phase) {
            applyIcon(spec)
        }
        if previous == nil || menuStatus(for: phase) != menuStatus(for: previous ?? phase) {
            applyStatusDescription(for: phase)
        }
        let shape = menuShape(for: phase)
        if previous == nil || shape != menuShape(for: previous ?? phase) {
            statusItem?.menu = buildMenu(phase: phase)
        }
    }

    /// Everything that changes the menu's *contents*. `elapsed` is deliberately not in
    /// it: the menu says "Stop Dictation" whether you have been talking for one second
    /// or thirty.
    struct MenuShape: Equatable {
        var holdsMicrophone: Bool
        var status: MenuStatus
        var hasOverview: Bool
        var hasHistory: Bool
        var hasSettings: Bool
        var hasSetup: Bool
    }

    func menuShape(for phase: PipelinePhase) -> MenuShape {
        MenuShape(holdsMicrophone: phase.holdsMicrophone,
                  status: menuStatus(for: phase),
                  hasOverview: actions.showOverview != nil,
                  hasHistory: actions.showHistory != nil,
                  hasSettings: actions.showSettings != nil,
                  hasSetup: actions.showSetup != nil && actions.needsSetup())
    }

    enum MenuStatus: Equatable {
        case ready, starting, listening, processing, complete, failed
    }

    func menuStatus(for phase: PipelinePhase) -> MenuStatus {
        switch phase {
        case .idle: return .ready
        case .arming: return .starting
        case .recording: return .listening
        case .transcribing, .refining: return .processing
        case .success: return .complete
        case .error: return .failed
        }
    }

    func menuStatusTitle(for phase: PipelinePhase) -> String {
        switch menuStatus(for: phase) {
        case .ready: return "Ready"
        case .starting: return "Starting microphone…"
        case .listening: return "Listening"
        case .processing: return "Preparing your text…"
        case .complete: return "Capture complete"
        case .failed: return "Capture needs attention"
        }
    }

    // MARK: Icon

    /// The glyph and tint for a phase. Monochrome template art everywhere except a
    /// live recording, which is the one state that has to be readable from the corner
    /// of an eye — spec §9: red for recording, one accent otherwise.
    struct IconSpec: Equatable {
        var symbol: String
        var tint: NSColor?
        var isTemplate: Bool
        var pulses: Bool
    }

    func iconSpec(for phase: PipelinePhase) -> IconSpec {
        switch phase {
        case .idle, .success:
            return IconSpec(symbol: "waveform", tint: nil, isTemplate: true, pulses: false)
        case .arming:
            return IconSpec(symbol: "waveform.circle.fill", tint: .systemRed, isTemplate: false, pulses: false)
        case .recording(_, let modeName):
            return IconSpec(symbol: modeSymbol(modeName), tint: .systemRed, isTemplate: false, pulses: true)
        case .transcribing, .refining:
            return IconSpec(symbol: "waveform.circle", tint: Self.lavender, isTemplate: false, pulses: false)
        case .error:
            return IconSpec(symbol: "exclamationmark.triangle.fill", tint: .systemRed,
                            isTemplate: false, pulses: false)
        }
    }

    private func applyIcon(_ spec: IconSpec) {
        guard let button = statusItem?.button else { return }
        let image: NSImage?
        if spec.isTemplate, spec.symbol == "waveform",
           let mark = NSImage(named: NSImage.Name("StatusMark"))?.copy() as? NSImage {
            mark.accessibilityDescription = "Captur"
            image = mark
        } else {
            image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: "Captur")
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Captur")
        }
        image?.isTemplate = spec.isTemplate
        button.image = image
        button.contentTintColor = spec.tint
        if spec.pulses { startPulse(on: button) } else { stopPulse() }
    }

    private func applyStatusDescription(for phase: PipelinePhase) {
        guard let button = statusItem?.button else { return }
        let status = menuStatusTitle(for: phase)
        button.toolTip = "Captur — \(status)"
        button.setAccessibilityValue(status)
    }

    /// A 1 s opacity cycle, run by Core Animation rather than a `Timer`.
    ///
    /// This is the whole reason there is no timer anywhere in this class: an idle app
    /// must not wake the CPU to redraw a static glyph, and a repeating
    /// `CABasicAnimation` exists only while it is attached to a layer.
    private func startPulse(on button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopPulse()
            return
        }
        guard let layer = button.layer, layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseKey)
    }

    private func stopPulse() {
        statusItem?.button?.layer?.removeAnimation(forKey: Self.pulseKey)
        statusItem?.button?.alphaValue = 1
    }

    // MARK: Menu

    /// Start Dictation · Captures… · Settings… ⌘, · Diagnostics… · Quit.
    ///
    /// Window destinations stay visible while unavailable. The stable shape — and the
    /// fact that Settings is ⌘, — lets the user learn the menu once while a reduced
    /// composition or first-run flow is still coming online.
    func buildMenu(phase: PipelinePhase) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = menuItem(menuStatusTitle(for: phase), nil, "", enabled: false,
                              symbol: statusSymbol(for: phase))
        status.attributedTitle = NSAttributedString(
            string: menuStatusTitle(for: phase),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)])
        menu.addItem(status)
        menu.addItem(.separator())

        if phase.holdsMicrophone {
            menu.addItem(menuItem("Stop Dictation", #selector(menuStop), "\r", symbol: "stop.circle.fill"))
            menu.addItem(menuItem("Cancel", #selector(menuCancel), "\u{1b}", symbol: "xmark"))
        } else {
            menu.addItem(menuItem("Start Dictation", #selector(menuStart), "", symbol: "mic.fill"))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Open Captur…", #selector(menuOverview), "",
                              enabled: actions.showOverview != nil, symbol: "square.grid.2x2"))
        menu.addItem(menuItem("Captures…", #selector(menuHistory), "",
                              enabled: actions.showHistory != nil, symbol: "clock.arrow.circlepath"))
        menu.addItem(menuItem("Settings…", #selector(menuSettings), ",",
                              enabled: actions.showSettings != nil, symbol: "gearshape"))
        if actions.showSetup != nil, actions.needsSetup() {
            menu.addItem(menuItem("Set Up Captur…", #selector(menuSetup), "", symbol: "checklist"))
        }
        menu.addItem(menuItem("Diagnostics…", #selector(menuDiagnostics), "", symbol: "waveform.path.ecg"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Captur", #selector(menuQuit), "q", symbol: "power"))
        return menu
    }

    private func menuItem(_ title: String,
                          _ action: Selector?,
                          _ key: String,
                          enabled: Bool = true,
                          symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            item.image = image
        }
        return item
    }

    private func statusSymbol(for phase: PipelinePhase) -> String {
        switch menuStatus(for: phase) {
        case .ready: return "waveform"
        case .starting, .listening: return "mic.fill"
        case .processing: return "waveform.circle"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private static let lavender = NSColor(
        calibratedRed: 0.69, green: 0.55, blue: 0.84, alpha: 1)

    @objc private func menuStart() { actions.startDictation() }
    @objc private func menuStop() { actions.stopDictation() }
    @objc private func menuCancel() { actions.cancelDictation() }
    @objc private func menuOverview() { actions.showOverview?() }
    @objc private func menuHistory() { actions.showHistory?() }
    @objc private func menuSettings() { actions.showSettings?() }
    @objc private func menuSetup() { actions.showSetup?() }
    @objc private func menuDiagnostics() { actions.showDiagnostics() }
    @objc private func menuQuit() { actions.quit() }
}
