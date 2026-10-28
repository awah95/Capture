import AppKit
import SwiftUI
import os

// MARK: - Seam

/// What the presenter needs from a window. One production conformer
/// (`MainWindowController`) and one test double.
///
/// The protocol exists so the build/release lifecycle — the part spec §15 actually
/// requires — is testable without an `NSWindow`, and therefore without launching a second
/// Captur that would fight the real one for the global hotkeys and the input device.
@MainActor
protocol MainWindowHosting: AnyObject {
    func present()
}

// MARK: - Presenter

/// Builds the main window on first open and lets go of it on close, spec §15.
///
/// This is a performance requirement, not tidiness: idle memory has to stay under 60 MB,
/// and a `NavigationSplitView` hosting five panes plus a stats column is the largest thing
/// in the process. Task 29 audits it by reading the `deinit` log below.
///
/// The reference graph is one-directional on purpose. The presenter holds the host
/// strongly; the host holds only the `onClose` callback, which captures the presenter
/// **weakly**. A closure capturing the presenter strongly here — or a view model captured
/// by the builder instead of created inside it — turns "released on close" into a leak that
/// still passes every functional test.
@MainActor
final class MainWindowPresenter {

    /// Builds a window and is handed the callback it must invoke when that window closes.
    typealias Build = (_ onClose: @escaping () -> Void) -> MainWindowHosting

    private let build: Build
    private var host: MainWindowHosting?

    var isBuilt: Bool { host != nil }

    init(build: @escaping Build) {
        self.build = build
    }

    /// Opens the window, building it if this is the first open since the last close.
    func open() {
        if host == nil {
            host = build { [weak self] in self?.hostDidClose() }
        }
        host?.present()
    }

    /// Drops the last strong reference. The next `open()` builds a fresh window rather
    /// than resurrecting a torn-down one.
    private func hostDidClose() {
        host = nil
    }
}

// MARK: - Window

/// The resizable main workspace, titled and hosting the native SwiftUI sidebar.
///
/// Modelled on `FirstRunWindowController` — the house pattern for an `NSWindowController`
/// with a SwiftUI root — with one difference that matters: this one is *released* when it
/// closes, so it must not be held anywhere but by `MainWindowPresenter`.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    /// Spec §10. Asserted in `HomeViewModelTests` so a "while I'm here" resize shows up as
    /// a failing test rather than as a screenshot nobody compares.
    static let contentSize = NSSize(width: 1080, height: 740)

    nonisolated private static let logger = Logger(subsystem: "com.awah.captur", category: "window")

    private let onClose: () -> Void

    /// - Parameters:
    ///   - panes: the six sidebar panes. Build any view model **inside** these closures,
    ///     not outside them: a model captured from the enclosing scope outlives the window
    ///     and quietly defeats the release-on-close requirement.
    ///   - onClose: invoked once, after the window has closed.
    init(panes: SidebarView.Panes,
         navigation: MainWindowNavigation,
         onClose: @escaping () -> Void) {
        self.onClose = onClose

        let hosting = NSHostingController(
            rootView: SidebarView(panes: panes, navigation: navigation))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Captur"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.toolbarStyle = .unified
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(Self.contentSize)
        // Resizable with a floor rather than fixed: the sidebar has a minimum, the split
        // panes have minimums (`HomeLayout`), and a fixed window turns any underestimate
        // of the natural height into permanently unreachable content — the same reason
        // the checklist and Settings windows are resizable.
        window.contentMinSize = NSSize(
            width: 980,
            height: 600)
        // Restores position and size across launches without a stored preference of our
        // own. The frame is UI state, not app data, so `UserDefaults` under AppKit's own
        // key is the right home for it.
        window.setFrameAutosaveName("com.awah.captur.mainWindow")
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // Read by the Task 29 idle-memory audit. Without it, "released on close" is a
        // claim in a comment rather than something anyone can check.
        Self.logger.debug("MainWindowController released")
    }

    // MARK: Presentation

    /// Brings the window forward and — the part that is easy to get wrong — makes the app
    /// active so the window can actually become key.
    ///
    /// Captur is `LSUIElement`, so it has no Dock tile and is never activated by a click on
    /// one. Without an explicit activation the window orders front but stays *inactive*:
    /// visible, apparently normal, and unable to accept a keystroke. Every text field in
    /// the sidebar — the Groq key, the mode prompt editor, the vocabulary search — is dead
    /// in that state.
    ///
    /// Three deliberate choices:
    ///
    /// 1. **`NSApp.activate()`, not `activate(ignoringOtherApps: true)`.** The older call
    ///    is deprecated and its flag is now ignored; the modern one cooperates with the
    ///    frontmost app. Setup and Diagnostics share the same presentation helper.
    /// 2. **Activate first, then make key.** Activation is asynchronous, and a
    ///    `makeKeyAndOrderFront` issued before it lands can be undone by the activation
    ///    that follows.
    /// 3. **`orderFrontRegardless()` as the floor.** Cooperative activation can be
    ///    *denied* — an accessory app is only eligible off the back of a recent user
    ///    interaction, which the menu-bar click or ⌘, that got us here normally provides,
    ///    but not always. If it is denied, this guarantees the window is at least on
    ///    screen so a click can focus it, instead of the app appearing to do nothing.
    func present() {
        // 0. **Become a regular app for as long as a window is open.** Measured, not
        //    assumed: with the policy left at `.accessory`, opening this window from the
        //    menu put a fully-drawn 900×652 window on screen with grey traffic lights and
        //    Captur *not* frontmost — visible, complete, and unable to accept a
        //    keystroke. Settings holds an API-key field and a shortcut recorder, so a
        //    window that cannot take focus is not a cosmetic problem.
        //
        //    The spec's "the app stays LSUIElement" is about not shipping a permanent
        //    Dock tile, and this keeps that: the tile exists only while a window is open
        //    and goes away with it. `.accessory` is restored in `windowWillClose`.
        CapturWindowPresentation.present(self)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only. Checked against every other window the app can own, so
        // closing Home while Diagnostics or the first-run checklist is still up does not
        // strand those without a Dock tile or the ability to take focus.
        CapturWindowPresentation.restoreAccessoryPolicy(excluding: notification.object as? NSWindow)

        // Deferred by one turn of the run loop. `onClose` drops the last strong reference
        // to this controller, and therefore to the window AppKit is still in the middle of
        // closing — releasing it synchronously inside its own delegate callback is a
        // use-after-free waiting for a slow machine.
        let onClose = self.onClose
        DispatchQueue.main.async { onClose() }
    }
}

extension MainWindowController: MainWindowHosting {}
