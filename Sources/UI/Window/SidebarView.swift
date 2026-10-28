import SwiftUI

/// Programmatic navigation for every route into the main window.
///
/// Sidebar clicks, Home's deep links, the menu bar, and global shortcuts all write to
/// this one value. Keeping it outside `SidebarView` is what lets a button in one pane
/// select another pane without reaching through SwiftUI's view hierarchy.
@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published var selection: SidebarView.Tab
    @Published private(set) var typingTestRequestID = 0
    private var handledTypingTestRequestID = 0

    init(selection: SidebarView.Tab = .home) {
        self.selection = selection
    }

    func show(_ tab: SidebarView.Tab) {
        selection = tab
    }

    func startTypingTest() {
        selection = .stats
        typingTestRequestID += 1
    }

    func consumeTypingTestRequest() -> Bool {
        guard typingTestRequestID > handledTypingTestRequestID else { return false }
        handledTypingTestRequestID = typingTestRequestID
        return true
    }
}

/// The main window's shell, spec §10: a `NavigationSplitView` with five tabs.
///
/// **Every pane is an injected view builder.** Home is the only screen this file knows
/// how to build; History, Modes, Vocabulary and Settings arrive as
/// `() -> AnyView` closures from the composition root. That is not indirection for its
/// own sake — those four screens are being built on parallel branches, and a sidebar that
/// named their types could not compile until all of them had merged. It also means the
/// window shell has no opinion about what a tab contains, which is the property that lets
/// Settings move out of its own window (see `docs/wiring/task21-wiring.md`) without this
/// file changing.
///
/// `AnyView` costs a type erasure per tab switch and buys the merge order. At five panes
/// rebuilt on click, that is not a performance question.
struct SidebarView: View {

    /// Spec §10: "Home · History · Modes · Vocabulary · Settings", in that order.
    ///
    /// Stats sits after Home rather than at the end: it is the other half of what Home
    /// shows, and spec §11 treats the two as one story told at two depths.
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case home, stats, history, modes, vocabulary, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Overview"
            case .stats: return "Analytics"
            case .history: return "Captures"
            case .modes: return "Modes"
            case .vocabulary: return "Vocabulary"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .home: return "square.grid.2x2"
            case .stats: return "chart.xyaxis.line"
            case .history: return "waveform"
            case .modes: return "slider.horizontal.3"
            case .vocabulary: return "character.book.closed"
            case .settings: return "gearshape"
            }
        }
    }

    /// The five panes. Each is rebuilt when its tab is selected, so a pane that owns a
    /// view model must be given one that outlives the closure — see the wiring note.
    struct Panes {
        var home: () -> AnyView
        var stats: () -> AnyView
        var history: () -> AnyView
        var modes: () -> AnyView
        var vocabulary: () -> AnyView
        var settings: () -> AnyView

        init(
            home: @escaping () -> AnyView,
            stats: @escaping () -> AnyView = { SidebarView.pending(.stats, task: 26) },
            history: @escaping () -> AnyView = { SidebarView.pending(.history, task: 22) },
            modes: @escaping () -> AnyView = { SidebarView.pending(.modes, task: 23) },
            vocabulary: @escaping () -> AnyView = { SidebarView.pending(.vocabulary, task: 24) },
            settings: @escaping () -> AnyView = { SidebarView.pending(.settings, task: 25) }
        ) {
            self.home = home
            self.stats = stats
            self.history = history
            self.modes = modes
            self.vocabulary = vocabulary
            self.settings = settings
        }
    }

    let panes: Panes
    @ObservedObject var navigation: MainWindowNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section("Workspace") {
                    ForEach([Tab.home, .stats, .history]) { tab in
                        navigationRow(tab)
                    }
                }
                Section("Personalize") {
                    ForEach([Tab.modes, .vocabulary, .settings]) { tab in
                        navigationRow(tab)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 12) {
                HStack(spacing: 10) {
                    CapturMark()
                    Text("Captur").font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            pane(for: navigation.selection)
                .frame(minWidth: 560, minHeight: 380)
                .background(CapturPalette.canvas)
                // Set here rather than in each pane. SwiftUI KEEPS the last title a view
                // provided, so with only Home and Stats setting one, the window read
                // "Stats" while Modes and Settings were on screen — seen in the LV8
                // screenshots. One place cannot drift out of step with the selection.
                .navigationTitle(navigation.selection.title)
        }
        .tint(CapturPalette.accent)
    }

    private func navigationRow(_ tab: Tab) -> some View {
        NavigationLink(value: tab) {
            Label(tab.title, systemImage: tab.symbol)
                .font(.system(size: 13, weight: .medium))
                .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func pane(for tab: Tab) -> some View {
        switch tab {
        case .home: panes.home()
        case .stats: panes.stats()
        case .history: panes.history()
        case .modes: panes.modes()
        case .vocabulary: panes.vocabulary()
        case .settings: panes.settings()
        }
    }

    /// An honest stand-in for a screen that has not merged yet.
    ///
    /// It names the task rather than saying "coming soon", because the only person who
    /// will ever see it is the one who can read the plan — and a placeholder that hides
    /// which branch owns it is a placeholder nobody can act on. Every one of these
    /// disappears by being replaced with a real pane in `Panes`, not by editing this file.
    static func pending(_ tab: Tab, task: Int) -> AnyView {
        AnyView(
            EmptyState(message: "\(tab.title) lands with Task \(task).",
                       symbol: tab.symbol)
        )
    }
}
