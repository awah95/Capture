import AVFoundation
import Foundation

/// Drives the real capture path for a fixed number of seconds and reports exactly what
/// happened. This is the instrument that makes a dead microphone readable instead of
/// mysterious — it is deliberately the first UI in the app.
@MainActor
final class DiagnosticsRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var liveLevel: Double = 0
    @Published private(set) var lastReport: DiagnosticsReport?
    @Published private(set) var lastAudioURL: URL?

    private let engine: AudioEngineControlling
    private let directory: URL

    init(engine: AudioEngineControlling, directory: URL = AppPaths.supportDirectory()) {
        self.engine = engine
        self.directory = directory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func availableDevices() -> [AudioInputDevice] {
        engine.availableInputDevices()
    }

    /// Records for `seconds` against the chosen device and returns what was observed.
    /// Never throws — a failure is part of the report, because a thrown error at this
    /// layer would be exactly the information the caller needs.
    func recordSample(seconds: Double = 3,
                      deviceUID: String?,
                      voiceProcessing: Bool) async -> DiagnosticsReport {
        guard !isRunning else { return lastReport ?? .empty }
        isRunning = true
        defer { isRunning = false }

        var report = DiagnosticsReport.empty
        report.voiceProcessingRequested = voiceProcessing

        let url = directory.appendingPathComponent("diagnostic-\(UUID().uuidString).flac")
        let counters = BufferCounters()

        var writer: FLACWriter?
        if let format = AudioFormatConverter.canonicalOutputFormat {
            do {
                writer = try FLACWriter(url: url, format: format)
            } catch {
                report.errors.append("could not open the output file: \(error.localizedDescription)")
            }
        } else {
            report.errors.append("could not build the 16 kHz mono capture format")
        }

        engine.onConvertedBuffer = { buffer in
            counters.consume(buffer)
            writer?.write(buffer)
        }
        engine.onLevel = { [weak self] level, _ in
            self?.liveLevel = level
        }

        let policy = MicSelectionPolicy(
            preferredDeviceUIDs: deviceUID.map { [$0] } ?? [],
            excludeContinuityInputs: false)   // Diagnostics must be able to test any device.

        let captureStart = Date()
        do {
            let info = try await engine.startRecording(policy: policy, voiceProcessing: voiceProcessing)
            report.deviceName = info.device.name
            report.deviceUID = info.device.id
            report.transport = info.device.transport.rawValue
            report.isContinuity = info.device.isContinuityDevice
            report.hardwareSampleRate = info.hardwareSampleRate
            report.hardwareChannels = info.hardwareChannels
            report.voiceProcessingActive = info.voiceProcessingActive
            report.fellBackToSystemDefault = info.fellBackToSystemDefault
            report.armedLatencyMs = Int(info.armedLatency * 1_000)

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await engine.stopRecording()
        } catch {
            report.errors.append(describe(error))
            await engine.cancelRecording()
        }

        engine.onConvertedBuffer = nil
        engine.onLevel = nil
        liveLevel = 0

        report.timings["capture"] = Int(Date().timeIntervalSince(captureStart) * 1_000)

        let snapshot = counters.snapshot()
        report.buffersReceived = snapshot.buffers
        report.nonSilentBufferCount = snapshot.nonSilent
        report.peakLevel = snapshot.peak
        report.rmsLevel = snapshot.rms

        if let writer {
            writer.finish()
            if let writeError = writer.writeError {
                report.errors.append("write failed: \(writeError.localizedDescription)")
            }
            report.durationSeconds = writer.duration
            report.fileFormat = "FLAC 16 kHz mono"
            report.fileBytes = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) .flatMap { $0 } ?? 0
            if report.fileBytes > 0 {
                lastAudioURL = url
            }
        }

        lastReport = report
        return report
    }

    private func describe(_ error: Error) -> String {
        guard let audioError = error as? AudioEngineError else {
            return error.localizedDescription
        }
        switch audioError {
        case .permissionDenied:
            return "microphone permission denied — grant it in System Settings › Privacy & Security › Microphone"
        case .deviceUnavailable:
            return "the selected input device could not be opened"
        case .engineStartFailed(let reason):
            return "engine start failed: \(reason)"
        case .notRecording:
            return "not recording"
        case .fileFinalizationFailed(let reason):
            return "file finalization failed: \(reason)"
        }
    }
}

/// Accumulates per-buffer statistics on the audio queue without touching the main actor.
private final class BufferCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var nonSilent = 0
    private var peak: Double = 0
    private var sumOfSquares: Double = 0
    private var sampleCount: Int = 0

    /// Below this a buffer is indistinguishable from a disconnected input.
    private static let silenceFloor: Float = 0.0005

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var localPeak: Float = 0
        var localSquares: Double = 0
        for index in 0..<frames {
            let sample = abs(channel[index])
            if sample > localPeak { localPeak = sample }
            localSquares += Double(sample) * Double(sample)
        }

        lock.lock()
        buffers += 1
        if localPeak > Self.silenceFloor { nonSilent += 1 }
        peak = max(peak, Double(localPeak))
        sumOfSquares += localSquares
        sampleCount += frames
        lock.unlock()
    }

    func snapshot() -> (buffers: Int, nonSilent: Int, peak: Double, rms: Double) {
        lock.lock()
        defer { lock.unlock() }
        let rms = sampleCount > 0 ? (sumOfSquares / Double(sampleCount)).squareRoot() : 0
        return (buffers, nonSilent, peak, rms)
    }
}
