import Darwin
import Foundation
import os

// MARK: - Samples

/// One resource reading, taken at a named moment.
///
/// There is no timer behind this and there must never be. Spec §15 sets idle CPU at
/// "≈ 0% — **no polling timers anywhere in the app**", so a sampler that woke up every
/// few seconds to measure resource use would itself become the resource use it reports.
/// Readings are taken at moments the app is already awake for.
struct ResourceSample: Codable, Equatable, Sendable {
    enum Moment: String, Codable, Sendable {
        /// Just after the composition root finishes building — the closest honest
        /// reading to spec §15's "idle resident memory" budget.
        case launched
        /// A dictation is about to arm the microphone.
        case dictationStart
        /// A dictation has finished and its text has landed.
        case dictationEnd
        /// The main window was opened. Windows are lazily built and released on close,
        /// so this is where the app is at its heaviest.
        case windowOpened
    }

    var at: Date
    var moment: Moment
    /// Resident footprint in bytes — what Activity Monitor calls Memory.
    var footprintBytes: UInt64
    /// Total CPU seconds this process has burned since launch, user + system. A
    /// difference between two samples gives CPU used over that span without any polling.
    var cpuSeconds: Double
    /// Correlates overlapping dictations. Nil on legacy samples and on moments
    /// such as launch/window-open that do not belong to a capture.
    var captureID: UUID? = nil
}

/// How one run of the app ended.
enum SessionEnding: String, Codable, Sendable {
    /// Still running, or the process died without getting to write anything.
    case running
    /// `applicationWillTerminate` completed.
    case clean
    /// A previous run left its marker behind: it was killed or it crashed.
    case unexpected
}

/// One run of the app, from launch to however it ended.
struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var ending: SessionEnding
    var appVersion: String
    var build: String
    /// Cold launch to menu-bar ready, in ms. Spec §15 budgets < 400 ms.
    var launchMs: Int
    /// Set only when `ending == .unexpected` and macOS wrote a matching crash report.
    /// Redacted; see `CrashReportReader`.
    var crashSummary: CrashSummary?
    var samples: [ResourceSample]

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil,
         ending: SessionEnding = .running, appVersion: String, build: String,
         launchMs: Int = 0, crashSummary: CrashSummary? = nil,
         samples: [ResourceSample] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.ending = ending
        self.appVersion = appVersion
        self.build = build
        self.launchMs = launchMs
        self.crashSummary = crashSummary
        self.samples = samples
    }
}

/// What a crash was, in the few fields worth showing — never the whole report.
///
/// Spec §16 is explicit that the Groq key is "never logged, never in a diagnostic report,
/// never in a crash log". A crash report is a memory dump in prose: it can contain stack
/// frames, register values and string fragments from the process, and this app holds an
/// API key in memory. So the raw `.ips` is never copied, never read into the record, and
/// never shown. Only these four short fields are extracted, and each is scrubbed.
struct CrashSummary: Codable, Equatable, Sendable {
    /// e.g. `EXC_BAD_ACCESS (SIGSEGV)`
    var exceptionType: String
    /// macOS's own one-line reason, when it wrote one.
    var terminationReason: String
    /// The faulting frame's symbol, if it belongs to Captur. Frames from system
    /// frameworks are reported as the framework name alone.
    var faultingSymbol: String
    var at: Date
}

// MARK: - Reading resources

/// Reads this process's own footprint and CPU. No timers, no subprocesses.
enum ProcessResources {

    /// Resident footprint, the number Activity Monitor shows under Memory.
    ///
    /// `phys_footprint` rather than `resident_size`: resident size counts pages shared
    /// with other processes and reads far higher than what the app is actually costing,
    /// which would make the §15 60 MB budget look blown when it is not.
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// Total CPU seconds burned since launch, user + system, across every thread.
    ///
    /// A cumulative counter, deliberately. Sampling an instantaneous percentage would
    /// need two readings a known interval apart — a timer — and §15 forbids that. Two
    /// cumulative readings taken at moments the app is awake for anyway give the same
    /// answer with nothing running in between.
    ///
    /// **Two flavours, added together, and both are required.** `TASK_BASIC_INFO` counts
    /// only threads that have already exited; `TASK_THREAD_TIMES_INFO` counts only the
    /// live ones. Reading either alone is the plausible-looking mistake: for a long-lived
    /// GUI app whose threads never exit, `TASK_BASIC_INFO` on its own returns a flat
    /// **zero**, which would have shipped a CPU stat that could never report anything.
    /// Caught by `testResourceReadingsAreNonZero`, which exists for exactly this.
    static func cpuSeconds() -> Double {
        var total: Double = 0

        var basic = task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        if basicResult == KERN_SUCCESS {
            total += seconds(basic.user_time) + seconds(basic.system_time)
        }

        var threads = task_thread_times_info_data_t()
        var threadCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let threadResult = withUnsafeMutablePointer(to: &threads) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &threadCount)
            }
        }
        if threadResult == KERN_SUCCESS {
            total += seconds(threads.user_time) + seconds(threads.system_time)
        }

        return total
    }

    private static func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }

    static func sample(_ moment: ResourceSample.Moment,
                       at date: Date,
                       captureID: UUID? = nil) -> ResourceSample {
        ResourceSample(at: date,
                       moment: moment,
                       footprintBytes: footprintBytes(),
                       cpuSeconds: cpuSeconds(),
                       captureID: captureID)
    }
}

// MARK: - Reading crash reports

/// Extracts the few safe fields from macOS's own crash reports.
///
/// The app does not install a signal handler. Catching your own crash means running code
/// in a process that has already lost the argument, and the answer is written for us
/// anyway: macOS drops a JSON `.ips` into `~/Library/Logs/DiagnosticReports`. Reading
/// what the system already recorded is both more reliable and less dangerous than trying
/// to record it ourselves mid-fault.
enum CrashReportReader {

    static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// The most recent Captur crash report at or after `after`, summarized and scrubbed.
    static func mostRecentCrash(after: Date,
                                in directory: URL = defaultDirectory,
                                now: Date = Date()) -> CrashSummary? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("Captur") }
            .filter { $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return (url, date)
            }
            // At or after the session started. A report from an earlier run is somebody
            // else's crash and must not be attributed to this session.
            .filter { $0.1 >= after && $0.1 <= now }
            .sorted { $0.1 > $1.1 }

        guard let (url, date) = candidates.first else { return nil }
        return summarize(contentsOf: url, at: date)
    }

    /// `.ips` files are two JSON objects concatenated: a one-line header, then the body.
    static func summarize(contentsOf url: URL, at date: Date) -> CrashSummary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return summarize(text, at: date)
    }

    static func summarize(_ text: String, at date: Date) -> CrashSummary? {
        // Skip the header line and parse the body.
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let bodyText = String(text[text.index(after: newline)...])
        guard let data = bodyText.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let exception = body["exception"] as? [String: Any]
        let type = [exception?["type"] as? String, exception?["signal"] as? String]
            .compactMap { $0 }
            .joined(separator: " ")

        let reason = (body["termination"] as? [String: Any])?["indicator"] as? String
            ?? exception?["message"] as? String
            ?? ""

        return CrashSummary(exceptionType: redact(type.isEmpty ? "unknown" : type),
                            terminationReason: redact(reason),
                            faultingSymbol: redact(faultingSymbol(in: body)),
                            at: date)
    }

    /// The top frame of whichever thread triggered the crash.
    private static func faultingSymbol(in body: [String: Any]) -> String {
        guard let threads = body["threads"] as? [[String: Any]] else { return "" }
        let faulting = threads.first { ($0["triggered"] as? Bool) == true } ?? threads.first
        guard let frames = faulting?["frames"] as? [[String: Any]],
              let top = frames.first
        else { return "" }

        if let symbol = top["symbol"] as? String, !symbol.isEmpty { return symbol }
        // No symbol: name the image instead. An offset alone tells the user nothing and
        // is the sort of value that varies per build.
        if let index = top["imageIndex"] as? Int,
           let images = body["usedImages"] as? [[String: Any]],
           index < images.count,
           let name = images[index]["name"] as? String {
            return name
        }
        return ""
    }

    /// Belt and braces on top of only ever reading four short fields.
    ///
    /// Nothing here is expected to contain a key — an exception type is `EXC_BAD_ACCESS`,
    /// not a secret. But this is the one place in the app where text from a memory dump
    /// is copied into a file the user can export, and §16 promises the key is never in a
    /// crash log. A cheap scrub is worth more than the assumption that it cannot happen.
    static func redact(_ text: String) -> String {
        var scrubbed = text
        // Groq keys are `gsk_` followed by a long opaque run.
        scrubbed = scrubbed.replacingOccurrences(
            of: "gsk_[A-Za-z0-9]{8,}",
            with: "gsk_***",
            options: .regularExpression)
        // Anything else long, opaque and token-shaped.
        scrubbed = scrubbed.replacingOccurrences(
            of: "\\b[A-Za-z0-9_-]{32,}\\b",
            with: "***",
            options: .regularExpression)
        // Home directory paths carry the user's account name.
        scrubbed = scrubbed.replacingOccurrences(
            of: "/Users/[^/\\s]+",
            with: "~",
            options: .regularExpression)
        return String(scrubbed.prefix(200))
    }
}

// MARK: - The log

/// Append-only history of app runs: how each ended, what it cost, and why it died.
///
/// Deliberately a separate file from `records.jsonl`. A dictation record is the user's
/// content and is precious; a session record is telemetry about the app and is
/// disposable. Mixing them would mean a health-data schema change risking the user's
/// history, and this project has already been bitten once by a decoder that drops what it
/// cannot read.
///
/// **Local only.** Spec §16: "Transcripts and records stay local. Nothing is sent anywhere
/// except Groq." Nothing in this file opens a socket, and nothing should be added that
/// does — if health data is ever wanted elsewhere, it goes out through an explicit,
/// user-initiated export, not a background upload.
actor SessionHealthLog {

    /// How many runs to keep. Enough to see a pattern across a few weeks of use; small
    /// enough that the file stays trivial to read in one go.
    static let maximumSessions = 200

    /// `nonisolated` so the synchronous termination path can reach them without an
    /// `await` that may never get to run. Both are immutable `URL`s, which is Sendable
    /// and therefore safe to read from any isolation.
    nonisolated let fileURL: URL
    nonisolated let markerURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.awah.captur", category: "health")

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("sessions.json")
        // Presence of this file means "a run is in progress". Its absence at launch means
        // the previous run got to `applicationWillTerminate`. It is the whole crash
        // detector: a process that is killed or faults never gets to delete it.
        markerURL = directory.appendingPathComponent(".session-running")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Reads

    func sessions() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([SessionRecord].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: Writes

    /// Opens a new session, and — first — settles what happened to the last one.
    ///
    /// Returns the session that was just opened.
    @discardableResult
    func beginSession(appVersion: String,
                      build: String,
                      launchMs: Int,
                      now: Date = Date()) -> SessionRecord {
        var all = sessions()

        // Close out anything still marked `.running`. The marker tells us whether the
        // previous run ended cleanly; a stale marker means it did not.
        let markerExists = FileManager.default.fileExists(atPath: markerURL.path)
        for index in all.indices where all[index].ending == .running {
            all[index].ending = markerExists ? .unexpected : .clean
            all[index].endedAt = all[index].endedAt ?? now
            if markerExists {
                all[index].crashSummary = CrashReportReader.mostRecentCrash(
                    after: all[index].startedAt, now: now)
            }
        }

        let session = SessionRecord(startedAt: now,
                                    appVersion: appVersion,
                                    build: build,
                                    launchMs: launchMs,
                                    samples: [ProcessResources.sample(.launched, at: now)])
        all.append(session)
        persist(all)
        try? Data().write(to: markerURL)
        return session
    }

    /// Records a reading against the open session. Cheap enough to call at any moment the
    /// app is already doing something; never call it on a schedule.
    func sample(_ moment: ResourceSample.Moment,
                captureID: UUID? = nil,
                now: Date = Date()) {
        var all = sessions()
        guard let index = all.lastIndex(where: { $0.ending == .running }) else { return }
        all[index].samples.append(ProcessResources.sample(
            moment, at: now, captureID: captureID))
        persist(all)
    }

    /// Clean shutdown: closes the session and removes the marker, which is what tells the
    /// next launch this run did not crash.
    func endSession(now: Date = Date()) {
        var all = sessions()
        if let index = all.lastIndex(where: { $0.ending == .running }) {
            all[index].ending = .clean
            all[index].endedAt = now
        }
        persist(all)
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// The same thing, from `applicationWillTerminate`, without an `await`.
    ///
    /// `nonisolated` and fully synchronous because the process may not survive an actor
    /// hop. Marker removal is the load-bearing step and is done FIRST and unconditionally:
    /// if the app is killed halfway through this function, the worst outcome is a session
    /// left marked `.running` and later closed as clean — whereas failing to remove the
    /// marker would report a perfectly clean quit to the user as a crash. A health
    /// feature that invents crashes is worse than one that misses a shutdown.
    ///
    /// It is safe to touch the file from outside the actor because this runs exactly once,
    /// at termination, when nothing else will write again.
    nonisolated func endSessionSynchronously(now: Date = Date()) {
        try? FileManager.default.removeItem(at: markerURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: fileURL),
              var all = try? decoder.decode([SessionRecord].self, from: data),
              let index = all.lastIndex(where: { $0.ending == .running })
        else { return }

        all[index].ending = .clean
        all[index].endedAt = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(all) else { return }
        try? encoded.write(to: fileURL, options: [.atomic])
    }

    private func persist(_ sessions: [SessionRecord]) {
        let trimmed = sessions.suffix(Self.maximumSessions)
        guard let data = try? encoder.encode(Array(trimmed)) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            log.error("session health not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
