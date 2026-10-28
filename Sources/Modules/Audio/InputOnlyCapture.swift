import AudioToolbox
import AVFoundation
import Foundation

/// An input-only queue pinned to a microphone UID. It never opens the output
/// graph or changes the system input, so Bluetooth playback keeps its route.
final class InputOnlyCapture: @unchecked Sendable {
    private var queue: AudioQueueRef?
    private let format: AVAudioFormat
    private let consume: (AVAudioPCMBuffer, TimeInterval) -> Void

    init(deviceUID: String, consume: @escaping (AVAudioPCMBuffer, TimeInterval) -> Void) throws {
        guard let format = AudioFormatConverter.canonicalOutputFormat else {
            throw AudioEngineError.deviceUnavailable
        }
        self.format = format
        self.consume = consume
        var description = format.streamDescription.pointee
        // AudioQueue expects packed mono float samples, not a noninterleaved flag.
        description.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        var created: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&created, &description, 0, AudioQueue.queue) {
            [weak self] queue, buffer, timestamp, _, _ in
            guard let self else { return }
            let frames = AVAudioFrameCount(buffer.pointee.mAudioDataByteSize / 4)
            if frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: frames),
               let channel = pcm.floatChannelData?.pointee {
                pcm.frameLength = frames
                memcpy(channel, buffer.pointee.mAudioData, Int(buffer.pointee.mAudioDataByteSize))
                let host = timestamp.pointee.mFlags.contains(.hostTimeValid)
                    ? AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
                    : ProcessInfo.processInfo.systemUptime
                self.consume(pcm, host)
            }
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard status == noErr, let created else {
            throw AudioEngineError.engineStartFailed("Could not create microphone capture (\(status)).")
        }
        queue = created
        do {
            let deviceString = deviceUID as CFString
            var uid = Unmanaged.passUnretained(deviceString)
            try withExtendedLifetime(deviceString) {
                try check(AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, &uid,
                                                 UInt32(MemoryLayout<Unmanaged<CFString>>.size)))
            }
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                // 64 ms at 16 kHz, with three buffers to absorb scheduling jitter.
                try check(AudioQueueAllocateBuffer(created, 4_096, &buffer))
                guard let buffer else { throw AudioEngineError.deviceUnavailable }
                try check(AudioQueueEnqueueBuffer(created, buffer, 0, nil))
            }
        } catch {
            stop()
            throw error
        }
    }

    func start() throws {
        guard let queue else { throw AudioEngineError.deviceUnavailable }
        try check(AudioQueueStart(queue, nil))
    }

    func stop() {
        guard let queue else { return }
        self.queue = nil
        AudioQueueStop(queue, true)
        // Dispose waits for callbacks; callers never invoke this on AudioQueue.queue.
        AudioQueueDispose(queue, true)
    }

    deinit { stop() }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw AudioEngineError.engineStartFailed("Could not open the selected microphone (\(status)).")
        }
    }
}
