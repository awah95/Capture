import AppKit
import Combine
import SwiftUI

/// The capsule's window. Never key, never main — spec §9 — which is why ⌘R has to be
/// a Carbon hotkey rather than a keyboard shortcut.
final class CapsulePanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        assertionFailure("The capsule must never become key.")
        super.becomeKey()
    }

    override func becomeMain() {
        assertionFailure("The capsule must never become main.")
        super.becomeMain()
    }
}

/// Owns the panel, the position memory, and the transient ⌘R registration.
///
/// Every decision about *what* the capsule says lives in `CapsulePresenter`; this
/// type only decides where the glass is and when it fades.
@MainActor
final class CapsuleController {

    /// §9 appear: 110 ms fade plus a 6 pt rise. Dismiss: 160 ms fade. No springs on
    /// opacity anywhere.
    static let appearDuration: TimeInterval = 0.11
    static let dismissDuration: TimeInterval = 0.16
    static let appearRise: CGFloat = 6
    /// Default resting height above the usable bottom edge of the active display.
    static let bottomInset: CGFloat = 140
    /// A dragged or stale saved position may approach the edge, but never disappear
    /// into the Dock or sit flush against the bottom of the visible workspace.
    static let minimumBottomClearance: CGFloat = 56
    static let edgeInset: CGFloat = 12
    /// The width morph's spring settles inside this; the window shrinks only after,
    /// so the capsule is never clipped on the way down.
    static let shrinkDelay: TimeInterval = 0.35

    let presenter: CapsulePresenter

    private let levels = WaveformLevelSource()
    private let hotkeys: any HotkeyManaging
    private let positions: CapsulePositionStore
    private let scheduler: any CapsuleScheduling

    private var panel: CapsulePanel?
    private var cancellables: Set<AnyCancellable> = []
    private var isOnScreen = false
    private var retryRegistered = false
    private var shrinkWork: (any CapsuleScheduledWork)?
    private var moveObserver: (any NSObjectProtocol)?
    private var captureDisplayIdentifier: String?

    init(hotkeys: any HotkeyManaging,
         presenter: CapsulePresenter? = nil,
         positions: CapsulePositionStore = CapsulePositionStore(),
         scheduler: (any CapsuleScheduling)? = nil) {
        self.hotkeys = hotkeys
        self.presenter = presenter ?? CapsulePresenter()
        self.positions = positions
        self.scheduler = scheduler ?? CapsuleDispatchScheduler()
        observePresenter()
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    // MARK: Input

    /// Levels arrive on the main actor, already throttled to ~30 Hz by the engine.
    func attach(to pipeline: DictationPipeline) {
        pipeline.$meterLevel
            .sink { [weak self] level in self?.levels.push(level) }
            .store(in: &cancellables)
        pipeline.$liveTranscriptPreview
            .removeDuplicates()
            .sink { [weak self] text in self?.presenter.update(liveTranscript: text) }
            .store(in: &cancellables)
    }

    func update(phase: PipelinePhase) {
        // A new capture starts from a flat line rather than inheriting the last one's.
        if case .arming = phase {
            levels.reset()
            let screen = resolveWorkingScreen()
            captureDisplayIdentifier = screen.map { CapsulePositionStore.identifier(for: $0) }
            if let panel, isOnScreen {
                panel.setFrameOrigin(restingOrigin(width: panel.frame.width, on: screen))
            }
        }
        presenter.update(phase: phase)
        if case .idle = phase { captureDisplayIdentifier = nil }
    }

    func present(notice: CapsuleNotice) {
        presenter.present(notice: notice)
    }

    func dismiss() {
        presenter.dismiss()
    }

    // MARK: Presenter observation

    private func observePresenter() {
        presenter.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in visible ? self?.show() : self?.hide() }
            .store(in: &cancellables)

        presenter.$content
            .map(\.targetWidth)
            .removeDuplicates()
            .sink { [weak self] width in self?.resize(to: width) }
            .store(in: &cancellables)

        presenter.$offersRetry
            .removeDuplicates()
            .sink { [weak self] offers in self?.setRetryHotkey(offers) }
            .store(in: &cancellables)
    }

    // MARK: The transient ⌘R

    /// The capsule never becomes key, so ⌘R can only reach it as a system hotkey —
    /// and a system hotkey stolen from every other app is only acceptable because it
    /// exists for the four seconds the error capsule is on screen.
    private func setRetryHotkey(_ wanted: Bool) {
        guard wanted != retryRegistered else { return }
        if wanted {
            do {
                try hotkeys.registerTransient(CapsuleState.retryCombo, action: .retryLast)
                retryRegistered = true
            } catch {
                // Someone else owns ⌘R. The capsule still says what happened; History
                // is the other way to retry.
                retryRegistered = false
            }
        } else {
            hotkeys.unregisterTransient(.retryLast)
            retryRegistered = false
        }
    }

    // MARK: Panel

    private func ensurePanel() -> CapsulePanel {
        if let panel { return panel }

        let hosting = NSHostingController(rootView: CapsuleView(presenter: presenter, levels: levels))
        hosting.view.setFrameSize(NSSize(width: presenter.content.targetWidth, height: CapsuleState.height))

        let panel = CapsulePanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: presenter.content.targetWidth,
                                height: CapsuleState.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.contentViewController = hosting
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.alphaValue = 0

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }

        self.panel = panel
        panel.setFrameOrigin(restingOrigin(width: presenter.content.targetWidth, on: targetScreen()))
        return panel
    }

    private func show() {
        let panel = ensurePanel()
        guard !isOnScreen else { return }
        isOnScreen = true

        let destination = restingOrigin(width: panel.frame.width, on: targetScreen())
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(destination)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.setFrameOrigin(NSPoint(x: destination.x, y: destination.y - Self.appearRise))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(destination)
        }
    }

    private func hide() {
        guard let panel, isOnScreen else { return }
        isOnScreen = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderOut(nil)
            levels.reset()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOnScreen else { return }
                panel.orderOut(nil)
                self.levels.reset()
            }
        }
    }

    /// The window grows the instant the content does, and shrinks only once the
    /// spring has settled — a window that shrank first would clip the morph.
    private func resize(to width: CGFloat) {
        guard let panel else { return }
        shrinkWork?.cancel()
        shrinkWork = nil

        let anchorX = panel.frame.midX
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            applyWidth(width, anchoredAt: anchorX, on: panel)
            return
        }
        if width > panel.frame.width {
            applyWidth(width, anchoredAt: anchorX, on: panel)
        } else if width < panel.frame.width {
            shrinkWork = scheduler.schedule(after: Self.shrinkDelay) { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.shrinkWork = nil
                guard self.presenter.content.targetWidth == width else { return }
                self.applyWidth(width, anchoredAt: panel.frame.midX, on: panel)
            }
        }
    }

    private func applyWidth(_ width: CGFloat, anchoredAt midX: CGFloat, on panel: CapsulePanel) {
        panel.setFrame(
            NSRect(x: midX - width / 2,
                   y: panel.frame.minY,
                   width: width,
                   height: CapsuleState.height),
            display: true)
    }

    // MARK: Position

    private func targetScreen() -> NSScreen? {
        if let captureDisplayIdentifier,
           let screen = NSScreen.screens.first(where: {
               CapsulePositionStore.identifier(for: $0) == captureDisplayIdentifier
           }) {
            return screen
        }
        return resolveWorkingScreen()
    }

    /// Chooses the display containing the focused editor/window. Accessibility and
    /// Quartz use the same top-left global display coordinates; `NSScreen.frame` does
    /// not, so matching is done against `CGDisplayBounds`. The pointer is a useful
    /// permission-free fallback for apps that expose no Accessibility geometry.
    private func resolveWorkingScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let focusedFrame = AXFocus.focusedSurfaceFrame(),
           let index = Self.bestDisplayIndex(
               for: focusedFrame,
               displayFrames: screens.map { screen in
                   guard let id = CapsulePositionStore.displayID(for: screen) else { return .null }
                   return CGDisplayBounds(id)
               }) {
            return screens[index]
        }

        let pointer = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? screens.first
    }

    /// Picks the display receiving the largest part of a focused surface. Using area
    /// rather than only the centre handles windows stretched across two monitors.
    static func bestDisplayIndex(for targetFrame: CGRect, displayFrames: [CGRect]) -> Int? {
        displayFrames.enumerated()
            .map { index, frame in (index, targetFrame.intersection(frame)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { lhs, rhs in lhs.1.width * lhs.1.height < rhs.1.width * rhs.1.height }?
            .0
    }

    /// Pure geometry, extracted so the one property that matters — that a remembered
    /// position survives the capsule changing width — is testable without a screen.
    ///
    /// The stored offset is the capsule's **centre**, not its left edge. Storing the
    /// left edge looks equivalent and is not: `applyWidth` anchors the morph on midX,
    /// so a capsule that widens from 132 to 340 moves its left edge 104 pt left, that
    /// move is persisted, and the next collapsed capsule opens 122 pt off-centre.
    /// Nothing about that requires the user to have ever dragged it.
    static func origin(width: CGFloat,
                       screenFrame: CGRect,
                       visibleFrame: CGRect? = nil,
                       storedCentreOffset: CGPoint?) -> NSPoint {
        let visibleFrame = visibleFrame ?? screenFrame
        let raw: NSPoint
        if let offset = storedCentreOffset {
            raw = NSPoint(x: screenFrame.minX + offset.x - width / 2,
                          y: screenFrame.minY + offset.y)
        } else {
            raw = NSPoint(x: visibleFrame.midX - width / 2,
                          y: visibleFrame.minY + bottomInset)
        }

        let minimumX = visibleFrame.minX + edgeInset
        let maximumX = max(minimumX, visibleFrame.maxX - width - edgeInset)
        let minimumY = visibleFrame.minY + minimumBottomClearance
        let maximumY = max(minimumY, visibleFrame.maxY - CapsuleState.height - edgeInset)
        return NSPoint(x: min(max(raw.x, minimumX), maximumX),
                       y: min(max(raw.y, minimumY), maximumY))
    }

    private func restingOrigin(width: CGFloat, on screen: NSScreen?) -> NSPoint {
        guard let screen else { return .zero }
        return Self.origin(
            width: width,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            storedCentreOffset: positions.offset(forDisplay: CapsulePositionStore.identifier(for: screen)))
    }

    private func rememberPosition() {
        guard let panel, let screen = panel.screen ?? targetScreen() else { return }
        let offset = CGPoint(x: panel.frame.midX - screen.frame.minX,
                             y: panel.frame.minY - screen.frame.minY)
        positions.setOffset(offset, forDisplay: CapsulePositionStore.identifier(for: screen))
    }
}
