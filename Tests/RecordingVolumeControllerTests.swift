import XCTest
@testable import Captur

@MainActor final class RecordingVolumeControllerTests: XCTestCase {
    private final class Output: OutputVolumeControlling {
        var snapshot: OutputVolumeSnapshot? = OutputVolumeSnapshot(deviceUID: "output", elements: [0], levels: [0.8])
        var writes: [OutputVolumeSnapshot] = []
        var reads = 0
        var failedReads: Set<Int> = []
        func read() -> OutputVolumeSnapshot? {
            reads += 1
            return failedReads.contains(reads) ? nil : snapshot
        }
        func write(_ value: OutputVolumeSnapshot) -> Bool { writes.append(value); snapshot = value; return true }
    }

    func testDisabledDoesNotReadOrWriteOutput() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: false, pauseEnabled: false, target: 0.2)
        controller.update(recording: false, enabled: false, pauseEnabled: false, target: 0.2)
        XCTAssertEqual(output.reads, 0); XCTAssertTrue(output.writes.isEmpty)
    }

    func testFixedLevelAndRestoreAtRecordingEnd() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        XCTAssertEqual(output.snapshot?.levels, [0.25])
        controller.update(recording: false, enabled: true, pauseEnabled: false, target: 0.25)
        XCTAssertEqual(output.snapshot?.levels, [0.8])
        XCTAssertEqual(output.writes.count, 2)
    }

    func testQuieterOutputNeverIncreases() {
        let output = Output(); output.snapshot = OutputVolumeSnapshot(deviceUID: "output", elements: [0], levels: [0.1])
        let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        controller.restore()
        XCTAssertTrue(output.writes.isEmpty)
    }

    func testTransientReadbackFailureStillRestoresSuccessfulReduction() {
        let output = Output(); output.failedReads = [2]
        let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        XCTAssertEqual(output.snapshot?.levels, [0.25])
        controller.restore()
        XCTAssertEqual(output.snapshot?.levels, [0.8])
    }

    func testManualChangeStillWinsAfterReadbackFailure() {
        let output = Output(); output.failedReads = [2]
        let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        output.snapshot = OutputVolumeSnapshot(deviceUID: "output", elements: [0], levels: [0.5])
        controller.restore()
        XCTAssertEqual(output.snapshot?.levels, [0.5])
        XCTAssertEqual(output.writes.count, 1)
    }

    func testManualVolumeChangeWins() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        output.snapshot = OutputVolumeSnapshot(deviceUID: "output", elements: [0], levels: [0.5])
        controller.restore()
        XCTAssertEqual(output.snapshot?.levels, [0.5]); XCTAssertEqual(output.writes.count, 1)
    }

    func testDifferentOutputIsNotOverwritten() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        output.snapshot = OutputVolumeSnapshot(deviceUID: "new-speaker", elements: [0], levels: [0.25])
        controller.restore()
        XCTAssertEqual(output.snapshot?.deviceUID, "new-speaker"); XCTAssertEqual(output.writes.count, 1)
    }

    func testPauseTakesPriority() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: true, target: 0.25)
        XCTAssertTrue(output.writes.isEmpty); XCTAssertEqual(output.reads, 0)
    }

    func testRepeatedRecordingUpdatesDoNotOverwriteOriginal() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        for _ in 0..<5 { controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25) }
        controller.restore()
        XCTAssertEqual(output.snapshot?.levels, [0.8]); XCTAssertEqual(output.writes.count, 2)
    }

    func testDisablingMidRecordingRestoresImmediately() {
        let output = Output(); let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        controller.update(recording: true, enabled: false, pauseEnabled: false, target: 0.25)
        XCTAssertEqual(output.snapshot?.levels, [0.8])
    }

    func testChannelsRestoreIndependently() {
        let output = Output(); output.snapshot = OutputVolumeSnapshot(deviceUID: "output", elements: [1, 2], levels: [0.8, 0.1])
        let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        XCTAssertEqual(output.snapshot?.levels, [0.25, 0.1])
        controller.restore(); XCTAssertEqual(output.snapshot?.levels, [0.8, 0.1])
    }

    func testUnsupportedOutputAndInvalidTargetAreNoOps() {
        let output = Output(); output.snapshot = nil
        let controller = RecordingVolumeController(output: output)
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: 0.25)
        controller.restore()
        controller.update(recording: true, enabled: true, pauseEnabled: false, target: .nan)
        XCTAssertTrue(output.writes.isEmpty)
    }

    func testVoiceProcessingCannotDuckUnpausedPlayback() {
        let suite = "captur-echo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceProcessing = true
        settings.pauseMediaDuringRecording = false
        XCTAssertFalse(settings.captureVoiceProcessing)
        settings.lowerOutputVolumeDuringRecording = true
        XCTAssertFalse(settings.captureVoiceProcessing)
        settings.pauseMediaDuringRecording = true
        XCTAssertTrue(settings.captureVoiceProcessing)
    }

    func testSettingsDefaultOffAndPersistFixedLevel() {
        let suite = "captur-volume-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.lowerOutputVolumeDuringRecording)
        settings.lowerOutputVolumeDuringRecording = true
        settings.recordingOutputVolume = 0.3
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.lowerOutputVolumeDuringRecording)
        XCTAssertEqual(reloaded.recordingOutputVolume, 0.3)
    }
}
