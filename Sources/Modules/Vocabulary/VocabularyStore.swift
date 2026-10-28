import Foundation
import Observation
import os

/// Persists the custom vocabulary as a versioned JSON file.
///
/// The vocabulary is user-authored and unrecoverable if lost, so an unreadable
/// file is copied to a timestamped backup and the store starts empty rather than
/// the file being overwritten in place. Backups are never deleted: a second
/// corruption cannot erase the salvage from the first.
@MainActor
@Observable
final class VocabularyStore {
    private(set) var terms: [VocabularyTerm] = []

    /// Set when the file on disk could not be read. The UI surfaces this so a
    /// silently-emptied vocabulary is never mistaken for one the user cleared.
    private(set) var recoveryWarning: String?

    /// The last write failure, if any. Cleared by the next successful save.
    /// Every mutation re-attempts the write, so a transient failure self-heals
    /// without the in-memory vocabulary being discarded.
    private(set) var lastSaveError: String?

    private(set) var lastLoadResult: LoadResult = .missing

    enum LoadResult: Equatable {
        case missing
        case loaded
        case corrupt
    }

    private let directory: URL
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.awah.captur", category: "vocabulary")

    /// Prefix shared by every corrupt-file backup, so they can be found and
    /// counted without knowing their timestamps.
    private static let corruptBackupPrefix = "vocabulary.corrupt"
    private static let fileName = "vocabulary.json"
    private static let fileVersion = 1

    private struct VocabularyFile: Codable {
        var version: Int
        var terms: [VocabularyTerm]
    }

    /// `directory` holds the vocabulary file. Tests inject a unique temporary
    /// directory; production passes Application Support/Captur.
    ///
    /// `seedIfEmpty` puts a starter list in place on a genuinely fresh install so the
    /// feature works the first time it is used rather than starting blank. It only
    /// applies when there is no vocabulary file at all — a user who has deliberately
    /// emptied their list never gets it handed back.
    init(directory: URL, seedIfEmpty: [String] = []) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        fileURL = directory.appendingPathComponent(Self.fileName)
        let hadFile = fileManager.fileExists(atPath: fileURL.path)
        lastLoadResult = load()

        if !hadFile, terms.isEmpty, !seedIfEmpty.isEmpty {
            terms = seedIfEmpty.map {
                VocabularyTerm(id: UUID(), text: $0, soundsLike: nil, isPinned: false,
                               useCount: 0, lastUsed: nil, appBundleIDs: [])
            }
            save()
        }
    }

    /// Common product names and technical terms that speech recognition can miss.
    /// Deliberately short: the Whisper prompt is capped at 224 tokens, so a bloated
    /// starter list would crowd out the terms the user adds themselves.
    static let starterTerms = [
        "Captur", "WordPress", "Groq", "Whisper", "Supabase", "Xcode", "SwiftUI",
        "Claude", "Anthropic", "Opus", "macOS", "Figma", "Slack", "Notion",
        "GitHub", "TypeScript", "Swift", "PHP", "SCSS", "webhook", "API", "UUID",
        "JSON", "SQL"
    ]

    // MARK: - Mutations

    func replaceAll(_ terms: [VocabularyTerm]) {
        self.terms = terms
        save()
    }

    func upsert(_ term: VocabularyTerm) {
        if let index = terms.firstIndex(where: { $0.id == term.id }) {
            terms[index] = term
        } else {
            terms.append(term)
        }
        save()
    }

    func delete(id: UUID) {
        guard terms.contains(where: { $0.id == id }) else { return }
        terms.removeAll { $0.id == id }
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
            let file = try JSONDecoder().decode(VocabularyFile.self, from: data)
            // A file written by a newer build may carry fields this one would
            // silently drop on the next save, so treat it as unreadable and
            // preserve it instead.
            guard file.version <= Self.fileVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            terms = file.terms
            return .loaded
        } catch {
            logger.error(
                "Failed to load vocabulary: \(error.localizedDescription, privacy: .public)"
            )
            backupCorruptFile()
            terms = []
            recoveryWarning = "Your vocabulary couldn't be read and was backed up. "
                + "Nothing was deleted — the previous file is still on disk."
            return .corrupt
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(
                VocabularyFile(version: Self.fileVersion, terms: terms)
            )
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            lastSaveError = nil
        } catch {
            // Keep the terms in memory. The next mutation retries the write, so
            // a full disk or a locked file does not cost the user their list.
            lastSaveError = error.localizedDescription
            logger.error(
                "Failed to save vocabulary: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Copies the unreadable file to a unique, timestamped backup. The original
    /// is left in place and prior backups are never touched.
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
                "Failed to back up corrupt vocabulary: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        logger.info(
            "Backed up corrupt vocabulary to \(candidate.lastPathComponent, privacy: .public)"
        )
    }
}
