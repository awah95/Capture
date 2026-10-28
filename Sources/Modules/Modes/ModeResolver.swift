import Foundation

/// Decides which mode transforms a given capture.
///
/// The ladder is explicit hotkey → website → per-app mapping → global default → `clean`.
/// Every rung falls through to the next when its id names a mode that no longer
/// exists — a mode the user deleted must not strand a hotkey or an app mapping.
///
/// The function is total by construction. Failing to resolve a mode would mean
/// failing to insert words the user has already spoken, which is the one outcome
/// the app cannot offer, so the last resort is the first mode available and the
/// one after that is the `clean` code definition.
enum ModeResolver {

    static func resolve(
        explicitModeID: String?,
        frontmostBundleID: String?,
        perAppMap: [String: String],
        defaultModeID: String,
        available: [Mode],
        websiteHost: String? = nil,
        perWebsiteMap: [String: String] = [:]
    ) -> Mode {
        func lookup(_ id: String?) -> Mode? {
            guard let id else { return nil }
            return available.first { $0.id == id }
        }

        // 1. The user asked for this mode by name, via its own hotkey or the picker.
        if let mode = lookup(explicitModeID) {
            return mode
        }

        // Exact-host rules take priority over the containing browser rule.
        if let websiteHost, let mode = lookup(perWebsiteMap[websiteHost]) { return mode }

        // 2. The app they are typing into has a mapping.
        if let bundleID = frontmostBundleID, let mode = lookup(perAppMap[bundleID]) {
            return mode
        }

        // 3. Their global default.
        if let mode = lookup(defaultModeID) {
            return mode
        }

        // 4. The shipped default, preferring the user's copy of it if they
        //    edited it.
        if let mode = lookup(Mode.clean.id) {
            return mode
        }

        // 5. Anything at all. `available` is only empty in a state the store
        //    cannot produce, but the caller still gets a usable mode.
        return available.first ?? Mode.clean
    }
}
