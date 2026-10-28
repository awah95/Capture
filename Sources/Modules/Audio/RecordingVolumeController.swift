import CoreAudio
import Foundation

struct OutputVolumeSnapshot: Equatable {
    let deviceUID: String
    let elements: [UInt32]
    let levels: [Float32]
}

@MainActor protocol OutputVolumeControlling {
    func read() -> OutputVolumeSnapshot?
    func write(_ snapshot: OutputVolumeSnapshot) -> Bool
}

/// Reads the current macOS output each time. No headset models or player APIs.
@MainActor final class SystemOutputVolume: OutputVolumeControlling {
    private func address(_ selector: AudioObjectPropertySelector,
                         element: UInt32 = 0,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func device() -> (AudioDeviceID, String)? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        property = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>? = nil
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return (id, uid.takeUnretainedValue() as String)
    }

    func read() -> OutputVolumeSnapshot? {
        guard let (id, uid) = device() else { return nil }
        // Most outputs expose a master scalar; others expose channel scalars.
        var master = address(kAudioDevicePropertyVolumeScalar)
        let elements: [UInt32]
        if AudioObjectHasProperty(id, &master) { elements = [0] }
        else {
            var stream = address(kAudioDevicePropertyStreamConfiguration)
            var byteCount: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &stream, 0, nil, &byteCount) == noErr,
                  byteCount >= MemoryLayout<AudioBufferList>.size else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            guard AudioObjectGetPropertyData(id, &stream, 0, nil, &byteCount, storage) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { return nil }
            elements = (1...channels).map(UInt32.init)
        }
        var levels: [Float32] = []
        for element in elements {
            var property = address(kAudioDevicePropertyVolumeScalar, element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &property, &settable) == noErr, settable.boolValue else { return nil }
            var level: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &level) == noErr,
                  level.isFinite else { return nil }
            levels.append(level)
        }
        return OutputVolumeSnapshot(deviceUID: uid, elements: elements, levels: levels)
    }

    func write(_ snapshot: OutputVolumeSnapshot) -> Bool {
        guard let (id, uid) = device(), uid == snapshot.deviceUID,
              snapshot.elements.count == snapshot.levels.count else { return false }
        var succeeded = true
        for (element, level) in zip(snapshot.elements, snapshot.levels) {
            var value = level
            var property = address(kAudioDevicePropertyVolumeScalar, element: element)
            if AudioObjectSetPropertyData(id, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) != noErr {
                succeeded = false
            }
        }
        return succeeded
    }
}

@MainActor final class RecordingVolumeController {
    private let output: any OutputVolumeControlling
    private var isRecording = false
    private var original: OutputVolumeSnapshot?
    private var applied: OutputVolumeSnapshot?

    init(output: (any OutputVolumeControlling)? = nil) {
        self.output = output ?? SystemOutputVolume()
    }

    func update(recording: Bool, enabled: Bool, pauseEnabled: Bool, target: Double) {
        // Turning the option off or choosing pause restores an existing reduction.
        guard recording, enabled, !pauseEnabled else {
            restore()
            isRecording = recording
            return
        }
        guard !isRecording else { return }
        isRecording = true
        guard target.isFinite, let before = output.read() else { return }
        let limit = Float32(min(max(target, 0), 1))
        let lowered = OutputVolumeSnapshot(deviceUID: before.deviceUID, elements: before.elements,
                                          levels: before.levels.map { min($0, limit) })
        guard lowered != before else { return }
        original = before
        // Read back actual hardware values, including rounding and partial failures.
        let wroteAllLevels = output.write(lowered)
        // A transient read failure must not forget a successful reduction. Use the
        // requested levels as the conservative restore guard until output is readable.
        applied = output.read() ?? (wroteAllLevels ? lowered : nil)
    }

    func restore() {
        defer { original = nil; applied = nil; isRecording = false }
        guard let original, let applied, let current = output.read(),
              current.deviceUID == original.deviceUID,
              current.elements == applied.elements,
              current.levels.count == applied.levels.count,
              zip(current.levels, applied.levels).allSatisfy({ abs($0 - $1) < 0.001 }) else { return }
        // A manual volume change or a new output device wins over restoration.
        _ = output.write(original)
    }
}
