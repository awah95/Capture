import Foundation
import Observation
import os

/// Persists the user's text replacements as a versioned `replacements.json`.
///
/// **This file is new in Task 24 and nothing in the dictation path reads it yet.**
/// `Replacement` and `ReplacementEngine` shipped earlier as a type and a pure
/// function with no home; the Vocabulary screen needs somewhere to put what the user
/// types, and inventing a second persistence pattern would be worse than reusing the
/// one this codebase has already chosen three times. So this is `VocabularyStore`'s
/// shape, deliberately: same versioned file, same corrupt-file backup discipline, same
/// `recoveryWarning` / `lastSaveError` surface. Task 16 must read *this* store when it
/// wires replacements into the pipeline — see `docs/wiring/task24-wiring.md`.
///
/// Order is part of the data: §7.2 says replacements are ordered and rule 2 operates on
/// rule 1's output, so the array order is what `ReplacementEngine.apply` consumes and
/// `move(fromOffsets:toOffset:)` is a real mutation, not a display preference.
@MainActor
@Observable
final class ReplacementStore {
    private(set) var replacements: [Replacement] = []

    /// Set when the file on disk could not be read. The UI surfaces this so a silently
    /// emptied rule list is never mistaken for one the user cleared.
    private(set) var recoveryWarning: String?

    /// The last write failure, cleared by the next successful save. Every mutation
    /// re-attempts the write, so a transient failure self-heals without the in-memory
    /// rules being discarded.
    private(set) var lastSaveError: String?

    private(set) var lastLoadResult: LoadResult = .missing

    enum LoadResult: Equatable {
        case missing
        case loaded
        case corrupt
    }

    private let directory: URL
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.awah.captur", category: "replacements")

    private static let corruptBackupPrefix = "replacements.corrupt"
    private static let fileName = "replacements.json"
    private static let fileVersion = 1

    private struct ReplacementFile: Codable {
        var version: Int
        var replacements: [Replacement]
    }

    /// `directory` holds the file. Tests inject a unique temporary directory;
    /// production passes Application Support/Captur.
    ///
    /// There is deliberately no seed list. A replacement is a claim about what *this*
    /// user's voice is misheard as; a shipped guess would silently rewrite words they
    /// said correctly, which is the one failure a dictation app cannot afford.
    init(directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        fileURL = directory.appendingPathComponent(Self.fileName)
        lastLoadResult = load()
    }

    // MARK: - Mutations

    func replaceAll(_ replacements: [Replacement]) {
        self.replacements = replacements
        save()
    }

    func upsert(_ replacement: Replacement) {
        if let index = replacements.firstIndex(where: { $0.id == replacement.id }) {
            replacements[index] = replacement
        } else {
            replacements.append(replacement)
        }
        save()
    }

    func delete(id: UUID) {
        guard replacements.contains(where: { $0.id == id }) else { return }
        replacements.removeAll { $0.id == id }
        save()
    }

    /// Reorders. Order is semantics here, not presentation.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = replacements
        reordered.move(fromOffsets: source, toOffset: destination)
        replacements = reordered
        save()
    }

    func dismissRecoveryWarning() {
        recoveryWarning = nil
    }

    // MARK: - Persistence

    @discardableResult
    private func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(ReplacementFile.self, from: data)
            // A file written by a newer build may carry fields this one would silently
            // drop on the next save, so treat it as unreadable and preserve it.
            guard file.version <= Self.fileVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            replacements = file.replacements
            return .loaded
        } catch {
            logger.error(
                "Failed to load replacements: \(error.localizedDescription, privacy: .public)"
            )
            backupCorruptFile()
            replacements = []
            recoveryWarning = "Your replacements couldn't be read and were backed up. "
                + "Nothing was deleted — the previous file is still on disk."
            return .corrupt
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(
                ReplacementFile(version: Self.fileVersion, replacements: replacements)
            )
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            lastSaveError = nil
        } catch {
            // Keep the rules in memory. The next mutation retries the write, so a full
            // disk does not cost the user their list.
            lastSaveError = error.localizedDescription
            logger.error(
                "Failed to save replacements: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Copies the unreadable file to a unique, timestamped backup. The original is left
    /// in place and prior backups are never touched.
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
                "Failed to back up corrupt replacements: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        logger.info(
            "Backed up corrupt replacements to \(candidate.lastPathComponent, privacy: .public)"
        )
    }
}
