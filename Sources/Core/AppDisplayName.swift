import Foundation

/// Turning `com.google.Chrome` into `Chrome`.
///
/// Found by opening the main window and looking at it: every row of Home and every bar
/// of "where the words go" was labelled with a raw bundle identifier, because
/// `DictationRecordDraft.open` hard-codes `targetAppName: nil` and nothing has ever
/// filled it in. The pipeline now records the real name, but that does nothing for the
/// records already on disk — hence a fallback that derives something readable from the
/// identifier itself.
///
/// It is a *fallback*, not a formatter: a recorded name always wins, because
/// `dev.warp.Warp-Stable` is called "Warp" and no amount of string surgery will know
/// that.
enum AppDisplayName {

    /// The best available label for an app, or nil when there is nothing to show.
    ///
    /// Never invents a placeholder. `StatsGroup.displayName` is optional for the same
    /// reason: a label that says "Unknown" is a claim about the data, and the honest
    /// answer here is to render nothing.
    static func label(bundleID: String?, recordedName: String?) -> String? {
        if let recordedName, !recordedName.isEmpty { return recordedName }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return derived(from: bundleID)
    }

    /// The last component of a reverse-DNS identifier, tidied.
    ///
    /// `com.google.Chrome` → `Chrome`, `dev.warp.Warp-Stable` → `Warp Stable`,
    /// `com.anthropic.claudefordesktop` → `claudefordesktop` (left alone: splitting a
    /// run-together name needs a dictionary, and a wrong split reads worse than none).
    static func derived(from bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        let spaced = last.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let trimmed = spaced.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? bundleID : trimmed
    }
}
