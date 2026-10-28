import Foundation
import os

// MARK: - Record shape

/// Per-stage latency of one dictation, in milliseconds.
///
/// `armingMs` and `finalizeMs` were added after the fact, and every field is decoded with
/// `decodeIfPresent`. That is not politeness: `DictationRecordLog.decodeRecords` drops any
/// line that fails to decode, so a record written before these fields existed would
/// silently disappear from History and from every statistic computed over it. The user's
/// dictation history is not something to lose to a schema change.
struct Timings: Codable, Equatable, Sendable {
    /// How long the user actually spoke. Not latency — subtracted out of every
    /// perceived-latency figure.
    var captureMs: Int
    /// Key-down until the microphone is live. Happens BEFORE speech, so it is not part of
    /// the post-speech wait, but it is felt: audio in this window is lost.
    var armingMs: Int
    /// Stopping the engine and closing the audio files, after the user stops talking and
    /// before the first byte can be uploaded. Squarely on the perceived path.
    var finalizeMs: Int
    /// Float32 → Int16 → FLAC encode cost attributable to the request.
    var convertMs: Int
    /// Bytes on the wire.
    var uploadMs: Int
    /// The transcription round trip, upload included.
    var whisperMs: Int
    /// The Clean-mode LLM pass. Zero in Verbatim.
    var llmMs: Int
    /// Getting the text to the cursor.
    var insertMs: Int
    /// Record open to record close — includes arming, speech, and the post-insert
    /// clipboard settle. Deliberately NOT the perceived figure; see `perceivedMs`.
    var totalMs: Int

    init(captureMs: Int = 0, armingMs: Int = 0, finalizeMs: Int = 0, convertMs: Int = 0,
         uploadMs: Int = 0, whisperMs: Int = 0, llmMs: Int = 0, insertMs: Int = 0,
         totalMs: Int = 0) {
        self.captureMs = captureMs
        self.armingMs = armingMs
        self.finalizeMs = finalizeMs
        self.convertMs = convertMs
        self.uploadMs = uploadMs
        self.whisperMs = whisperMs
        self.llmMs = llmMs
        self.insertMs = insertMs
        self.totalMs = totalMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureMs = try container.decodeIfPresent(Int.self, forKey: .captureMs) ?? 0
        armingMs = try container.decodeIfPresent(Int.self, forKey: .armingMs) ?? 0
        finalizeMs = try container.decodeIfPresent(Int.self, forKey: .finalizeMs) ?? 0
        convertMs = try container.decodeIfPresent(Int.self, forKey: .convertMs) ?? 0
        uploadMs = try container.decodeIfPresent(Int.self, forKey: .uploadMs) ?? 0
        whisperMs = try container.decodeIfPresent(Int.self, forKey: .whisperMs) ?? 0
        llmMs = try container.decodeIfPresent(Int.self, forKey: .llmMs) ?? 0
        insertMs = try container.decodeIfPresent(Int.self, forKey: .insertMs) ?? 0
        totalMs = try container.decodeIfPresent(Int.self, forKey: .totalMs) ?? 0
    }

    /// **The number that matches what the user experiences**: key release to text on
    /// screen.
    ///
    /// It is built up from the stages rather than measured as one span, because the two
    /// obvious spans are both wrong. `totalMs` starts before arming — time spent before
    /// the user has said anything — and ends after a 300 ms clipboard-settle sleep that
    /// happens *after* the text is already visible. `scripts/lv5.py` used
    /// `totalMs - captureMs` and therefore overstated perceived latency by roughly
    /// 700 ms, which made every historical LV5 reading pessimistic.
    ///
    /// Returns nil when a record predates stage instrumentation and cannot be decomposed —
    /// an unknown is reported as unknown rather than as a plausible-looking zero.
    var perceivedMs: Int? {
        let stages = finalizeMs + whisperMs + llmMs + insertMs
        guard stages > 0 else { return nil }
        return stages
    }

    /// True when this record carries the post-2026-07-27 stage breakdown. Older records
    /// are still counted for volume and words; they are excluded from latency percentiles
    /// so a partially-instrumented past cannot drag a present-day p50 around.
    var hasStageBreakdown: Bool {
        armingMs > 0 || finalizeMs > 0 || convertMs > 0 || uploadMs > 0
    }
}

/// How a dictation ended. `failed` carries the reason so a failure can be
/// explained in the UI without a second lookup.
enum DictationOutcome: Codable, Equatable, Sendable {
    case inserted
    case cancelled
    case failed(reason: String)
}

enum DictationUsageStage: String, Codable, Equatable, Hashable, Sendable {
    case transcription
    case refinement
}

/// The concrete transcription work a provider performed. This is deliberately
/// provider-neutral: Stats can compare local and cloud engines without decoding
/// model names or guessing from a zero-dollar charge.
enum DictationTranscriptionPath: String, Codable, Equatable, Hashable, Sendable {
    case batchSegment
    case liveStream
    case finalBatchRecheck
    case retryBatch
}

enum DictationUsageOutcome: String, Codable, Equatable, Hashable, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// One provider charge attached to a dictation. A list rather than flattened
/// totals preserves retries and provider fallbacks without losing attribution.
struct DictationUsageEntry: Codable, Equatable, Sendable {
    var stage: DictationUsageStage
    var providerID: String
    var requestedModelID: String
    var actualModelID: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var cachedTokens: Int?
    var costUSD: Decimal?
    var costKind: RefinementCostKind
    var generationID: String?
    /// Audio presented to this model pass. Unlike `speakingDuration`, this is
    /// intentionally additive: live + final recheck records the same clip twice.
    var audioSeconds: TimeInterval? = nil
    /// Set on the one transcription entry whose text became the record's raw text.
    /// Keeping it off the other passes prevents a live + batch run double-counting words.
    var outputWordCount: Int? = nil
    /// End-of-speech wait attributed to the selected transcription result.
    var latencyMs: Int? = nil
    var transcriptionPath: DictationTranscriptionPath? = nil
    /// Nil on legacy entries, false/true on newly measured transcription work.
    var isRetry: Bool? = nil
    var outcome: DictationUsageOutcome? = nil
}

/// One completed dictation. Written once, occasionally amended (audio purge),
/// rarely deleted.
struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    /// Amended once the recording is closed: the pipeline opens the record before the
    /// first byte of audio leaves the machine, and only then knows how long the user
    /// spoke for.
    var speakingDuration: TimeInterval
    var rawText: String
    var finalText: String
    var modeID: String
    var targetBundleID: String?
    var targetAppName: String?
    var wordCount: Int
    var rawWordCount: Int
    var segmentCount: Int
    var timings: Timings
    /// Mirrors `InsertionOutcome`; a plain string keeps the log decodable across
    /// refactors of that enum.
    var insertionOutcome: String
    var retryCount: Int
    var editDistanceRawToFinal: Double
    /// The CONTINUOUS SESSION audio file; nil once purged by the retention sweep.
    var audioFileName: String?
    var audioBytes: Int
    var estimatedCostUSD: Double
    /// Vocabulary supplied to the transcription path, not proof that the decoder
    /// applied a hint. Optional native rescoring can skip for model/budget reasons.
    var vocabularyTermsSent: Int
    var voiceProcessingActive: Bool
    var outcome: DictationOutcome
    /// Missing on legacy rows. New rows write an array, including an empty one
    /// when every stage was local, so zero and unknown remain distinguishable.
    var usageEntries: [DictationUsageEntry]? = nil
    /// Counts/status only; raw context is intentionally never serialized.
    var contextSummary: String? = nil

    var totalTrackedCostUSD: Double {
        guard let usageEntries else { return estimatedCostUSD }
        let total = usageEntries.compactMap(\.costUSD).reduce(Decimal.zero, +)
        return NSDecimalNumber(decimal: total).doubleValue
    }

    var unknownTrackedCostCount: Int {
        usageEntries?.filter { $0.costUSD == nil }.count ?? 0
    }

    /// Promoting a legacy record to itemized usage must retain the aggregate
    /// transcription estimate that predates `usageEntries`.
    mutating func appendUsageEntriesPreservingLegacyCost(_ newEntries: [DictationUsageEntry]) {
        guard !newEntries.isEmpty else { return }
        if usageEntries == nil {
            usageEntries = estimatedCostUSD > 0 ? [
                DictationUsageEntry(
                    stage: .transcription,
                    providerID: RefinementProviderID.groq.rawValue,
                    requestedModelID: "Legacy estimate",
                    actualModelID: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    reasoningTokens: nil,
                    cachedTokens: nil,
                    costUSD: Decimal(estimatedCostUSD),
                    costKind: .estimated,
                    generationID: nil)
            ] : []
        }
        usageEntries?.append(contentsOf: newEntries)
    }
}

// MARK: - Log

/// Append-only JSONL log of completed dictations — the sole data source for the
/// stats screen.
///
/// JSONL is deliberate over a database: a partial write damages one line rather
/// than the whole file, it needs no dependency, the user can read it with any
/// text editor, and it streams. The cost is that updates and deletes require a
/// rewrite, which is acceptable because they are rare and the file is small.
///
/// **Format.** One compact JSON object per line, newline-terminated, no pretty
/// printing. Dates are `.secondsSince1970` numbers: the round trip is exact for
/// day-boundary streak math, there is no timezone or locale ambiguity, and the
/// read path parses no date strings — ISO8601 parsing of thousands of lines is
/// the single most expensive thing this file could do.
///
/// **Corruption.** An undecodable line is skipped, never fatal. The whole file
/// is copied to `records.jsonl.corrupt-<timestamp>` before the surviving records
/// are returned; the original is left exactly as found. Nothing is ever erased —
/// the same discipline `CaptureStore` and `VocabularyStore` apply to a corrupt
/// index. Backups are timestamped and never deleted, and one is taken per
/// distinct corrupt file state rather than once per read.
actor DictationRecordLog {
    private let fileURL: URL
    private let directory: URL
    private let logger = Logger(subsystem: "com.awah.captur", category: "records")

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Size and modification date of the file at the time of the last corruption
    /// backup. Re-reading an unchanged corrupt file must not pile up copies of it.
    private var lastBackedUpSignature: FileSignature?

    private struct FileSignature: Equatable {
        var size: Int
        var modified: Date?
    }

    private static let corruptBackupPrefix = "corrupt-"

    init(fileURL: URL) {
        self.fileURL = fileURL
        directory = fileURL.deletingLastPathComponent()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        // No .prettyPrinted and no .sortedKeys: one line per record, and key
        // order stays whatever the synthesized encoder emits.
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    // MARK: - Reads

    /// Every record that decodes, in file order. A missing or empty file returns
    /// an empty array rather than throwing.
    func all() throws -> [DictationRecord] {
        guard let data = try readFile() else { return [] }
        return decodeRecords(from: data)
    }

    func record(id: UUID) throws -> DictationRecord? {
        try all().first { $0.id == id }
    }

    // MARK: - Writes

    /// Appends one line. Opens the file for appending and writes only the new
    /// bytes — the existing contents are never rewritten, so a crash here can at
    /// worst leave one torn trailing line.
    func append(_ record: DictationRecord) throws {
        var line = try encoder.encode(record)
        line.append(UInt8(ascii: "\n"))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: [.atomic])
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Applies `mutate` to the matching record and rewrites the file atomically.
    /// An unknown id, a missing file, and a mutation that changes nothing are all
    /// no-ops that leave the bytes on disk untouched.
    func update(id: UUID, mutate: (inout DictationRecord) -> Void) throws {
        guard let data = try readFile() else { return }
        var records = decodeRecords(from: data)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        let before = records[index]
        mutate(&records[index])
        guard records[index] != before else { return }

        try rewrite(records)
    }

    /// Removes the matching record and rewrites the file atomically. An unknown
    /// id or a missing file is a no-op.
    func delete(id: UUID) throws {
        guard let data = try readFile() else { return }
        var records = decodeRecords(from: data)
        guard records.contains(where: { $0.id == id }) else { return }

        records.removeAll { $0.id == id }
        try rewrite(records)
    }

    // MARK: - File plumbing

    /// Returns the file's bytes, or nil when there is no file. A missing file is
    /// the normal state before the first dictation, not an error.
    private func readFile() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    /// Decodes one record per newline-delimited line. Blank lines are skipped
    /// silently; a line that fails to decode triggers a one-time backup of the
    /// whole file and is then skipped, so every intact record still loads.
    private func decodeRecords(from data: Data) -> [DictationRecord] {
        guard !data.isEmpty else { return [] }

        let bytes = [UInt8](data)
        let newline = UInt8(ascii: "\n")

        var records: [DictationRecord] = []
        records.reserveCapacity(128)
        var corruptLines = 0

        var start = bytes.startIndex
        while start < bytes.endIndex {
            var end = start
            while end < bytes.endIndex, bytes[end] != newline { end += 1 }
            defer { start = end + 1 }

            guard start < end else { continue }
            let slice = bytes[start..<end]
            if isBlank(slice) { continue }

            if let record = try? decoder.decode(DictationRecord.self, from: Data(slice)) {
                records.append(record)
            } else {
                corruptLines += 1
            }
        }

        if corruptLines > 0 {
            logger.error("Skipped \(corruptLines, privacy: .public) undecodable record line(s)")
            backUpCorruptFile()
        }
        return records
    }

    private func isBlank(_ slice: ArraySlice<UInt8>) -> Bool {
        slice.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == 0x0D }
    }

    /// Serializes `records` and swaps the file in one step, so a crash mid-write
    /// cannot leave a truncated log: the temp file is written and flushed first,
    /// then replaces the original in a single filesystem operation.
    private func rewrite(_ records: [DictationRecord]) throws {
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporaryURL, options: [.atomic])

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    // MARK: - Corruption backup

    /// Copies the file to a unique, timestamped sibling. The original is left in
    /// place, prior backups are never touched, and an unchanged corrupt file is
    /// only copied once however many times it is read.
    private func backUpCorruptFile() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        // An unreadable signature means "can't prove it's the same file" — back
        // it up rather than risk skipping a salvage.
        let signature = currentSignature()
        if let signature, signature == lastBackedUpSignature { return }

        // Colons are legal in POSIX paths but confuse the Finder/Carbon layer.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = "\(fileURL.lastPathComponent).\(Self.corruptBackupPrefix)\(stamp)"
        var candidate = directory.appendingPathComponent(base)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }

        do {
            try fileManager.copyItem(at: fileURL, to: candidate)
        } catch {
            logger.error(
                "Failed to back up corrupt record log: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        lastBackedUpSignature = signature
        logger.info(
            "Backed up corrupt record log to \(candidate.lastPathComponent, privacy: .public)"
        )
    }

    private func currentSignature() -> FileSignature? {
        guard let values = try? fileURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = values.fileSize else {
            return nil
        }
        return FileSignature(size: size, modified: values.contentModificationDate)
    }
}
