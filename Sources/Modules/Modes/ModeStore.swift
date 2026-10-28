import Foundation
import Observation
import os

/// Wraps a value that the user may have overridden *to nil*.
///
/// A plain `Bool?` inside an override cannot tell "the user did not touch this"
/// from "the user cleared this". Wrapping gives the outer optional the first
/// meaning and the inner one the second. It encodes as a JSON object rather
/// than a bare null (`{}` for cleared, `{"value":…}` for set) so the distinction
/// survives `decodeIfPresent`, which collapses an explicit null into nil.
struct NullableOverride<Wrapped: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Wrapped?
}

/// A user's edits to a built-in mode, stored as a sparse per-field diff against
/// the definition in code.
///
/// Storing the diff rather than the whole mode is what lets a later app version
/// improve a prompt the user never touched while leaving the fields they did
/// touch alone — including on the *same* mode, so renaming Note does not freeze
/// its prompt forever.
///
/// `id`, `isBuiltIn`, and `usesLLM` are deliberately absent: they are structural.
/// Verbatim's identity is that it does not call out to a model, and no amount of
/// customization should be able to turn that into a network round trip.
struct ModeOverride: Codable, Equatable, Sendable {
    var name: String?
    var symbol: String?
    var systemPrompt: String?
    var cleanupChoice: ModeCleanupChoice?
    var refinementProvider: RefinementProviderID?
    var model: String?
    var reasoningEffort: ReasoningEffort?
    var temperature: Double?
    var includeClipboardContext: Bool?
    var contextOptions: ModeContextOptions?
    var includeAppNameContext: Bool?
    var autoPaste: NullableOverride<Bool>?
    var hotkey: NullableOverride<KeyCombo>?

    var isEmpty: Bool { self == ModeOverride() }

    /// The fields of `edited` that differ from the shipped definition.
    static func diff(_ edited: Mode, against builtIn: Mode) -> ModeOverride {
        var override = ModeOverride()
        if edited.name != builtIn.name { override.name = edited.name }
        if edited.symbol != builtIn.symbol { override.symbol = edited.symbol }
        if edited.systemPrompt != builtIn.systemPrompt {
            override.systemPrompt = edited.systemPrompt
        }
        if edited.cleanupChoice != builtIn.cleanupChoice {
            override.cleanupChoice = edited.cleanupChoice
        }
        if edited.refinementProvider != builtIn.refinementProvider {
            override.refinementProvider = edited.refinementProvider
        }
        if edited.model != builtIn.model { override.model = edited.model }
        if edited.reasoningEffort != builtIn.reasoningEffort {
            override.reasoningEffort = edited.reasoningEffort
        }
        if edited.temperature != builtIn.temperature {
            override.temperature = edited.temperature
        }
        if edited.includeClipboardContext != builtIn.includeClipboardContext {
            override.includeClipboardContext = edited.includeClipboardContext
        }
        if edited.includeAppNameContext != builtIn.includeAppNameContext {
            override.includeAppNameContext = edited.includeAppNameContext
        }
        if edited.contextOptions != builtIn.contextOptions {
            override.contextOptions = edited.contextOptions
        }
        if edited.autoPaste != builtIn.autoPaste {
            override.autoPaste = NullableOverride(value: edited.autoPaste)
        }
        if edited.hotkey != builtIn.hotkey {
            override.hotkey = NullableOverride(value: edited.hotkey)
        }
        return override
    }

    /// `builtIn` with this override's fields laid over it.
    func applied(to builtIn: Mode) -> Mode {
        var mode = builtIn
        if let contextOptions { mode.contextOptions = contextOptions }
        if let name { mode.name = name }
        if let symbol { mode.symbol = symbol }
        if let systemPrompt { mode.systemPrompt = systemPrompt }
        if let cleanupChoice { mode.cleanupChoice = cleanupChoice }
        if let refinementProvider { mode.refinementProvider = refinementProvider }
        if let model { mode.model = model }
        if let reasoningEffort { mode.reasoningEffort = reasoningEffort }
        if let temperature { mode.temperature = temperature }
        if let includeClipboardContext {
            mode.includeClipboardContext = includeClipboardContext
        }
        if let includeAppNameContext {
            mode.includeAppNameContext = includeAppNameContext
        }
        if let autoPaste { mode.autoPaste = autoPaste.value }
        if let hotkey { mode.hotkey = hotkey.value }
        return mode
    }
}

/// Persists mode customization as a versioned `modes.json`.
///
/// Built-in definitions live in code; the file holds only the user's deltas.
/// Custom modes have no definition in code, so those are stored whole.
///
/// An unreadable file is copied to a timestamped backup and the store starts
/// from the built-ins, matching the vocabulary store: nothing the user authored
/// is ever destroyed to make a load succeed.
@MainActor
@Observable
final class ModeStore {

    /// The merged list: built-ins in shipped order with any overrides applied,
    /// followed by custom modes in the order the user created them.
    private(set) var modes: [Mode] = []

    private(set) var perAppMap: [String: String] = [:]
    private(set) var defaultModeID: String = Mode.clean.id

    /// Set when the file on disk could not be read, so the UI never lets a
    /// silently-reset set of modes pass for one the user chose.
    private(set) var recoveryWarning: String?

    /// The last write failure, cleared by the next successful save. Every
    /// mutation re-attempts the write, so a transient failure self-heals.
    private(set) var lastSaveError: String?

    private(set) var lastLoadResult: LoadResult = .missing

    enum LoadResult: Equatable {
        case missing
        case loaded
        case corrupt
    }

    /// Apps whose mode is obvious enough to be right more often than not. The
    /// user can change any of these; they exist so the first dictation into
    /// Slack or a terminal already behaves.
    static let defaultPerAppMap: [String: String] = [
        "com.tinyspeck.slackmacgap": "message",
        "com.apple.mail": "email",
        "com.apple.Terminal": "code",
        "com.googlecode.iterm2": "code",
        "com.mitchellh.ghostty": "code",
        "com.microsoft.VSCode": "code",
        "com.apple.dt.Xcode": "code",
    ]

    private let builtIns: [Mode]
    private let directory: URL
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.awah.captur", category: "modes")

    private var overrides: [String: ModeOverride] = [:]
    private var customModes: [Mode] = []

    private static let corruptBackupPrefix = "modes.corrupt"
    private static let fileName = "modes.json"
    private static let fileVersion = 3
    private var loadedFileVersion: Int?

    private struct ModesFile: Codable {
        var version: Int
        var overrides: [String: ModeOverride]
        var customModes: [Mode]
        var perAppMap: [String: String]
        var defaultModeID: String
    }

    /// `directory` holds the modes file. Tests inject a unique temporary
    /// directory; production passes Application Support/Captur.
    ///
    /// `builtIns` is injectable so a test can stand in for a later app version
    /// whose shipped prompts have changed.
    init(directory: URL, builtIns: [Mode] = Mode.builtIns,
         legacyCleanCleanupChoice: ModeCleanupChoice = .currentMode) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.builtIns = builtIns
        fileURL = directory.appendingPathComponent(Self.fileName)
        lastLoadResult = load()
        // v3 makes mode settings authoritative. Saving the version with the
        // migrated choice prevents the old preference from re-enabling local
        // cleanup after the user changes or resets Clean.
        if lastLoadResult == .loaded, (loadedFileVersion ?? 0) < Self.fileVersion {
            migrateLegacyCleanCleanup(legacyCleanCleanupChoice)
            save()
        } else if lastLoadResult == .missing, legacyCleanCleanupChoice == .localS1Mini {
            migrateLegacyCleanCleanup(legacyCleanCleanupChoice)
            save()
        }
    }

    // MARK: - Reads

    func mode(id: String) -> Mode? {
        modes.first { $0.id == id }
    }

    func automaticModesUse(_ provider: RefinementProviderID) -> Bool {
        let ids = Set(perAppMap.values).union([defaultModeID])
        return ids.compactMap { mode(id: $0) }
            .contains { $0.usesProviderRefinement && $0.refinementProvider == provider }
    }

    private func builtIn(id: String) -> Mode? {
        builtIns.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Upserts a mode. A built-in is reduced to a diff against its shipped
    /// definition; an edit that restores every field drops the override
    /// entirely, so the mode resumes tracking future app versions.
    func update(_ mode: Mode) {
        if let shipped = builtIn(id: mode.id) {
            let override = ModeOverride.diff(mode, against: shipped)
            if override.isEmpty {
                overrides.removeValue(forKey: mode.id)
            } else {
                overrides[mode.id] = override
            }
        } else {
            var custom = mode
            custom.isBuiltIn = false
            if let index = customModes.firstIndex(where: { $0.id == custom.id }) {
                customModes[index] = custom
            } else {
                customModes.append(custom)
            }
        }
        rebuild()
        save()
    }

    /// Discards the user's edits to a built-in.
    func resetToBuiltIn(id: String) {
        guard overrides.removeValue(forKey: id) != nil else { return }
        rebuild()
        save()
    }

    /// Removes a custom mode. Built-ins are not deletable — they can only be
    /// reset — so an id that names one is ignored.
    func deleteCustom(id: String) {
        guard builtIn(id: id) == nil,
              customModes.contains(where: { $0.id == id }) else { return }
        customModes.removeAll { $0.id == id }
        // A dangling default would silently resolve to clean forever with
        // nothing in the UI to show why, so point it somewhere real.
        if defaultModeID == id {
            defaultModeID = Mode.clean.id
        }
        rebuild()
        save()
    }

    func setDefaultModeID(_ id: String) {
        guard defaultModeID != id else { return }
        defaultModeID = id
        save()
    }

    /// Passing nil clears the app's mapping, returning it to the global default.
    func setMode(_ modeID: String?, forBundleID bundleID: String) {
        if let modeID {
            guard perAppMap[bundleID] != modeID else { return }
            perAppMap[bundleID] = modeID
        } else {
            guard perAppMap[bundleID] != nil else { return }
            perAppMap.removeValue(forKey: bundleID)
        }
        save()
    }

    func dismissRecoveryWarning() {
        recoveryWarning = nil
    }

    // MARK: - Merge

    private func rebuild() {
        modes = builtIns.map { shipped in
            guard let override = overrides[shipped.id] else { return shipped }
            return override.applied(to: shipped)
        } + customModes
    }

    private func seedFromBuiltIns() {
        overrides = [:]
        customModes = []
        perAppMap = Self.defaultPerAppMap
        defaultModeID = Mode.clean.id
        rebuild()
    }

    // MARK: - Persistence

    private func migrateLegacyCleanCleanup(_ choice: ModeCleanupChoice) {
        guard choice == .localS1Mini, let clean = builtIn(id: Mode.clean.id), clean.usesLLM,
              overrides[clean.id]?.cleanupChoice == nil else { return }
        var override = overrides[clean.id] ?? ModeOverride()
        override.cleanupChoice = choice
        overrides[clean.id] = override
        rebuild()
    }

    @discardableResult
    private func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            seedFromBuiltIns()
            return .missing
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(ModesFile.self, from: data)
            // A file written by a newer build may carry fields this one would
            // silently drop on the next save, so treat it as unreadable and
            // preserve it rather than quietly truncating the user's setup.
            guard file.version <= Self.fileVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            loadedFileVersion = file.version
            overrides = file.overrides
            if file.version < 2 {
                // Before v2 every model override was necessarily a Groq model.
                // Preserve that meaning instead of combining a legacy model id
                // with a built-in that may now ship on another provider.
                for id in overrides.keys where overrides[id]?.model != nil
                    && overrides[id]?.refinementProvider == nil {
                    overrides[id]?.refinementProvider = .groq
                    overrides[id]?.reasoningEffort = .providerDefault
                }
            }
            customModes = file.customModes.map { mode in
                var mode = mode
                mode.isBuiltIn = false
                return mode
            }
            perAppMap = file.perAppMap
            defaultModeID = file.defaultModeID
            rebuild()
            return .loaded
        } catch {
            logger.error(
                "Failed to load modes: \(error.localizedDescription, privacy: .public)"
            )
            backupCorruptFile()
            seedFromBuiltIns()
            recoveryWarning = "Your modes couldn't be read and were backed up. "
                + "Nothing was deleted — the previous file is still on disk."
            return .corrupt
        }
    }

    private func save() {
        do {
            let file = ModesFile(
                version: Self.fileVersion,
                overrides: overrides,
                customModes: customModes,
                perAppMap: perAppMap,
                defaultModeID: defaultModeID
            )
            let data = try JSONEncoder().encode(file)
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            lastSaveError = nil
        } catch {
            // Keep the modes in memory. The next mutation retries the write, so
            // a full disk or a locked file does not cost the user their setup.
            lastSaveError = error.localizedDescription
            logger.error(
                "Failed to save modes: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Copies the unreadable file to a unique, timestamped backup. The original
    /// is left in place and prior backups are never touched, so a second
    /// corruption cannot erase the salvage from the first.
    private func backupCorruptFile() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        // Colons are legal in POSIX paths but confuse the Finder/Carbon layer.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var candidate = directory.appendingPathComponent(
            "\(Self.corruptBackupPrefix)-\(stamp).json"
        )
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(
                "\(Self.corruptBackupPrefix)-\(stamp)-\(suffix).json"
            )
            suffix += 1
        }

        do {
            try fileManager.copyItem(at: fileURL, to: candidate)
        } catch {
            logger.error(
                "Failed to back up corrupt modes: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        logger.info(
            "Backed up corrupt modes to \(candidate.lastPathComponent, privacy: .public)"
        )
    }
}
