import CoreAudio
import Foundation

/// Not main-actor isolated: the audio engine that owns it is not either, and this must
/// be readable synchronously from the capture path. State is lock-guarded instead.
final class AudioDeviceMonitor: @unchecked Sendable {
    typealias ChangeHandler = ([AudioInputDevice]) -> Void

    var onDevicesChanged: ChangeHandler? {
        get { lock.withLock { _onDevicesChanged } }
        set { lock.withLock { _onDevicesChanged = newValue } }
    }

    var devices: [AudioInputDevice] { lock.withLock { _devices } }

    /// CoreAudio delivers hot-plug notifications here. Deliberately not the main queue:
    /// the callback enumerates every device and can tear a live capture down, and none
    /// of that belongs on the thread that renders the waveform.
    private let listenerQueue = DispatchQueue(label: "com.awah.captur.audio.devices")

    private let lock = NSLock()
    private var _onDevicesChanged: ChangeHandler?
    private var _devices: [AudioInputDevice] = []
    private var deviceIDsByUID: [String: AudioDeviceID] = [:]
    private var devicesByID: [AudioDeviceID: AudioInputDevice] = [:]
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isListening = false

    init() {
        refresh()
        installListener()
    }

    deinit {
        guard isListening, let listenerBlock else { return }
        for var address in Self.monitoredAddresses {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listenerBlock
            )
        }
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        lock.withLock { deviceIDsByUID[uid] }
    }

    @discardableResult
    func refresh() -> [AudioInputDevice] {
        let entries = Self.readInputDevices()
        return lock.withLock {
            _devices = entries.map(\.device)
            deviceIDsByUID = Dictionary(
                entries.map { ($0.device.id, $0.deviceID) },
                uniquingKeysWith: { first, _ in first }
            )
            devicesByID = Dictionary(
                entries.map { ($0.deviceID, $0.device) },
                uniquingKeysWith: { first, _ in first }
            )
            return _devices
        }
    }

    /// The system's current default input, used as the last-resort fallback when the
    /// selection policy matches nothing. Returns nil when the machine has no input at all.
    /// Makes `deviceID` the system default input.
    ///
    /// This is how Captur selects a microphone. The obvious alternative — setting
    /// `kAudioOutputUnitProperty_CurrentDevice` on AVAudioEngine's AUHAL — reports
    /// success and then silently delivers no buffers at all, which is exactly the dead
    /// microphone this app shipped with. Verified against real hardware on 2026-07-25:
    /// pinning the AUHAL yields 0 buffers on every device; leaving it alone yields audio.
    @discardableResult
    func setSystemDefaultInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        return status == noErr
    }

    func systemDefaultInput() -> (device: AudioInputDevice, deviceID: AudioDeviceID)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }

        if let known = lock.withLock({ devicesByID[deviceID] }) {
            return (known, deviceID)
        }
        // The default may have appeared since the last refresh.
        refresh()
        guard let device = lock.withLock({ devicesByID[deviceID] }) else { return nil }
        return (device, deviceID)
    }

    private func installListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let refreshed = self.refresh()
            self.onDevicesChanged?(refreshed)
        }

        for var address in Self.monitoredAddresses {
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block
            )
            if status == noErr { isListening = true }
        }
        if isListening { listenerBlock = block }
    }

    private struct DeviceEntry {
        let deviceID: AudioDeviceID
        let device: AudioInputDevice
    }

    private static var monitoredAddresses: [AudioObjectPropertyAddress] {
        [devicesAddress, AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)]
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readInputDevices() -> [DeviceEntry] {
        var address = devicesAddress
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: count
        )
        let status = deviceIDs.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                base
            )
        }
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(
                    deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                  ),
                  let name = stringProperty(
                    deviceID,
                    selector: kAudioObjectPropertyName
                  ) else {
                return nil
            }

            let rawTransport = uint32Property(
                deviceID,
                selector: kAudioDevicePropertyTransportType
            ) ?? kAudioDeviceTransportTypeUnknown
            let transport = mappedTransport(rawTransport)
            let model = stringProperty(
                deviceID,
                selector: kAudioDevicePropertyModelUID
            ) ?? ""
            let identifyingText = "\(name) \(model)".lowercased()
            let isContinuity = transport == .continuity
                || identifyingText.contains("iphone")
                || identifyingText.contains("continuity")

            return DeviceEntry(
                deviceID: deviceID,
                device: AudioInputDevice(
                    id: uid,
                    name: name,
                    transport: transport,
                    isContinuityDevice: isContinuity
                )
            )
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr && byteCount >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        ) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }

    private static func uint32Property(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func mappedTransport(_ rawValue: UInt32) -> AudioTransport {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .continuity
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return .virtual
        default:
            return .other
        }
    }
}
