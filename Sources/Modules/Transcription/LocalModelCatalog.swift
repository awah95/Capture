import Foundation

/// The local model catalog supported by this Captur build.
/// Keeping it finite makes download size, licensing, and runtime behavior honest.
struct LocalModelDescriptor: Identifiable, Equatable, Sendable {
    let provider: TranscriptionProvider
    let name: String
    let version: String
    let size: String
    let detail: String
    let isRecommended: Bool
    /// Stable identifiers written to history. Display names and dependency
    /// versions may change without merging two different model artifacts in Stats.
    let batchModelID: String
    let streamingModelID: String?

    var id: TranscriptionProvider { provider }

    static let all: [LocalModelDescriptor] = [
        LocalModelDescriptor(
            provider: .localPhonon,
            name: "Phonon-2 Core ML",
            version: "Phonon Core ML 1.1.2",
            size: "≈345 MB + compiled cache",
            detail: "English batch transcription on the Neural Engine. No live preview or acoustic vocabulary boosting. First preparation can take several minutes. Fermion Research · CC BY 4.0 weights.",
            isRecommended: false,
            batchModelID: "phonon-2-coreml-48af304c8db8",
            streamingModelID: nil),
        LocalModelDescriptor(
            provider: .localUnified,
            name: "Parakeet Unified 0.6B",
            version: "FluidAudio 0.17.4",
            size: "≈600 MB",
            detail: "Best accuracy and punctuation for finished English dictation.",
            isRecommended: true,
            batchModelID: "parakeet-unified-en-0.6b-int8",
            streamingModelID: "parakeet-unified-en-0.6b-streaming-int8"),
        LocalModelDescriptor(
            provider: .localMoonshine,
            name: "Moonshine Medium Streaming",
            version: "Moonshine 0.1.5",
            size: "≈257 MB",
            detail: "Streams while you speak for the fastest end-of-dictation response.",
            isRecommended: false,
            batchModelID: "moonshine-medium-streaming-en",
            streamingModelID: "moonshine-medium-streaming-en"),
        LocalModelDescriptor(
            provider: .localUltra,
            name: "Parakeet Ultra",
            version: "FluidAudio 0.17.4",
            size: "≈630 MB",
            detail: "Multilingual batch transcription with punctuation. Transcribes completed audio; no live preview.",
            isRecommended: false,
            batchModelID: "parakeet-ultra-coreml-int8",
            streamingModelID: nil),
    ]
}

extension TranscriptionProvider {
    var usageDisplayName: String {
        switch self {
        case .groq: return "Groq"
        case .localUnified: return "Parakeet"
        case .localMoonshine: return "Moonshine"
        case .localUltra: return "Parakeet Ultra"
        case .localPhonon: return "Phonon-2"
        }
    }

    var batchUsageModelID: String {
        LocalModelDescriptor.all.first { $0.provider == self }?.batchModelID
            ?? GroqClient.defaultModel
    }

    var streamingUsageModelID: String {
        LocalModelDescriptor.all.first { $0.provider == self }?.streamingModelID
            ?? batchUsageModelID
    }
}

enum LiveTranscriptionCapability: Equatable, Sendable {
    case unsupported(reason: String)
    case included(detail: String)
    case additionalDownload(size: String, detail: String)
}

extension TranscriptionProvider {
    var liveTranscriptionCapability: LiveTranscriptionCapability {
        switch self {
        case .groq:
            .unsupported(reason: "Groq's Whisper endpoint transcribes completed audio, not a live stream.")
        case .localUltra:
            .unsupported(reason: "Parakeet Ultra transcribes completed audio; live transcription is unavailable.")
        case .localPhonon:
            .unsupported(reason: "Phonon-2 Core ML is English batch transcription; live transcription is unavailable.")
        case .localMoonshine:
            .included(detail: "Included with Moonshine. Partial text is revised while you speak.")
        case .localUnified:
            .additionalDownload(
                size: "≈565 MB",
                detail: "Uses Parakeet Unified's 640 ms streaming encoder. The batch model stays available.")
        }
    }
}

struct LocalModelDownloadProgress: Equatable, Sendable {
    let fraction: Double
    let etaSeconds: TimeInterval?
    let detail: String

    static func fraction(_ fraction: Double, detail: String) -> Self {
        Self(fraction: min(max(fraction, 0), 1), etaSeconds: nil, detail: detail)
    }
}

struct LocalModelAvailability: Equatable, Sendable {
    let isDownloaded: Bool
    let updateAvailable: Bool
    let installedBytes: Int?
    let installedVersion: String?

    init(isDownloaded: Bool, updateAvailable: Bool, installedBytes: Int? = nil, installedVersion: String? = nil) {
        self.isDownloaded = isDownloaded
        self.updateAvailable = updateAvailable
        self.installedBytes = installedBytes
        self.installedVersion = installedVersion
    }
}

enum LocalModelStorage {
    static func byteCount(at directory: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: directory.path),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += size
        }
        return total
    }
}

/// A provider-specific 30-day view shown beside an installed local model. Unique
/// audio answers "how long did I dictate?" while processed audio answers "how much
/// work did this model do?" and therefore includes live + batch rechecks and retries.
struct LocalModelUsageSummary: Equatable, Sendable {
    var dictationCount = 0
    var successfulDictationCount = 0
    var processedPassCount = 0
    var retryPassCount = 0
    var unsuccessfulPassCount = 0
    var outputWordCount = 0
    var uniqueAudioSeconds: TimeInterval = 0
    var processedAudioSeconds: TimeInterval = 0
    var latencyP50Ms: Int?
    var latencyP95Ms: Int?

    var hasData: Bool { processedPassCount > 0 }
}

enum LocalModelUsageAggregator {
    static func summarize(
        _ records: [DictationRecord],
        provider: TranscriptionProvider
    ) -> LocalModelUsageSummary {
        guard provider.isLocal else { return LocalModelUsageSummary() }
        var summary = LocalModelUsageSummary()
        var latencies: [Int] = []

        for record in records {
            let entries = (record.usageEntries ?? []).filter {
                $0.stage == .transcription && $0.providerID == provider.rawValue
            }
            guard !entries.isEmpty else { continue }
            summary.dictationCount += 1
            if record.outcome == .inserted { summary.successfulDictationCount += 1 }
            summary.uniqueAudioSeconds += record.speakingDuration
            summary.processedPassCount += entries.count
            summary.processedAudioSeconds += entries.compactMap(\.audioSeconds).reduce(0, +)
            summary.outputWordCount += entries.compactMap(\.outputWordCount).reduce(0, +)
            summary.retryPassCount += entries.count { $0.isRetry == true }
            summary.unsuccessfulPassCount += entries.count {
                $0.outcome == .failed || $0.outcome == .cancelled
            }
            latencies.append(contentsOf: entries.compactMap(\.latencyMs))
        }

        summary.latencyP50Ms = percentile(latencies, 0.5)
        summary.latencyP95Ms = percentile(latencies, 0.95)
        return summary
    }

    private static func percentile(_ values: [Int], _ percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

enum LocalModelState: Equatable, Sendable {
    case checking
    case notDownloaded
    case downloading(LocalModelDownloadProgress)
    case ready(updateAvailable: Bool)
    case failed(String)
}

/// Turns monotonic progress callbacks into a useful ETA without inventing one
/// before enough data has arrived to estimate a rate.
final class LocalModelProgressEstimator: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var baselineFraction: Double?

    func snapshot(fraction rawFraction: Double, detail: String) -> LocalModelDownloadProgress {
        lock.withLock {
            let fraction = min(max(rawFraction, 0), 1)
            let elapsed = Date().timeIntervalSince(startedAt)
            let baseline = baselineFraction ?? fraction
            if baselineFraction == nil { baselineFraction = baseline }
            let observedProgress = fraction - baseline
            let eta: TimeInterval? = observedProgress >= 0.01 && elapsed >= 0.5
                ? max(0, elapsed * (1 - fraction) / observedProgress)
                : nil
            return LocalModelDownloadProgress(
                fraction: fraction, etaSeconds: eta, detail: detail)
        }
    }
}

/// Model replacement must not interrupt a capture or a download already in flight.
struct LocalModelBusyError: LocalizedError {
    var errorDescription: String? {
        "This model is in use. Finish dictation or the current download, then try again."
    }
}

/// A runtime version is the latest installation supported by this Captur build.
/// Reading a cache must never relabel an older installation as upgraded.
enum LocalModelInstallation {
    static func availability(root: URL, markerName: String = "captur-model-version.txt",
                             latestVersion: String, artifactsPresent: Bool) -> LocalModelAvailability {
        guard artifactsPresent else {
            return LocalModelAvailability(isDownloaded: false, updateAvailable: false)
        }
        let version = try? String(contentsOf: root.appendingPathComponent(markerName), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalModelAvailability(isDownloaded: true,
            updateAvailable: version != latestVersion,
            installedBytes: LocalModelStorage.byteCount(at: root), installedVersion: version)
    }

    static func recordPrepared(root: URL, markerName: String = "captur-model-version.txt",
                               version: String, existingArtifacts: Bool = false) throws {
        // Unversioned legacy files remain unknown until the user replaces them.
        guard !existingArtifacts else { return }
        let marker = root.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try Data(version.utf8).write(to: marker, options: .atomic)
    }
}
