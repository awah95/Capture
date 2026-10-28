import Foundation
import Observation
import os

/// Persists captures as a versioned JSON index alongside their audio files.
///
/// Terminal dictations are capped, while thoughts and all non-terminal captures
/// are retained. A corrupt index is backed up without deleting any audio.
@MainActor
@Observable
final class CaptureStore {
    private(set) var captures: [Capture] = []

    private let dictationCap = 10

    private(set) var recoveryWarning: String?

    /// The last index-write failure, if any. Cleared on the next successful save.
    /// Every mutation re-attempts the write, so a transient failure self-heals
    /// without ever discarding captures or their audio.
    private(set) var lastSaveError: String?

    private let audioDir: URL
    private let baseDir: URL
    private let indexURL: URL
    private let logger = Logger(subsystem: "com.awah.quickcapturemac", category: "store")

    /// Prefix shared by every corrupt-index backup. Backups are timestamped and
    /// never deleted, so a repeated corruption can't erase an earlier salvage.
    private static let corruptBackupPrefix = "captures-index.corrupt"

    enum LoadResult: Equatable {
        case missing
        case loaded
        case corrupt
    }

    private struct IndexFile: Codable {
        var version: Int
        var captures: [Capture]
    }

    private static let indexVersion = 2

    /// `baseURL` is the directory containing the index and `captures` directory.
    /// Tests inject a unique temporary directory. Production uses
    /// Application Support/Captur.
    init(baseURL: URL? = nil) {
        let fileManager = FileManager.default
        let base: URL = baseURL ?? AppPaths.supportDirectory(fileManager: fileManager)

        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        baseDir = base
        audioDir = base.appendingPathComponent("captures", isDirectory: true)
        try? fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
        indexURL = base.appendingPathComponent("captures-index.json")

        switch load() {
        case .loaded:
            // Orphan deletion is only safe against a fully readable index. A
            // corruption backup may be the only remaining map from captures to
            // their audio, so never prune while one survives on disk.
            if !hasCorruptBackup() {
                reconcileOrphanedAudio()
            }
        case .missing:
            // A missing index is indistinguishable from a transient index-write
            // failure, so it is NOT proof the audio is orphaned. Never delete
            // here — quarantine any unreferenced audio as recovered captures so
            // transcription can be retried and nothing is lost.
            quarantineUnreferencedAudio()
        case .corrupt:
            // load() already backed the index up; audio is untouched.
            break
        }
    }

    // MARK: - Audio file locations

    var audioDirectory: URL { audioDir }

    func newAudioURL(for id: UUID) -> URL {
        try? FileManager.default.createDirectory(
            at: audioDir,
            withIntermediateDirectories: true
        )
        return audioDir.appendingPathComponent("\(id.uuidString).m4a")
    }

    func audioURL(for capture: Capture) -> URL? {
        guard let name = capture.audioFileName else { return nil }
        let url = audioDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func importedAudioURL(for id: UUID) -> URL {
        try? FileManager.default.createDirectory(
            at: audioDir,
            withIntermediateDirectories: true
        )
        return audioDir.appendingPathComponent("\(id.uuidString).m4a")
    }

    // MARK: - Mutations

    func upsert(_ capture: Capture) {
        var capture = capture
        capture.updatedAt = Date()
        if let index = captures.firstIndex(where: { $0.id == capture.id }) {
            captures[index] = capture
        } else {
            captures.append(capture)
        }
        captures.sort { $0.createdAt > $1.createdAt }
        prune()
        save()
    }

    @discardableResult
    func update(_ id: UUID, _ mutate: (inout Capture) -> Void) -> Capture? {
        guard let index = captures.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        mutate(&captures[index])
        captures[index].updatedAt = Date()
        save()
        return captures[index]
    }

    func capture(_ id: UUID) -> Capture? {
        captures.first { $0.id == id }
    }

    @discardableResult
    func importIfNew(_ capture: Capture) -> Bool {
        guard self.capture(capture.id) == nil else { return false }
        upsert(capture)
        return true
    }

    func delete(_ capture: Capture) {
        if let url = audioURL(for: capture) {
            try? FileManager.default.removeItem(at: url)
        }
        captures.removeAll { $0.id == capture.id }
        save()
    }

    func clear() {
        for capture in captures {
            if let url = audioURL(for: capture) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        captures.removeAll()
        save()
    }

    func clear(mode: CaptureMode) {
        for capture in captures where capture.mode == mode {
            if let url = audioURL(for: capture) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        captures.removeAll { $0.mode == mode }
        save()
    }

    func dismissRecoveryWarning() {
        recoveryWarning = nil
    }

    func recoverable() -> [Capture] {
        captures.filter {
            ($0.status == .pending || $0.status == .transcribing || $0.status == .failed)
                && audioURL(for: $0) != nil
        }
    }

    // MARK: - Persistence

    private func isPrunable(_ capture: Capture) -> Bool {
        capture.mode == .dictation
            && capture.status.isTerminal
            && capture.transferState != .queued
            && capture.transferState != .sending
    }

    private func prune() {
        let terminalDictations = captures.filter(isPrunable)
        guard terminalDictations.count > dictationCap else { return }

        let overflow = terminalDictations.dropFirst(dictationCap)
        guard !overflow.isEmpty else { return }
        for capture in overflow {
            if let url = audioURL(for: capture) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let ids = Set(overflow.map(\.id))
        captures.removeAll { ids.contains($0.id) }
    }

    @discardableResult
    private func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: indexURL)
            if let index = try? JSONDecoder().decode(IndexFile.self, from: data) {
                guard index.version <= Self.indexVersion else {
                    throw CocoaError(.coderReadCorrupt)
                }
                captures = index.captures.sorted { $0.createdAt > $1.createdAt }
            } else {
                captures = try JSONDecoder().decode([Capture].self, from: data)
                    .sorted { $0.createdAt > $1.createdAt }
            }
            return .loaded
        } catch {
            logger.error(
                "Failed to load capture index: \(error.localizedDescription, privacy: .public)"
            )
            backupCorruptIndex()
            captures = []
            recoveryWarning = "Your capture list couldn't be read and was backed up. "
                + "No audio was deleted — your recordings are safe."
            return .corrupt
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(
                IndexFile(version: Self.indexVersion, captures: captures)
            )
            try data.write(
                to: indexURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            lastSaveError = nil
        } catch {
            // Record the failure but keep captures (and their audio) in memory.
            // The next mutation calls save() again, retrying the write; audio is
            // never discarded just because the index could not be persisted.
            lastSaveError = error.localizedDescription
            logger.error(
                "Failed to save capture index: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Copies the unreadable index to a unique, timestamped backup. Prior backups
    /// are never deleted, and the backup is only considered made once the copy
    /// verifiably exists on disk.
    private func backupCorruptIndex() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: indexURL.path) else { return }

        let formatter = ISO8601DateFormatter()
        // Colons are legal in POSIX paths but confuse the Finder/Carbon layer.
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var candidate = baseDir.appendingPathComponent(
            "\(Self.corruptBackupPrefix)-\(stamp).json"
        )
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = baseDir.appendingPathComponent(
                "\(Self.corruptBackupPrefix)-\(stamp)-\(suffix).json"
            )
            suffix += 1
        }

        do {
            try fileManager.copyItem(at: indexURL, to: candidate)
        } catch {
            logger.error(
                "Failed to back up corrupt index: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            logger.error(
                "Corrupt-index backup did not materialize: \(candidate.lastPathComponent, privacy: .public)"
            )
            return
        }
        logger.info(
            "Backed up corrupt index to \(candidate.lastPathComponent, privacy: .public)"
        )
    }

    /// True when any corrupt-index backup survives on disk (timestamped or the
    /// legacy fixed name). While one exists, the forward index may not reference
    /// every audio file, so orphan deletion must stay disabled.
    private func hasCorruptBackup() -> Bool {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return files.contains {
            $0.lastPathComponent.hasPrefix(Self.corruptBackupPrefix)
        }
    }

    /// Imports every audio file not already referenced by the index as a recovered
    /// `.pending` capture. Runs only when the index is missing, so a transient
    /// index-write failure recovers audio instead of destroying it.
    private func quarantineUnreferencedAudio() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDir,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return
        }

        let referenced = Set(captures.compactMap(\.audioFileName))
        var recovered = 0
        for file in files
        where file.pathExtension == "m4a"
            && !referenced.contains(file.lastPathComponent) {
            let stem = file.deletingPathExtension().lastPathComponent
            let id = UUID(uuidString: stem) ?? UUID()
            let createdAt = (try? file.resourceValues(
                forKeys: [.creationDateKey]
            ).creationDate) ?? Date()
            captures.append(
                Capture(
                    id: id,
                    createdAt: createdAt,
                    mode: .dictation,
                    source: .importedAudio,
                    audioFileName: file.lastPathComponent,
                    status: .pending
                )
            )
            recovered += 1
            logger.info(
                "Recovered unreferenced audio \(file.lastPathComponent, privacy: .public)"
            )
        }

        guard recovered > 0 else { return }
        captures.sort { $0.createdAt > $1.createdAt }
        recoveryWarning = "Your capture list was missing, so "
            + "\(recovered) recording\(recovered == 1 ? " was" : "s were") "
            + "recovered and will be re-transcribed. No audio was deleted."
        save()
    }

    private func reconcileOrphanedAudio() {
        let fileManager = FileManager.default
        guard !hasCorruptBackup() else { return }
        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let referenced = Set(captures.compactMap(\.audioFileName))
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
            logger.info(
                "Removed orphaned audio file \(file.lastPathComponent, privacy: .public)"
            )
        }
    }
}
