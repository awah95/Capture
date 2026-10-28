import AVFoundation
import AppKit
import Foundation
import IOKit.hid

// MARK: - Prerequisites

/// One row of the setup checklist.
struct Prerequisite: Equatable, Identifiable {
    /// The order of the cases is the order of the checklist, and it is deliberate:
    /// the key is the only row a user can satisfy without leaving the app, and the
    /// three permissions descend from "dictation cannot start" to "the push-to-talk
    /// key cannot be seen".
    enum Kind: String, CaseIterable, Sendable {
        case groqKey, openRouterKey, microphone, accessibility, inputMonitoring
    }

    let id: Kind
    var isSatisfied: Bool
}

/// A tri-state that macOS permissions actually have. The distinction matters:
/// `notDetermined` can be answered with a system prompt, `denied` cannot — macOS
/// silently ignores a second request, so the only honest move is a deep link into
/// System Settings.
enum PermissionStatus: String, Equatable, Sendable {
    case notDetermined, granted, denied
}

@MainActor
protocol MicrophonePermitting: AnyObject {
    func status() -> PermissionStatus
    /// Shows the system prompt. Only meaningful while `status()` is `.notDetermined`.
    func request() async -> Bool
}

@MainActor
protocol InputMonitoringPermitting: AnyObject {
    func status() -> PermissionStatus
    func request() -> Bool
}

// MARK: - Live probes

@MainActor
final class SystemMicrophonePermission: MicrophonePermitting {
    init() {}

    func status() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Input Monitoring — TCC's `kTCCServiceListenEvent`.
///
/// The app needs it for exactly one thing: the global
/// `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` monitor in
/// `HotkeyManager`, which is how push-to-talk sees Right ⌥ go down and up while
/// another app is frontmost. Carbon `RegisterEventHotKey` combos (⌥Space) do *not*
/// need it, which is why the app appears to work without it right up until someone
/// tries to hold the key — the failure it prevents is silent, so it belongs on the
/// checklist rather than in a runtime error.
@MainActor
final class SystemInputMonitoringPermission: InputMonitoringPermitting {
    init() {}

    func status() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

// MARK: - Controller

/// The setup checklist's state, spec §10.6.
///
/// Reads live status on demand only. There is no timer: a poll would wake the app
/// forever to answer a question that changes at most a handful of times in its life,
/// and the two moments that actually matter — the window opening and the app coming
/// back to the front after a trip to System Settings — are both events the composition
/// root already sees. It calls `refresh()` there.
@MainActor
final class FirstRunController: ObservableObject {

    @Published private(set) var prerequisites: [Prerequisite] = []
    /// Set by `dismiss()`. Hides the checklist for now; it never marks a row satisfied.
    @Published private(set) var isDismissed = false

    var needsSetup: Bool { prerequisites.contains { !$0.isSatisfied } }

    /// Spec §10.6: the checklist "disappears from launch once every row is satisfied".
    /// Satisfaction is the only thing that suppresses it — a dismissal lasts for the
    /// session, not for the install, because an unsatisfied prerequisite means the app
    /// does not work and quietly forgetting that would be worse than the interruption.
    var shouldPresentAtLaunch: Bool { needsSetup }

    /// Invoked when `request(.groqKey)` fires. The key row is answered inside the
    /// checklist — there is no system prompt and no Settings pane to deep-link into —
    /// so the view uses this to focus its `GroqKeyField`.
    var onRevealKeyField: (() -> Void)?
    var onRevealOpenRouterKeyField: (() -> Void)?

    /// The most recent `request(_:)`, so a caller (and a test) can await it. The
    /// microphone prompt is asynchronous; the others are not, but they all land here
    /// so there is one thing to wait on.
    private(set) var inFlightRequest: Task<Void, Never>?

    private let keyStore: any GroqKeyStoring
    private let openRouterKeyStore: (any OpenRouterKeyStoring)?
    private let microphone: any MicrophonePermitting
    private let accessibility: any TextInserting
    private let inputMonitoring: any InputMonitoringPermitting
    private let openSystemSettings: (URL) -> Void
    private let requiresGroqKey: () -> Bool
    private let requiresOpenRouterKey: () -> Bool

    init(keyStore: any GroqKeyStoring,
         openRouterKeyStore: (any OpenRouterKeyStoring)? = nil,
         microphone: any MicrophonePermitting,
         accessibility: any TextInserting,
         inputMonitoring: any InputMonitoringPermitting,
         requiresGroqKey: @escaping () -> Bool = { true },
         requiresOpenRouterKey: @escaping () -> Bool = { false },
         openSystemSettings: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.keyStore = keyStore
        self.openRouterKeyStore = openRouterKeyStore
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.requiresGroqKey = requiresGroqKey
        self.requiresOpenRouterKey = requiresOpenRouterKey
        self.openSystemSettings = openSystemSettings
        refresh()
    }

    /// Re-reads every prerequisite from its live source. Cheap, synchronous, and the
    /// only thing that changes `prerequisites`.
    func refresh() {
        let key = keyStore.groqKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let openRouterKey = openRouterKeyStore?.openRouterKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        prerequisites = [
            requiresGroqKey() ? Prerequisite(id: .groqKey, isSatisfied: !key.isEmpty) : nil,
            requiresOpenRouterKey()
                ? Prerequisite(id: .openRouterKey, isSatisfied: !openRouterKey.isEmpty) : nil,
            Prerequisite(id: .microphone, isSatisfied: microphone.status() == .granted),
            Prerequisite(id: .accessibility, isSatisfied: accessibility.hasAccessibilityPermission()),
            Prerequisite(id: .inputMonitoring, isSatisfied: inputMonitoring.status() == .granted)
        ].compactMap { $0 }
    }

    /// The single button on a row. Permissions are requested *here*, deliberately —
    /// never mid-dictation, where a modal prompt would eat the user's first sentence.
    func request(_ kind: Prerequisite.Kind) {
        inFlightRequest = Task { @MainActor [weak self] in
            guard let self else { return }
            switch kind {
            case .groqKey:
                self.onRevealKeyField?()

            case .openRouterKey:
                self.onRevealOpenRouterKeyField?()

            case .microphone:
                if self.microphone.status() == .notDetermined {
                    _ = await self.microphone.request()
                } else {
                    self.openSettings(Self.microphoneSettingsURL)
                }

            case .accessibility:
                // AX has no `notDetermined`: the process is trusted or it is not.
                // The prompt is the right move while untrusted (it offers the pane);
                // once trusted, the only useful button is "show me where that lives".
                if self.accessibility.hasAccessibilityPermission() {
                    self.openSettings(Self.accessibilitySettingsURL)
                } else {
                    self.accessibility.requestAccessibilityPermission()
                }

            case .inputMonitoring:
                // Always ask first, whatever the status says.
                //
                // `IOHIDRequestAccess` is what puts an app into the Input Monitoring
                // list at all. Calling it only while `notDetermined` produced a dead
                // end on real hardware: macOS reported `denied`, so the button opened
                // System Settings — to a list the app was not in, with nothing to
                // switch on and no way to add it. Asking again when already denied is
                // harmless (it returns false without prompting) and it re-registers
                // the app, so Settings then has a row to toggle.
                let granted = self.inputMonitoring.request()
                if !granted, self.inputMonitoring.status() != .granted {
                    self.openSettings(Self.inputMonitoringSettingsURL)
                }
            }
            self.refresh()
        }
    }

    func dismiss() { isDismissed = true }

    func reopen() {
        isDismissed = false
        refresh()
    }

    // MARK: System Settings deep links

    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    static let inputMonitoringSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")

    private func openSettings(_ url: URL?) {
        guard let url else { return }
        openSystemSettings(url)
    }
}
