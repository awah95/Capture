import AVFoundation
import XCTest
@testable import Captur

final class AudioEngineTests: XCTestCase {
    func testPreferredDeviceUIDOrderWinsOverAvailableOrder() {
        let builtIn = device("built-in", transport: .builtIn)
        let firstPreference = device("usb-first", transport: .usb)
        let secondPreference = device("bluetooth-second", transport: .bluetooth)
        let policy = MicSelectionPolicy(
            preferredDeviceUIDs: [firstPreference.id, secondPreference.id],
            excludeContinuityInputs: true
        )

        let selected = selectDevice(
            available: [builtIn, secondPreference, firstPreference],
            policy: policy
        )

        XCTAssertEqual(selected, firstPreference)
    }

    func testContinuityPreferredDeviceIsExcludedWhenPolicyEnabled() {
        let iphone = device(
            "iphone",
            transport: .continuity,
            isContinuity: true
        )
        let local = device("local", transport: .builtIn)
        let policy = MicSelectionPolicy(
            preferredDeviceUIDs: [iphone.id],
            excludeContinuityInputs: true
        )

        XCTAssertEqual(
            selectDevice(available: [iphone, local], policy: policy),
            nil
        )
    }

    func testContinuityPreferredDeviceIsAllowedWhenPolicyDisabled() {
        let iphone = device(
            "iphone",
            transport: .continuity,
            isContinuity: true
        )
        let local = device("local", transport: .builtIn)
        let policy = MicSelectionPolicy(
            preferredDeviceUIDs: [iphone.id],
            excludeContinuityInputs: false
        )

        XCTAssertEqual(
            selectDevice(available: [local, iphone], policy: policy),
            iphone
        )
    }

    func testMissingPreferredDevicesDoNotFallBackToUnlistedInputs() {
        let virtual = device("loopback", transport: .virtual)
        let usb = device("usb", transport: .usb)
        let bluetooth = device("bluetooth", transport: .bluetooth)
        let policy = MicSelectionPolicy(
            preferredDeviceUIDs: ["missing-one", "missing-two"],
            excludeContinuityInputs: true
        )

        XCTAssertEqual(
            selectDevice(
                available: [virtual, usb, bluetooth],
                policy: policy
            ),
            nil
        )
    }

    func testFallbackDoesNotSelectContinuityEvenWhenExclusionIsDisabled() {
        let iphone = device(
            "iphone",
            transport: .continuity,
            isContinuity: true
        )
        let bluetooth = device("bluetooth", transport: .bluetooth)
        let policy = MicSelectionPolicy(
            preferredDeviceUIDs: [],
            excludeContinuityInputs: false
        )

        XCTAssertEqual(
            selectDevice(available: [iphone, bluetooth], policy: policy),
            bluetooth
        )
    }

    func testUnlistedEarphonesCannotReplaceUnavailableChosenMic() {
        let headset = device("headset", transport: .bluetooth)
        let policy = MicSelectionPolicy(preferredDeviceUIDs: ["quadcast"], excludeContinuityInputs: true)
        XCTAssertNil(selectDevice(available: [headset], policy: policy))
    }

    func testExplicitBuiltInBackupWinsOverConnectedUnlistedEarphones() {
        let builtIn = device("built-in", transport: .builtIn)
        let headset = device("headset", transport: .bluetooth)
        let policy = MicSelectionPolicy(preferredDeviceUIDs: ["quadcast", builtIn.id], excludeContinuityInputs: true)
        XCTAssertEqual(selectDevice(available: [headset, builtIn], policy: policy), builtIn)
    }

    func testAutomaticSelectionSkipsVirtualInput() {
        let usb = device("usb", transport: .usb)
        XCTAssertEqual(selectDevice(available: [device("virtual", transport: .virtual), usb], policy: .default), usb)
    }

    func testSelectionFailureMessageReachesRecordingUI() {
        XCTAssertEqual(AudioEngineError.engineStartFailed("Selected microphone unavailable").localizedDescription,
                       "Selected microphone unavailable")
    }

    func testEmptyAvailableListReturnsNil() {
        XCTAssertNil(
            selectDevice(available: [], policy: .default)
        )
    }

    func testNormalizedRMSForSilenceIsZero() {
        XCTAssertEqual(
            normalizedRMS(samples: Array(repeating: 0, count: 64)),
            0,
            accuracy: 0.000_001
        )
    }

    func testNormalizedRMSForSyntheticPCM() {
        XCTAssertEqual(
            normalizedRMS(samples: [0.5, -0.5, 0.5, -0.5]),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            normalizedRMS(samples: [1, -1]),
            1,
            accuracy: 0.000_001
        )
    }

    func testNormalizedRMSIsClampedToUnitRange() {
        XCTAssertEqual(
            normalizedRMS(samples: [2, -2]),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(normalizedRMS(samples: []), 0)
    }

    // MARK: - Engine surface (no hardware required)

    func testEngineStartsIdleWithNoActiveDevice() {
        let engine = AudioEngine()

        XCTAssertFalse(engine.isRecording)
        XCTAssertNil(engine.activeDevice)
    }

    /// The whole point of the rewrite: the control surface is reachable without the
    /// main actor, so nothing in the capture path can be blocked by a SwiftUI stall.
    func testDeviceEnumerationWorksOffTheMainThread() {
        let engine = AudioEngine()
        let done = expectation(description: "off-main enumeration")
        var offMain: [AudioInputDevice] = []

        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            offMain = engine.availableInputDevices()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        // Whatever this machine has, the two reads must agree on identity.
        XCTAssertEqual(offMain.map(\.id), engine.availableInputDevices().map(\.id))
    }

    func testStoppingAnIdleEngineIsHarmless() async {
        let engine = AudioEngine()

        await engine.stopRecording()
        await engine.cancelRecording()

        XCTAssertFalse(engine.isRecording)
        XCTAssertNil(engine.activeDevice)
    }

    func testAudioQueueGuardPassesOffTheMainThread() {
        let done = expectation(description: "audio queue")
        AudioQueue.queue.async {
            XCTAssertFalse(Thread.isMainThread, "the audio queue is never the main thread")
            AudioQueue.assertNotMain("test")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testRetiredTapLifetimeRejectsNewBuffersButDrainsAcceptedWork() async {
        let lifetime = TapLifetime()

        XCTAssertTrue(lifetime.acceptBuffer())
        lifetime.stopAcceptingBuffers()
        XCTAssertFalse(lifetime.acceptBuffer())
        XCTAssertTrue(lifetime.isValid, "accepted buffers remain publishable during the drain")

        let drain = Task {
            await lifetime.waitForAcceptedBuffers()
            return true
        }
        await Task.yield()

        lifetime.completeBuffer()
        let drained = await drain.value
        XCTAssertTrue(drained)

        lifetime.invalidate()
        XCTAssertFalse(lifetime.isValid)
        XCTAssertFalse(lifetime.acceptBuffer())
    }

    func testCaptureStartInfoComparesEveryNegotiatedValue() {
        let base = startInfo()

        XCTAssertEqual(base, startInfo())
        XCTAssertNotEqual(base, startInfo(sampleRate: 44_100))
        XCTAssertNotEqual(base, startInfo(channels: 2))
        XCTAssertNotEqual(base, startInfo(voiceProcessing: false))
        XCTAssertNotEqual(base, startInfo(fellBack: true))
        XCTAssertNotEqual(base, startInfo(latency: 1.2))
    }

    // Live capture, permission, device pinning, AEC ducking, the transport-aware
    // arming window and unplug behavior all require real audio hardware and user
    // authorization, so they are gated as the LV1 live-microphone check rather than
    // run here.

    private func startInfo(
        sampleRate: Double = 48_000,
        channels: UInt32 = 1,
        voiceProcessing: Bool = true,
        fellBack: Bool = false,
        latency: TimeInterval = 0.12
    ) -> CaptureStartInfo {
        CaptureStartInfo(
            device: device("built-in", transport: .builtIn),
            hardwareSampleRate: sampleRate,
            hardwareChannels: channels,
            voiceProcessingActive: voiceProcessing,
            fellBackToSystemDefault: fellBack,
            armedLatency: latency
        )
    }

    private func device(
        _ id: String,
        transport: AudioTransport,
        isContinuity: Bool = false
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: id,
            transport: transport,
            isContinuityDevice: isContinuity
        )
    }
}
