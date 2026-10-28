import Foundation

/// A latency stage, as the Stats screen shows it.
struct LatencyStage: Identifiable, Equatable, Sendable {
    var name: String
    var p50Ms: Int
    var p95Ms: Int
    /// What this stage is, in one line, for the row's help text.
    var detail: String
    /// False for stages the user does not wait through — arming happens before speech.
    /// Shown, because it is felt, but excluded from the perceived total.
    var isOnPerceivedPath: Bool

    var id: String { name }
}

/// Everything the Performance & health section renders.
///
/// A value type computed from the two logs, so the screen never reads a file and the
/// arithmetic can be tested without either.
struct HealthSummary: Equatable, Sendable {

    // Resource use
    /// Idle footprint at launch, median across sessions. Spec §15 budgets < 60 MB.
    var idleFootprintBytes: UInt64?
    /// The largest footprint seen at any sampled moment.
    var peakFootprintBytes: UInt64?
    /// Median CPU seconds consumed per dictation — start sample to end sample.
    var cpuSecondsPerDictation: Double?
    /// Median cold launch, ms. Spec §15 budgets < 400 ms.
    var launchMs: Int?

    // Stability
    var sessionCount: Int
    var cleanExitCount: Int
    var unexpectedExitCount: Int
    /// Unexpected endings that macOS wrote a crash report for, newest first.
    var crashes: [CrashSummary]

    // Latency
    var stages: [LatencyStage]
    /// Key release to text on screen, p50 / p95, over records carrying a stage breakdown.
    var perceivedP50Ms: Int?
    var perceivedP95Ms: Int?
    /// Same, split by mode — the budgets differ (§15: Verbatim 800 ms, Clean 1,300 ms).
    var verbatimP50Ms: Int?
    var cleanP50Ms: Int?
    /// How many records the latency figures rest on. A p50 over three samples is an
    /// anecdote; §15 says twenty, and the screen says so when it has fewer.
    var latencySampleCount: Int

    static let empty = HealthSummary(
        idleFootprintBytes: nil, peakFootprintBytes: nil, cpuSecondsPerDictation: nil,
        launchMs: nil, sessionCount: 0, cleanExitCount: 0, unexpectedExitCount: 0,
        crashes: [], stages: [], perceivedP50Ms: nil, perceivedP95Ms: nil,
        verbatimP50Ms: nil, cleanP50Ms: nil, latencySampleCount: 0)

    /// Spec §15's budgets, in one place so the screen and the tests cannot disagree
    /// about what "over budget" means.
    enum Budget {
        static let idleFootprintBytes: UInt64 = 60 * 1_000_000
        static let launchMs = 400
        static let armingMs = 250
        static let verbatimPerceivedMs = 800
        static let cleanPerceivedMs = 1_300
        /// §15: "A p50 requires samples… at least 20".
        static let minimumLatencySamples = 20
    }
}

/// Builds a `HealthSummary` from the raw logs. Pure arithmetic, no I/O.
enum HealthAggregator {

    static func summarize(sessions: [SessionRecord],
                          records: [DictationRecord]) -> HealthSummary {
        var summary = HealthSummary.empty

        // MARK: Resources
        let idle = sessions
            .compactMap { $0.samples.first { $0.moment == .launched }?.footprintBytes }
            .filter { $0 > 0 }
        summary.idleFootprintBytes = median(idle)

        let peaks = sessions.flatMap { $0.samples.map(\.footprintBytes) }.filter { $0 > 0 }
        summary.peakFootprintBytes = peaks.max()

        // CPU per dictation: attribute each process-wide counter increment across the
        // captures active during that interval. This keeps overlapping captures from
        // claiming the same CPU work more than once — no timer, per §15.
        var cpuDeltas: [Double] = []
        for session in sessions {
            var pendingStart: Double?
            var activeCaptures: Set<UUID> = []
            var cpuByCapture: [UUID: Double] = [:]
            var previousCPU: Double?
            for sample in session.samples {
                // The counter belongs to the process, not a capture. Attribute each
                // increment once across the captures active during that interval so
                // overlapping dictations cannot double-count the same CPU work.
                if let previousCPU,
                   sample.cpuSeconds >= previousCPU,
                   !activeCaptures.isEmpty {
                    let share = (sample.cpuSeconds - previousCPU)
                        / Double(activeCaptures.count)
                    for id in activeCaptures {
                        cpuByCapture[id, default: 0] += share
                    }
                }
                previousCPU = sample.cpuSeconds

                switch sample.moment {
                case .dictationStart:
                    if let id = sample.captureID {
                        activeCaptures.insert(id)
                        cpuByCapture[id] = 0
                    } else {
                        pendingStart = sample.cpuSeconds
                    }
                case .dictationEnd:
                    if let id = sample.captureID,
                       activeCaptures.remove(id) != nil,
                       let attributed = cpuByCapture.removeValue(forKey: id) {
                        cpuDeltas.append(attributed)
                    } else if sample.captureID == nil,
                              let start = pendingStart,
                              sample.cpuSeconds >= start {
                        cpuDeltas.append(sample.cpuSeconds - start)
                        pendingStart = nil
                    }
                default: break
                }
            }
        }
        summary.cpuSecondsPerDictation = median(cpuDeltas)

        summary.launchMs = median(sessions.map(\.launchMs).filter { $0 > 0 })

        // MARK: Stability
        // The run in progress is excluded: it has not ended, so counting it as anything
        // would be a guess, and counting it as clean would flatter the number.
        let finished = sessions.filter { $0.ending != .running }
        summary.sessionCount = finished.count
        summary.cleanExitCount = finished.count { $0.ending == .clean }
        summary.unexpectedExitCount = finished.count { $0.ending == .unexpected }
        summary.crashes = finished
            .compactMap(\.crashSummary)
            .sorted { $0.at > $1.at }

        // MARK: Latency
        // Only records carrying the stage breakdown. Older records are perfectly good
        // for volume and words, but they cannot be decomposed, and letting them count as
        // zero would drag every percentile toward a number nothing ever measured.
        let timed = records
            .filter { $0.outcome == .inserted }
            .map(\.timings)
            .filter { $0.hasStageBreakdown }
        summary.latencySampleCount = timed.count

        summary.stages = [
            LatencyStage(name: "Arming",
                         p50Ms: percentile(timed.map(\.armingMs), 0.5) ?? 0,
                         p95Ms: percentile(timed.map(\.armingMs), 0.95) ?? 0,
                         detail: "Key down until the microphone is live. Before you speak, "
                             + "so it is not part of the wait — but audio in this window is lost.",
                         isOnPerceivedPath: false),
            LatencyStage(name: "Finalizing",
                         p50Ms: percentile(timed.map(\.finalizeMs), 0.5) ?? 0,
                         p95Ms: percentile(timed.map(\.finalizeMs), 0.95) ?? 0,
                         detail: "Stopping the engine and closing the audio files, after you "
                             + "stop talking and before anything can be sent.",
                         isOnPerceivedPath: true),
            LatencyStage(name: "Transcription",
                         p50Ms: percentile(timed.map(\.whisperMs), 0.5) ?? 0,
                         p95Ms: percentile(timed.map(\.whisperMs), 0.95) ?? 0,
                         detail: "Post-release transcription work. For Groq this includes the "
                             + "upload; for local live models it is the final stream or batch wait.",
                         isOnPerceivedPath: true),
            LatencyStage(name: "Mode (Clean)",
                         p50Ms: percentile(timed.map(\.llmMs), 0.5) ?? 0,
                         p95Ms: percentile(timed.map(\.llmMs), 0.95) ?? 0,
                         detail: "The second round trip that cleans the transcript up. "
                             + "Zero in Verbatim, and it blocks the text appearing.",
                         isOnPerceivedPath: true),
            LatencyStage(name: "Insertion",
                         p50Ms: percentile(timed.map(\.insertMs), 0.5) ?? 0,
                         p95Ms: percentile(timed.map(\.insertMs), 0.95) ?? 0,
                         detail: "Getting the text to your cursor.",
                         isOnPerceivedPath: true)
        ]

        let perceived = timed.compactMap(\.perceivedMs)
        summary.perceivedP50Ms = percentile(perceived, 0.5)
        summary.perceivedP95Ms = percentile(perceived, 0.95)

        let byMode = records.filter { $0.outcome == .inserted && $0.timings.hasStageBreakdown }
        summary.verbatimP50Ms = percentile(
            byMode.filter { $0.modeID == "verbatim" }.compactMap { $0.timings.perceivedMs }, 0.5)
        summary.cleanP50Ms = percentile(
            byMode.filter { $0.modeID == "clean" }.compactMap { $0.timings.perceivedMs }, 0.5)

        return summary
    }

    // MARK: - Arithmetic

    /// Nearest-rank percentile. Returns nil for an empty set rather than 0 — "no data"
    /// and "measured zero" are different claims and the screen renders them differently.
    static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }

    static func median(_ values: [Int]) -> Int? { percentile(values, 0.5) }

    static func median(_ values: [UInt64]) -> UInt64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }
}
