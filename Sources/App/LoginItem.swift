import Foundation
import ServiceManagement
import os

// MARK: - Status

/// `SMAppService.Status`, restated so nothing above this file has to import
/// ServiceManagement — and so the fourth case cannot be quietly forgotten.
///
/// `requiresApproval` is the case that makes this worth modelling: it is **neither an
/// error nor a success**. macOS accepted the registration and the user (or a policy) has
/// the switch off in System Settings → Login Items. A plain toggle in that state turns
/// on, does nothing, and is off again next time the window opens.
enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    /// launchd cannot find this copy of the app — normally because it is being run from
    /// a build directory rather than `/Applications` (spec §2).
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .notRegistered
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        // A status this build has never heard of must not be reported as `enabled`, and
        // `notFound` would tell the user to move an app that is exactly where it should
        // be. `notRegistered` is the one state whose offered action — try to register —
        // is safe and produces a real error if it cannot work.
        @unknown default: self = .notRegistered
        }
    }
}

// MARK: - Seam

/// Everything `LoginItem` does to the machine.
///
/// A seam because the real implementation writes to the owner's **system state**:
/// `register()` makes this build launch at every login, and `unregister()` would just as
/// happily remove a login item somebody added on purpose. Tests drive the fake; the real
/// type is named exactly once, in `LoginItem.init`'s default argument.
@MainActor protocol LoginItemService {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
    /// Opens System Settings → General → Login Items, for the `requiresApproval` case
    /// where the only fix is a switch the app is not allowed to flip.
    func openSystemSettings()
}

/// The production service. **Never constructed in a test.**
struct SystemLoginItemService: LoginItemService {
    func status() -> LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Login item

/// Launch at login, spec §10.5's General section.
///
/// Nothing about this setting is persisted by Captur: `SMAppService` **is** the store,
/// and a mirrored copy in `UserDefaults` would be wrong the first time the user changed
/// it in System Settings. The status is therefore re-read on demand — on window open and
/// after every change — and never polled (spec §15).
@MainActor
final class LoginItem {
    private let service: any LoginItemService
    private let log = Logger(subsystem: "com.awah.captur", category: "loginitem")

    private(set) var status: LoginItemStatus
    /// The last register/unregister failure, if it has not been superseded by a success.
    private var failure: String?

    /// The service defaults to the real one, expressed as `nil` because a default
    /// argument is evaluated outside the actor and this seam is `@MainActor`. Every test
    /// passes a fake; `SystemLoginItemService` is named nowhere else.
    init(service: (any LoginItemService)? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        // A read, not a write: this asks macOS what it already thinks and registers
        // nothing.
        status = service.status()
    }

    /// True only for `.enabled`. `.requiresApproval` deliberately reads as off: the app
    /// does *not* launch at login in that state, and a toggle that says otherwise is
    /// lying about the one thing it exists to report.
    var isOn: Bool { status == .enabled }

    var needsApproval: Bool { status == .requiresApproval }

    /// What to tell the user, or nil when there is nothing wrong. A failed attempt wins
    /// over a status explanation: it is the more specific and more recent fact.
    var advice: String? {
        if let failure { return failure }
        switch status {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "macOS has registered Captur but the switch is off. Turn Captur on in "
                + "System Settings → General → Login Items, and it will start with your Mac."
        case .notFound:
            return "macOS cannot find this copy of Captur to launch it. Move Captur to your "
                + "Applications folder and try again."
        }
    }

    /// Re-reads the live status. Called on window open, and after any change. The user
    /// visiting System Settings → Login Items is the normal way this changes behind the
    /// app's back, and app activation is the moment that becomes observable — the same
    /// trick the permission checklist uses to avoid a timer.
    func refresh() {
        status = service.status()
    }

    func setEnabled(_ enabled: Bool) {
        // SwiftUI re-sets a binding to the value it already holds; a second `register()`
        // is a system call for nothing.
        guard enabled != isOn else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            failure = nil
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            failure = enabled
                ? "Captur could not be added to your login items: \(error.localizedDescription)"
                : "Captur could not be removed from your login items: \(error.localizedDescription)"
        }

        // Always re-read rather than assuming the attempt did what it said. A successful
        // `register()` can still land in `.requiresApproval`, and a failed one must not
        // leave the toggle claiming success.
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
