import XCTest
@testable import Captur

final class DiagnosticsTests: XCTestCase {

    // MARK: - The dead-microphone signal

    func test_reportFlagsSilentCaptureAsAnError() {
        var report = DiagnosticsReport.empty
        report.buffersReceived = 120
        report.nonSilentBufferCount = 0
        report.peakLevel = 0

        XCTAssertTrue(report.formatted().contains("SILENT"),
                      "a capture with no non-silent buffers is the exact failure this panel exists to surface")
    }

    func test_doesNotFlagSilentWhenAudioWasActuallyCaptured() {
        var report = DiagnosticsReport.empty
        report.buffersReceived = 120
        report.nonSilentBufferCount = 96
        report.peakLevel = 0.42

        XCTAssertFalse(report.formatted().contains("SILENT"))
    }

    func test_flagsNoBuffersDistinctlyFromSilentBuffers() {
        var report = DiagnosticsReport.empty
        report.buffersReceived = 0
        report.nonSilentBufferCount = 0

        let text = report.formatted()
        XCTAssertTrue(text.contains("NO BUFFERS"),
                      "zero callbacks is a different fault from callbacks carrying silence")
    }

    // MARK: - Secrets

    func test_reportNeverContainsAnApiKey() {
        var report = DiagnosticsReport.empty
        report.errors = ["401 unauthorized for key gsk_liveSecretValue123"]

        let text = report.formatted()
        XCTAssertFalse(text.contains("gsk_"))
        XCTAssertFalse(text.contains("liveSecretValue123"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func test_redactsAKeyAnywhereInTheReportNotJustErrors() {
        var report = DiagnosticsReport.empty
        report.deviceName = "Mic gsk_abc123def"

        XCTAssertFalse(report.formatted().contains("gsk_abc123def"))
    }

    // MARK: - Timings

    func test_timingsRenderInFixedStageOrder() throws {
        var report = DiagnosticsReport.empty
        report.timings = ["whisper": 210, "capture": 3_000, "convert": 12, "insert": 8]

        let lines = report.formatted().split(separator: "\n").map(String.init)
        let capture = try XCTUnwrap(lines.firstIndex { $0.contains("capture") })
        let convert = try XCTUnwrap(lines.firstIndex { $0.contains("convert") })
        let whisper = try XCTUnwrap(lines.firstIndex { $0.contains("whisper") })
        let insert = try XCTUnwrap(lines.firstIndex { $0.contains("insert") })

        XCTAssertLessThan(capture, convert)
        XCTAssertLessThan(convert, whisper)
        XCTAssertLessThan(whisper, insert)
    }

    func test_omitsStagesThatDidNotRun() {
        var report = DiagnosticsReport.empty
        report.timings = ["capture": 3_000]

        let text = report.formatted()
        XCTAssertTrue(text.contains("capture"))
        XCTAssertFalse(text.contains("llm"), "a stage that never ran should not be reported as 0 ms")
    }

    // MARK: - Voice processing honesty

    func test_reportsWhenVoiceProcessingWasRequestedButDidNotEngage() {
        var report = DiagnosticsReport.empty
        report.voiceProcessingRequested = true
        report.voiceProcessingActive = false

        XCTAssertTrue(report.formatted().contains("requested but NOT active"))
    }

    func test_reportsArmedLatency() {
        var report = DiagnosticsReport.empty
        report.armedLatencyMs = 180

        XCTAssertTrue(report.formatted().contains("180"))
    }

    // MARK: - Compression

    func test_reportsCompressionAgainstTheRawHardwareCapture() {
        var report = DiagnosticsReport.empty
        report.durationSeconds = 3.0
        report.fileBytes = 26_000
        report.hardwareSampleRate = 48_000
        report.hardwareChannels = 2

        let text = report.formatted()
        // 3s of 48 kHz stereo float32 is 1,152,000 bytes; 26,000 is ~44x smaller.
        XCTAssertTrue(text.contains("smaller"), "the panel must show what compression actually bought")
        XCTAssertTrue(text.contains("44") || text.contains("43") || text.contains("45"))
    }

    func test_compressionLineIsOmittedWhenThereIsNoAudio() {
        var report = DiagnosticsReport.empty
        report.durationSeconds = 0
        report.fileBytes = 0

        XCTAssertFalse(report.formatted().contains("smaller"))
    }

    func test_reportsUploadBytesPerSecondSoSlowLinksAreVisible() {
        var report = DiagnosticsReport.empty
        report.durationSeconds = 10
        report.fileBytes = 160_000

        XCTAssertTrue(report.formatted().contains("KB/s of speech"))
    }
}
