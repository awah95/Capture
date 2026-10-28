import XCTest
@testable import Captur

/// Coverage for the local-only health telemetry: crash detection, resource sampling, the
/// redaction promise, and the arithmetic the Stats screen renders.
final class SessionHealthTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-health-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLog() -> SessionHealthLog { SessionHealthLog(directory: directory) }

    // MARK: - Crash detection

    /// The whole detector in one test: a run that never called `endSession` left its
    /// marker behind, and the next launch must read that as an unexpected ending.
    func testASessionThatNeverEndedIsRecordedAsUnexpected() async {
        let first = makeLog()
        await first.beginSession(appVersion: "1.0", build: "1", launchMs: 100)
        // No endSession — the process "died".

        let second = makeLog()
        await second.beginSession(appVersion: "1.0", build: "1", launchMs: 100)

        let sessions = await second.sessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].ending, .unexpected)
        XCTAssertEqual(sessions[1].ending, .running, "the new run is still open")
    }

    /// The other half, and the one that matters more: a clean quit must NOT be reported
    /// as a crash. A health feature that invents crashes is worse than one that misses.
    func testACleanShutdownIsRecordedAsClean() async {
        let first = makeLog()
        await first.beginSession(appVersion: "1.0", build: "1", launchMs: 100)
        await first.endSession()

        let second = makeLog()
        await second.beginSession(appVersion: "1.0", build: "1", launchMs: 100)

        let sessions = await second.sessions()
        XCTAssertEqual(sessions[0].ending, .clean)
        XCTAssertNil(sessions[0].crashSummary)
    }

    /// `applicationWillTerminate` cannot await, so the synchronous path has to do the same
    /// job. If it did not, every quit would be reported as a crash.
    func testTheSynchronousShutdownPathAlsoClearsTheMarker() async {
        let first = makeLog()
        await first.beginSession(appVersion: "1.0", build: "1", launchMs: 100)
        first.endSessionSynchronously()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.markerURL.path),
                       "the marker is what a crash is detected by; a clean quit clears it")

        let second = makeLog()
        await second.beginSession(appVersion: "1.0", build: "1", launchMs: 100)
        let sessions = await second.sessions()
        XCTAssertEqual(sessions[0].ending, .clean)
    }

    func testLaunchAndSamplesArePersisted() async {
        let log = makeLog()
        await log.beginSession(appVersion: "1.2", build: "34", launchMs: 321)
        await log.sample(.dictationStart)
        await log.sample(.dictationEnd)

        let session = await log.sessions().last
        XCTAssertEqual(session?.appVersion, "1.2")
        XCTAssertEqual(session?.launchMs, 321)
        XCTAssertEqual(session?.samples.map(\.moment), [.launched, .dictationStart, .dictationEnd])
    }

    /// Resource readings must be real. A sampler that silently returns zero would make
    /// every budget look met.
    func testResourceReadingsAreNonZero() {
        XCTAssertGreaterThan(ProcessResources.footprintBytes(), 0)
        XCTAssertGreaterThan(ProcessResources.cpuSeconds(), 0)
    }

    // MARK: - Redaction

    /// Spec §16: the key is "never logged, never in a diagnostic report, never in a crash
    /// log". This is the only place text from a memory dump is copied into a file.
    func testRedactionRemovesKeysPathsAndLongTokens() {
        let scrubbed = CrashReportReader.redact(
            "failed with gsk_abcdefghijklmnopqrstuvwxyz012345 at /Users/example/Library/x")
        XCTAssertFalse(scrubbed.contains("gsk_abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertFalse(scrubbed.contains("/Users/example"))
        XCTAssertTrue(scrubbed.contains("gsk_***"))
    }

    func testRedactionIsLengthCapped() {
        XCTAssertLessThanOrEqual(CrashReportReader.redact(String(repeating: "a", count: 5000)).count,
                                 200)
    }

    /// A real `.ips` is a header line followed by a JSON body. Parsing must survive that
    /// shape and pull exactly the four fields — no more.
    func testCrashSummaryIsExtractedFromAnIPSBody() throws {
        let ips = """
        {"app_name":"Captur","timestamp":"2026-07-27"}
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
         "termination":{"indicator":"Namespace SIGNAL, Code 11"},
         "threads":[{"triggered":true,"frames":[{"symbol":"Captur.AudioEngine.stop()"}]}],
         "usedImages":[{"name":"Captur"}]}
        """
        let summary = try XCTUnwrap(CrashReportReader.summarize(ips, at: Date()))
        XCTAssertEqual(summary.exceptionType, "EXC_BAD_ACCESS SIGSEGV")
        XCTAssertEqual(summary.terminationReason, "Namespace SIGNAL, Code 11")
        XCTAssertEqual(summary.faultingSymbol, "Captur.AudioEngine.stop()")
    }

    func testAnUnparseableReportYieldsNoSummaryRatherThanAGuess() {
        XCTAssertNil(CrashReportReader.summarize("not json at all", at: Date()))
    }

    // MARK: - Aggregation

    private func sample(_ moment: ResourceSample.Moment,
                        footprint: UInt64,
                        cpu: Double) -> ResourceSample {
        ResourceSample(at: Date(), moment: moment, footprintBytes: footprint, cpuSeconds: cpu)
    }

    func testCPUPerDictationIsTheDifferenceBetweenTwoCumulativeReadings() {
        let session = SessionRecord(
            startedAt: Date(), ending: .clean, appVersion: "1", build: "1", launchMs: 200,
            samples: [sample(.launched, footprint: 50_000_000, cpu: 1.0),
                      sample(.dictationStart, footprint: 55_000_000, cpu: 2.0),
                      sample(.dictationEnd, footprint: 58_000_000, cpu: 2.5)])

        let summary = HealthAggregator.summarize(sessions: [session], records: [])

        XCTAssertEqual(summary.cpuSecondsPerDictation ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(summary.idleFootprintBytes, 50_000_000)
        XCTAssertEqual(summary.peakFootprintBytes, 58_000_000)
        XCTAssertEqual(summary.launchMs, 200)
    }

    func testOverlappingDictationsShareProcessCPUWithoutDoubleCounting() {
        let first = UUID()
        let second = UUID()
        let samples = [
            ResourceSample(at: Date(), moment: .dictationStart,
                           footprintBytes: 1, cpuSeconds: 1.0, captureID: first),
            ResourceSample(at: Date(), moment: .dictationStart,
                           footprintBytes: 1, cpuSeconds: 1.2, captureID: second),
            ResourceSample(at: Date(), moment: .dictationEnd,
                           footprintBytes: 1, cpuSeconds: 1.7, captureID: first),
            ResourceSample(at: Date(), moment: .dictationEnd,
                           footprintBytes: 1, cpuSeconds: 2.2, captureID: second),
        ]
        let session = SessionRecord(
            startedAt: Date(), ending: .clean, appVersion: "1", build: "1",
            samples: samples)

        let summary = HealthAggregator.summarize(sessions: [session], records: [])

        // 0.2 belongs only to the first capture, the overlapping 0.5 is split,
        // and the final 0.5 belongs only to the second: 0.45 and 0.75. The lower
        // median is therefore 0.45, and the shared interval is counted only once.
        XCTAssertEqual(summary.cpuSecondsPerDictation ?? 0, 0.45, accuracy: 0.001)
    }

    /// The open run has not ended, so counting it either way would be a guess — and
    /// counting it as clean would flatter the number.
    func testTheRunInProgressIsExcludedFromStability() {
        let sessions = [
            SessionRecord(startedAt: Date(), ending: .clean, appVersion: "1", build: "1"),
            SessionRecord(startedAt: Date(), ending: .unexpected, appVersion: "1", build: "1"),
            SessionRecord(startedAt: Date(), ending: .running, appVersion: "1", build: "1")
        ]
        let summary = HealthAggregator.summarize(sessions: sessions, records: [])
        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.cleanExitCount, 1)
        XCTAssertEqual(summary.unexpectedExitCount, 1)
    }

    // MARK: - Percentiles

    func testPercentileIsNearestRank() {
        let values = Array(1...100)
        XCTAssertEqual(HealthAggregator.percentile(values, 0.5), 50)
        XCTAssertEqual(HealthAggregator.percentile(values, 0.95), 95)
    }

    /// "No data" and "measured zero" are different claims, and the screen renders them
    /// differently. A percentile over nothing must not be 0.
    func testPercentileOfNothingIsNilNotZero() {
        XCTAssertNil(HealthAggregator.percentile([], 0.5))
    }
}
