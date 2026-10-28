import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// AVAudioEngine capture with voice processing (AEC), hardware device pinning and
/// metering.
///
/// **The render graph is deliberately empty.** No mixer is attached, nothing is
/// connected, and the tap is installed straight on `inputNode` using the exact
/// `AVAudioFormat` the input node reports *after* voice processing has been enabled and
/// the device re-pinned. The previous version routed
/// `inputNode → AVAudioMixerNode → mainMixerNode` and tapped the mixer with a
/// hand-built mono format; format negotiation across that chain on a voice-processing
/// IO unit is the prime suspect for the tap that never fired. Downsampling to 16 kHz
/// mono is done by `AudioFormatConverter` inside the tap callback, never by asking
/// AVAudioEngine to negotiate it.
///
/// Not main-actor isolated: every per-buffer operation runs on `AudioQueue.queue`.
final class AudioEngine: AudioEngineControlling, @unchecked Sendable {

    // MARK: Callbacks

    var onLevel: ((Double, TimeInterval) -> Void)? {
        get { lock.withLock { _onLevel } }
        set { lock.withLock { _onLevel = newValue } }
    }

    var onActiveDeviceChange: ((AudioInputDevice?) -> Void)? {
        get { lock.withLock { _onActiveDeviceChange } }
        set { lock.withLock { _onActiveDeviceChange = newValue } }
    }

    var onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _onConvertedBuffer } }
        set { lock.withLock { _onConvertedBuffer = newValue } }
    }

    // MARK: Public state

    var activeDevice: AudioInputDevice? { lock.withLock { _activeDevice } }

    var isRecording: Bool {
        lock.withLock {
            if case .running = state { return true }
            return false
        }
    }

    // MARK: Tuning

    /// A built-in or wired input hands over its first buffer almost immediately.
    private static let armingWindow: TimeInterval = 0.7
    /// Bluetooth has to renegotiate to the HFP input profile first, which routinely
    /// takes one to two seconds. A fixed 700 ms window would false-fail every headset.
    private static let bluetoothArmingWindow: TimeInterval = 2.0
    private static let tapBufferSize: AVAudioFrameCount = 1_024
    private static let meterInterval: TimeInterval = 1.0 / 30.0

    // MARK: Lifecycle state
    //
    // One lock-protected state machine, so "is a start allowed", "is this start still
    // wanted" and "publish the live session" are a single atomic decision. The old
    // engine's separate `isRecording` flag plus generation counter left a window in
    // which two starts could both proceed and the loser's AVAudioEngine was orphaned,
    // still running and still tapping.

    private enum State {
        case idle
        /// A start is in flight: permission prompt, device pinning, arming window.
        case starting(token: UInt64)
        case running(token: UInt64, session: Session)

        var token: UInt64? {
            switch self {
            case .idle: return nil
            case .starting(let token): return token
            case .running(let token, _): return token
            }
        }
    }

    // MARK: Storage

    private let log = Logger(subsystem: "com.awah.captur", category: "audio")
    private let deviceMonitor: AudioDeviceMonitor

    private let lock = NSLock()
    private var _onLevel: ((Double, TimeInterval) -> Void)?
    private var _onActiveDeviceChange: ((AudioInputDevice?) -> Void)?
    private var _onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var _activeDevice: AudioInputDevice?
    private var state: State = .idle
    /// The tap lifetime of the attempt currently arming. Held here (rather than only in
    /// the attempt's local scope) so a stop during `.starting` can silence that attempt
    /// immediately, instead of letting its buffers keep arriving until it notices at
    /// publish time — by which point a newer recording's file may be installed.
    private var startingLifetime: TapLifetime?
    /// Monotonic session token. A start suspended at the microphone permission prompt
    /// is invalidated by stop/cancel moving the state to `.idle`, which retires the
    /// token the suspended start is holding. Nothing that runs during a legitimate
    /// start ever advances it.
    private var nextToken: UInt64 = 0

    init() {
        let monitor = AudioDeviceMonitor()
        deviceMonitor = monitor
        monitor.onDevicesChanged = { [weak self] devices in
            self?.handleDeviceListChange(devices)
        }
    }

    // MARK: - Devices

    func availableInputDevices() -> [AudioInputDevice] {
        deviceMonitor.refresh()
    }

    // MARK: - Start

    func startRecording(
        policy: MicSelectionPolicy,
        voiceProcessing: Bool
    ) async throws -> CaptureStartInfo {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let token = try beginStart()
        do {
            return try await runStart(
                token: token,
                policy: policy,
                voiceProcessing: voiceProcessing,
                startedAt: startedAt
            )
        } catch {
            // Only retires this start; a stop that already moved us to `.idle`, or a
            // newer start, is left untouched.
            abandonStart(token)
            throw error
        }
    }

    private func runStart(
        token: UInt64,
        policy: MicSelectionPolicy,
        voiceProcessing: Bool,
        startedAt: TimeInterval
    ) async throws -> CaptureStartInfo {
        guard await microphonePermissionGranted() else {
            // Cancellation resolves the permission wait as "not granted"; it must not be
            // reported to the user as a denial.
            try Task.checkCancellation()
            throw AudioEngineError.permissionDenied
        }
        try checkStillWanted(token)

        // One silent start earns exactly one retry: a device caught mid-profile-switch
        // usually hands over buffers on the second attempt.
        for attempt in 0..<2 {
            try checkStillWanted(token)
            // Hot-plug/profile changes can replace CoreAudio IDs between attempts.
            let resolved = try resolveDevice(policy: policy)
            if let info = try await attemptStart(
                resolved: resolved,
                voiceProcessing: voiceProcessing,
                token: token,
                startedAt: startedAt
            ) {
                return info
            }
            log.error("Capture produced no buffers (attempt \(attempt + 1) of 2).")
        }

        throw AudioEngineError.engineStartFailed("No audio buffers received")
    }

    // MARK: - Stop

    func stopRecording() async {
        let claimed = claimForStop()
        // Invalidated outside the engine lock, per the lock-order note on `TapLifetime`.
        claimed.armingLifetime?.invalidate()
        if let session = claimed.session { await finish(session) }
    }

    func cancelRecording() async {
        // There is no output file to delete any more — the consumer of converted
        // buffers owns whatever it wrote — so cancel and stop are the same teardown.
        await stopRecording()
    }

    // MARK: - Start internals

    private struct ResolvedDevice {
        let device: AudioInputDevice
        let deviceID: AudioDeviceID
        let fellBackToSystemDefault: Bool
    }

    private struct DefaultInputChange {
        let previousUID: String
        let selectedUID: String
    }

    private final class Session {
        let engine: AVAudioEngine?
        let inputNode: AVAudioInputNode?
        let inputOnly: InputOnlyCapture?
        let lifetime: TapLifetime
        let token: UInt64
        let defaultInputChange: DefaultInputChange?

        init(engine: AVAudioEngine, inputNode: AVAudioInputNode, lifetime: TapLifetime, token: UInt64, defaultInputChange: DefaultInputChange?) {
            self.engine = engine
            self.inputNode = inputNode
            self.inputOnly = nil
            self.lifetime = lifetime
            self.token = token
            self.defaultInputChange = defaultInputChange
        }

        init(inputOnly: InputOnlyCapture, lifetime: TapLifetime, token: UInt64) {
            self.engine = nil
            self.inputNode = nil
            self.inputOnly = inputOnly
            self.lifetime = lifetime
            self.token = token
            self.defaultInputChange = nil
        }
    }

    private func resolveDevice(policy: MicSelectionPolicy) throws -> ResolvedDevice {
        let devices = deviceMonitor.refresh()

        if let selected = selectDevice(available: devices, policy: policy),
           let deviceID = deviceMonitor.deviceID(forUID: selected.id) {
            return ResolvedDevice(
                device: selected,
                deviceID: deviceID,
                fellBackToSystemDefault: false
            )
        }

        guard policy.preferredDeviceUIDs.isEmpty else {
            throw AudioEngineError.engineStartFailed("Your selected microphones are unavailable. Connect one or update Settings → Microphone.")
        }

        // Nothing matched the policy. Recording with the system's own default beats
        // refusing to record at all.
        guard let fallback = deviceMonitor.systemDefaultInput(),
              !fallback.device.isContinuityDevice else {
            throw AudioEngineError.deviceUnavailable
        }
        log.notice("Mic policy matched nothing; falling back to the system default input.")
        return ResolvedDevice(
            device: fallback.device,
            deviceID: fallback.deviceID,
            fellBackToSystemDefault: true
        )
    }

    /// One start attempt. Returns nil when the engine started but no converted buffer
    /// arrived inside the arming window (the caller retries once); throws for every
    /// other failure. Either way the engine is fully torn down before returning.
    private func attemptStart(
        resolved: ResolvedDevice,
        voiceProcessing: Bool,
        token: UInt64,
        startedAt: TimeInterval
    ) async throws -> CaptureStartInfo? {
        if !voiceProcessing {
            return try await attemptInputOnlyStart(resolved: resolved, token: token, startedAt: startedAt)
        }

        // 4. Select the microphone BEFORE the engine exists. AVAudioEngine binds to the
        // default input the moment `inputNode` is touched, so the selection has to be in
        // place first — and it has to be a real default-device change, not an AUHAL pin.
        let defaultInputChange = try await makeDeviceDefault(resolved, token: token)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // Retires this attempt's tap. Blocks already queued on AudioQueue check it
        // before publishing anything, so audio captured by an abandoned attempt can
        // never be written into a later recording's file.
        let lifetime = TapLifetime()
        guard attachArmingLifetime(lifetime, token: token) else {
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            throw CancellationError()
        }

        // 6. Voice processing is best-effort: a driver that refuses AEC must still record.
        var voiceProcessingActive = false
        if voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingActive = inputNode.isVoiceProcessingEnabled
            } catch {
                log.notice(
                    "Voice processing unavailable on \(resolved.device.name, privacy: .public); continuing without AEC."
                )
                voiceProcessingActive = false
            }
        }

        // 7. macOS ducks all other audio by default once voice processing is on, which
        // would drop the user's music every time they dictate — precisely the annoyance
        // echo cancellation exists to avoid. Turn the ducking down explicitly.
        if voiceProcessingActive {
            configureMinimumDucking(on: inputNode)
        }

        // 8. Enabling voice processing rebuilds the IO unit. The selection is a system
        // default-device change rather than a per-unit pin, so the rebuild picks the same
        // device back up on its own — nothing to re-assert.
        //
        // With voice processing on, the rebuilt unit reports a 44100 Hz **9-channel**
        // format tagged `kAudioChannelLayoutTag_DiscreteInOrder`. Channel 0 is the
        // microphone — measured, and every other channel carries the same content — but
        // `AVAudioConverter` has no mixing matrix for a discrete layout and silently
        // downmixes it to zeros. `AudioFormatConverter` therefore extracts channel 0
        // before converting; see that type and `VoiceProcessingProbe` for the evidence.

        // 9. Only now is the input node's format meaningful.
        let observedFormat = inputNode.outputFormat(forBus: 0)
        guard observedFormat.sampleRate > 0, observedFormat.channelCount > 0 else {
            log.error(
                "Input node reported an unusable format: \(observedFormat, privacy: .public)"
            )
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            throw AudioEngineError.deviceUnavailable
        }

        // 10. Conversion to 16 kHz mono happens in the tap, not in the render graph.
        let converter: AudioFormatConverter
        do {
            converter = try AudioFormatConverter(inputFormat: observedFormat)
        } catch {
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            throw error
        }

        // 11. Tap the input node directly, with the exact format it just reported.
        //
        // The consumers are snapshotted per attempt rather than fetched per buffer. A
        // buffer that was already in flight when this attempt was retired would
        // otherwise pick up whatever callback a *newer* recording had since installed
        // and write old audio into the new file.
        let consumers = lock.withLock { (buffer: _onConvertedBuffer, level: _onLevel) }
        let gate = ArmingGate()
        let throttle = LevelThrottle(interval: Self.meterInterval)
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: observedFormat
        ) { [weak self] buffer, time in
            // Timestamped on the tap thread itself, so the arming latency measures the
            // hardware rather than how quickly our queue happened to drain.
            gate.noteTapFired(at: ProcessInfo.processInfo.systemUptime)

            guard let self, lifetime.acceptBuffer() else { return }
            guard let copy = buffer.detachedCopy() else {
                lifetime.completeBuffer()
                return
            }
            let hostSeconds = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime

            AudioQueue.queue.async {
                AudioQueue.assertNotMain("AudioEngine tap")
                defer { lifetime.completeBuffer() }
                self.process(
                    copy,
                    hostSeconds: hostSeconds,
                    converter: converter,
                    throttle: throttle,
                    lifetime: lifetime,
                    gate: gate,
                    consumers: consumers
                )
            }
        }

        // 12. Start.
        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }

        // 13. Transport-aware start guard — never leave the engine sitting silently dead.
        // The gate opens on the first *converted* buffer, not merely the first tap
        // callback, so a tap that fires but yields nothing downstream still fails the
        // arm rather than reporting a healthy start into a dead pipeline.
        let window = resolved.device.transport == .bluetooth
            ? Self.bluetoothArmingWindow
            : Self.armingWindow
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            gate.signal(false)
        }
        let armed = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            // Do not sit out the whole arming window for a start nobody wants any more.
            gate.signal(false)
        }
        timeout.cancel()

        // Cancellation is checked before the arming result, so a cancelled start can
        // never publish a live session just because a buffer happened to land first.
        do {
            try checkStillWanted(token)
        } catch {
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            throw error
        }

        guard armed else {
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            return nil
        }

        guard deviceMonitor.systemDefaultInput()?.device.id == resolved.device.id else {
            teardown(engine: engine, inputNode: inputNode, lifetime: lifetime, defaultInputChange: defaultInputChange, token: token)
            throw AudioEngineError.engineStartFailed("The microphone changed while recording started. Please try again.")
        }

        let firstBufferAt = gate.firstTapUptime ?? ProcessInfo.processInfo.systemUptime
        let session = Session(engine: engine, inputNode: inputNode, lifetime: lifetime, token: token, defaultInputChange: defaultInputChange)

        // Publishing is the same atomic step as re-checking that this start is still
        // wanted, so a stop racing the final commit cannot leave a live orphan engine.
        guard publish(session: session, device: resolved.device, token: token) else {
            teardown(session)
            throw CancellationError()
        }
        emitActiveDeviceChange(resolved.device)

        return CaptureStartInfo(
            device: resolved.device,
            hardwareSampleRate: observedFormat.sampleRate,
            hardwareChannels: observedFormat.channelCount,
            voiceProcessingActive: voiceProcessingActive,
            fellBackToSystemDefault: resolved.fellBackToSystemDefault,
            armedLatency: firstBufferAt - startedAt
        )
    }

    private func attemptInputOnlyStart(resolved: ResolvedDevice, token: UInt64,
                                       startedAt: TimeInterval) async throws -> CaptureStartInfo? {
        let lifetime = TapLifetime()
        guard attachArmingLifetime(lifetime, token: token) else { throw CancellationError() }
        let gate = ArmingGate()
        let throttle = LevelThrottle(interval: Self.meterInterval)
        let consumers = lock.withLock { (buffer: _onConvertedBuffer, level: _onLevel) }
        guard let format = AudioFormatConverter.canonicalOutputFormat else {
            throw AudioEngineError.deviceUnavailable
        }
        let converter = try AudioFormatConverter(inputFormat: format)
        let input = try InputOnlyCapture(deviceUID: resolved.device.id) { [weak self] pcm, host in
            guard let self, lifetime.acceptBuffer() else { return }
            defer { lifetime.completeBuffer() }
            gate.noteTapFired(at: ProcessInfo.processInfo.systemUptime)
            self.process(pcm, hostSeconds: host, converter: converter, throttle: throttle,
                         lifetime: lifetime, gate: gate, consumers: consumers)
        }
        let session = Session(inputOnly: input, lifetime: lifetime, token: token)
        do {
            try input.start()
            let window = resolved.device.transport == .bluetooth ? Self.bluetoothArmingWindow : Self.armingWindow
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                gate.signal(false)
            }
            let armed = await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.signal(false) }
            timeout.cancel()
            try checkStillWanted(token)
            guard armed else { teardown(session); return nil }
            guard publish(session: session, device: resolved.device, token: token) else { throw CancellationError() }
            emitActiveDeviceChange(resolved.device)
            return CaptureStartInfo(device: resolved.device, hardwareSampleRate: format.sampleRate,
                hardwareChannels: format.channelCount, voiceProcessingActive: false,
                fellBackToSystemDefault: resolved.fellBackToSystemDefault,
                armedLatency: (gate.firstTapUptime ?? ProcessInfo.processInfo.systemUptime) - startedAt)
        } catch {
            teardown(session)
            throw error
        }
    }

    // MARK: - Per-buffer path (audio queue only)

    private typealias Consumers = (
        buffer: ((AVAudioPCMBuffer) -> Void)?,
        level: ((Double, TimeInterval) -> Void)?
    )

    private func process(
        _ buffer: AVAudioPCMBuffer,
        hostSeconds: TimeInterval,
        converter: AudioFormatConverter,
        throttle: LevelThrottle,
        lifetime: TapLifetime,
        gate: ArmingGate,
        consumers: Consumers
    ) {
        guard lifetime.isValid else { return }

        let converted: AVAudioPCMBuffer?
        do {
            converted = try converter.convert(buffer)
        } catch {
            log.error("Buffer conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let converted, converted.frameLength > 0 else { return }

        // Audio has made it all the way through the chain: the start is genuinely armed.
        gate.signal(true)

        // The consumer was captured when this attempt installed its tap, so no engine
        // lock is taken here — see the lock-order note on `TapLifetime`.
        lifetime.withValid { consumers.buffer?(converted) }

        guard let emit = consumers.level,
              throttle.shouldEmit(at: hostSeconds),
              let channel = converted.floatChannelData?.pointee else {
            return
        }
        let level = normalizedRMS(
            samples: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        )
        emitLevel(level, at: hostSeconds, lifetime: lifetime, emit: emit)
    }

    // MARK: - Main-actor hops (the only two)

    /// A plain validity check rather than `withValid`: this runs on the main queue and
    /// the handler drives the whole silence policy, so holding the lifetime lock across
    /// it would let main-thread work block a teardown. The worst a raced sample can do
    /// is feed one stale meter reading into a fresh policy.
    private func emitLevel(
        _ level: Double,
        at hostSeconds: TimeInterval,
        lifetime: TapLifetime,
        emit: @escaping (Double, TimeInterval) -> Void
    ) {
        DispatchQueue.main.async {
            guard lifetime.isValid else { return }
            emit(level, hostSeconds)
        }
    }

    private func emitActiveDeviceChange(_ device: AudioInputDevice?) {
        DispatchQueue.main.async { [self] in
            lock.withLock { _onActiveDeviceChange }?(device)
        }
    }

    // MARK: - Device loss

    /// Runs on the device monitor's own serial queue, never on main.
    private func handleDeviceListChange(_ devices: [AudioInputDevice]) {
        guard let running = runningSessionIdentity(),
              (!devices.contains(where: { $0.id == running.device.id })
                || (lock.withLock { if case .running(_, let session) = state { return session.inputOnly == nil }; return false }
                    && deviceMonitor.systemDefaultInput()?.device.id != running.device.id)),
              // Claiming the session IS the exactly-once guard: it can only succeed for
              // this exact session, and it leaves the engine `.idle`.
              let session = claimRunningSession(token: running.token) else {
            return
        }
        log.notice("Active input \(running.device.name, privacy: .public) disappeared or the input route changed; stopping.")
        teardown(session)
        emitActiveDeviceChange(nil)
    }

    // MARK: - State machine (all lock-protected)

    private func beginStart() throws -> UInt64 {
        try lock.withLock {
            guard case .idle = state else {
                throw AudioEngineError.engineStartFailed("A recording is already active.")
            }
            nextToken &+= 1
            state = .starting(token: nextToken)
            startingLifetime = nil
            return nextToken
        }
    }

    /// Registers the arming attempt's tap so a stop can silence it at once. Returns
    /// false when this start has already been retired, in which case the caller tears
    /// the half-built attempt down.
    private func attachArmingLifetime(_ lifetime: TapLifetime, token: UInt64) -> Bool {
        lock.withLock {
            guard case .starting(let current) = state, current == token else { return false }
            startingLifetime = lifetime
            return true
        }
    }

    private func publish(
        session: Session,
        device: AudioInputDevice,
        token: UInt64
    ) -> Bool {
        lock.withLock {
            guard case .starting(let current) = state, current == token else { return false }
            state = .running(token: token, session: session)
            startingLifetime = nil          // the session owns the lifetime from here
            _activeDevice = device
            return true
        }
    }

    private func abandonStart(_ token: UInt64) {
        lock.withLock {
            guard case .starting(let current) = state, current == token else { return }
            state = .idle
            startingLifetime = nil
        }
    }

    /// Retires whatever is in flight — a running session *and/or* a start still arming
    /// or suspended at the permission prompt — and hands both back for teardown.
    private func claimForStop() -> (session: Session?, armingLifetime: TapLifetime?) {
        lock.withLock {
            var claimed: Session?
            if case .running(_, let session) = state { claimed = session }
            let arming = startingLifetime
            startingLifetime = nil
            state = .idle
            _activeDevice = nil
            return (claimed, arming)
        }
    }

    /// The live session's token and device, read together so a caller can act on a
    /// consistent pair.
    private func runningSessionIdentity() -> (token: UInt64, device: AudioInputDevice)? {
        lock.withLock {
            guard case .running(let token, _) = state, let device = _activeDevice else {
                return nil
            }
            return (token, device)
        }
    }

    /// Claims a live session only if it is still the exact one identified by `token`,
    /// leaving an in-flight start alone. Matching on the token rather than the device
    /// UID is what stops a stale unplug notification from tearing down a newer
    /// recording that happens to have reconnected the same device.
    private func claimRunningSession(token: UInt64) -> Session? {
        lock.withLock {
            guard case .running(let current, let session) = state, current == token else {
                return nil
            }
            state = .idle
            _activeDevice = nil
            return session
        }
    }

    private func checkStillWanted(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard lock.withLock({ state.token }) == token else {
            throw CancellationError()
        }
    }

    // MARK: - Teardown

    /// Ends a live recording without throwing away buffers the tap already accepted.
    ///
    /// `removeTap` stops future delivery, but AVFAudio can already be executing a tap
    /// block while it returns. `TapLifetime.stopAcceptingBuffers()` makes that race
    /// deterministic: a callback either joins the drain before the stop edge or is
    /// refused. The recorder is finalized only after every joined buffer has reached its
    /// consumer on `AudioQueue`.
    private func finish(_ session: Session) async {
        session.inputOnly?.stop()
        session.inputNode?.removeTap(onBus: 0)
        if let engine = session.engine, engine.isRunning { engine.stop() }
        session.lifetime.stopAcceptingBuffers()
        await session.lifetime.waitForAcceptedBuffers()
        session.lifetime.invalidate()
        restoreDefaultInput(session.defaultInputChange, token: session.token)
        if let engine = session.engine, let node = session.inputNode {
            deferRelease(of: engine, inputNode: node)
        }
    }

    private func teardown(_ session: Session) {
        if let input = session.inputOnly {
            session.lifetime.invalidate()
            input.stop()
            return
        }
        guard let engine = session.engine, let node = session.inputNode else { return }
        teardown(
            engine: engine,
            inputNode: node,
            lifetime: session.lifetime,
            defaultInputChange: session.defaultInputChange,
            token: session.token
        )
    }

    private func teardown(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        lifetime: TapLifetime,
        defaultInputChange: DefaultInputChange?,
        token: UInt64
    ) {
        // Invalidate first: buffers already queued on AudioQueue must not publish.
        lifetime.invalidate()
        inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        restoreDefaultInput(defaultInputChange, token: token)
        deferRelease(of: engine, inputNode: inputNode)
    }

    /// macOS 26 can leave `AVAudioIOUnit` property-listener blocks queued after
    /// `AVAudioEngine.stop()` returns. Releasing the engine immediately races those
    /// blocks and has produced repeatable `objc_msgSend` use-after-free crashes in
    /// `AVAudioIOUnit::IOUnitPropertyListener`. The framework exposes no queue to drain,
    /// so retain the stopped graph for one short grace period and release it on main.
    ///
    /// Explicitly disabling voice processing here used to rebuild the IO unit during
    /// teardown and create another property notification. Releasing the stopped engine
    /// already tears that private unit down; toggling it off first is unnecessary.
    private func deferRelease(of engine: AVAudioEngine, inputNode: AVAudioInputNode) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [engine, inputNode] in
            withExtendedLifetime((engine, inputNode)) {}
        }
    }

    // MARK: - Microphone selection

    /// Selects the microphone by making it the system default input for the duration of
    /// the recording, restoring the previous one on teardown.
    ///
    /// This is deliberately not an AUHAL pin. Setting
    /// `kAudioOutputUnitProperty_CurrentDevice` on AVAudioEngine's unit returns `noErr`
    /// and then delivers zero buffers — measured on real hardware against both a USB and
    /// the built-in microphone. A default-device change is the only selection mechanism
    /// that actually works here, and it has a useful side effect: because Captur never
    /// selects a Continuity input, macOS cannot quietly hand the recording to an iPhone.
    ///
    /// Nothing is touched when the wanted device is already the default, which is the
    /// common case.
    private func makeDeviceDefault(_ resolved: ResolvedDevice, token: UInt64) async throws -> DefaultInputChange? {
        guard let current = deviceMonitor.systemDefaultInput() else {
            throw AudioEngineError.deviceUnavailable
        }
        guard current.device.id != resolved.device.id else {
            return nil
        }
        guard !Self.pinningDisabled,
              deviceMonitor.setSystemDefaultInput(resolved.deviceID) else {
            throw AudioEngineError.engineStartFailed("Could not select \(resolved.device.name). Recording was stopped to avoid using another microphone.")
        }
        let change = DefaultInputChange(previousUID: current.device.id, selectedUID: resolved.device.id)
        // Confirm the requested default before AVAudioEngine binds to its input.
        // This bounded wait is used only during a device switch.
        do {
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 50_000_000)
                try checkStillWanted(token)
                if deviceMonitor.systemDefaultInput()?.device.id == resolved.device.id {
                    log.notice("Selected \(resolved.device.name, privacy: .public) as the input device.")
                    return change
                }
            }
            throw AudioEngineError.engineStartFailed("The selected microphone did not become available. Please reconnect it and try again.")
        } catch {
            restoreDefaultInput(change, token: token)
            throw error
        }
    }

    private func restoreDefaultInput(_ change: DefaultInputChange?, token: UInt64) {
        guard let change,
              // A retired attempt must not change a newer recording's route.
              lock.withLock({ state.token == nil || state.token == token }),
              deviceMonitor.systemDefaultInput()?.device.id == change.selectedUID else { return }
        deviceMonitor.refresh()
        // IDs can change when a headset reconnects. Restore by UID, and leave a
        // newer system/user choice untouched rather than restoring a vanished device.
        guard let previousID = deviceMonitor.deviceID(forUID: change.previousUID) else { return }
        deviceMonitor.setSystemDefaultInput(previousID)
    }

    // MARK: - Helpers

    /// Diagnostic escape hatch. Setting `kAudioOutputUnitProperty_CurrentDevice` on the
    /// engine's AUHAL retargets that unit for input *and* output; pointing it at an
    /// input-only device can leave the unit unable to initialize or unable to render.
    /// `CAPTUR_NO_PIN=1` skips pinning entirely so that hypothesis can be tested against
    /// real hardware rather than argued about.
    static let pinningDisabled = ProcessInfo.processInfo.environment["CAPTUR_NO_PIN"] == "1"

    private func pin(_ inputNode: AVAudioInputNode, to deviceID: AudioDeviceID) throws {
        if Self.pinningDisabled {
            log.notice("CAPTUR_NO_PIN=1 — skipping device pinning, using the system default input.")
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioEngineError.deviceUnavailable
        }

        // Accessing `engine.inputNode` instantiates AND initializes the AUHAL. Setting
        // kAudioOutputUnitProperty_CurrentDevice on an initialized unit returns noErr but
        // leaves it unable to render — which is precisely the dead microphone this app
        // shipped with: a pin that reported success and silently produced no buffers.
        // The device can only be retargeted while the unit is uninitialized.
        let wasInitialized = AudioUnitUninitialize(audioUnit) == noErr

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if wasInitialized {
            let reinitStatus = AudioUnitInitialize(audioUnit)
            guard reinitStatus == noErr else {
                log.error("Could not re-initialize the IO unit after pinning: \(reinitStatus)")
                throw AudioEngineError.deviceUnavailable
            }
        }

        guard status == noErr else {
            throw AudioEngineError.deviceUnavailable
        }
    }

    private func configureMinimumDucking(on inputNode: AVAudioInputNode) {
        var configuration = inputNode.voiceProcessingOtherAudioDuckingConfiguration
        configuration.enableAdvancedDucking = false
        configuration.duckingLevel = .min
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = configuration

        let applied = inputNode.voiceProcessingOtherAudioDuckingConfiguration
        if applied.duckingLevel != .min {
            log.notice("Ducking level stayed at \(applied.duckingLevel.rawValue); other audio may dip.")
        }
    }

    /// Cancellation-aware: the system prompt cannot be dismissed programmatically, so a
    /// cancelled start resolves the wait itself and lets the caller unwind. Whoever
    /// answers the prompt later finds the latch already settled. Without this, a
    /// key-up that cancels a start stays suspended behind an unanswered prompt and the
    /// app looks wedged.
    private func microphonePermissionGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let latch = OneShotLatch()
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else { return false }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    latch.resolve(granted)
                }
                return await latch.wait()
            } onCancel: {
                latch.resolve(false)
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - Tap lifetime

/// One per start attempt. Removing a tap does not drain the blocks it already handed to
/// `AudioQueue`, so every queued block re-checks this before publishing anything.
///
/// **Lock order:** never take the engine's lock while holding this one. Callers fetch
/// the consumer callback under the engine lock *first*, then invoke it inside
/// `withValid`. Getting that backwards would invert the order against
/// `claimSessionForStop`, which invalidates outside the engine lock for the same reason.
final class TapLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var acceptingBuffers = true
    private let acceptedBuffers = DispatchGroup()

    var isValid: Bool { lock.withLock { valid } }

    /// Registers one tap callback for the normal-stop drain. Registration and retiring
    /// are serialized by the same lock, so a callback cannot enter the dispatch group
    /// after `stopAcceptingBuffers()` has made an empty group observable.
    func acceptBuffer() -> Bool {
        lock.withLock {
            guard valid, acceptingBuffers else { return false }
            acceptedBuffers.enter()
            return true
        }
    }

    func completeBuffer() {
        acceptedBuffers.leave()
    }

    func stopAcceptingBuffers() {
        lock.withLock { acceptingBuffers = false }
    }

    func waitForAcceptedBuffers() async {
        await withCheckedContinuation { continuation in
            acceptedBuffers.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    /// Delivers `body` only while this attempt is live, serialized against
    /// `invalidate()` so teardown cannot slip in between the validity check and the
    /// delivery and route an abandoned attempt's audio into a newer recording.
    func withValid(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return }
        body()
    }

    /// Blocks until any in-flight `withValid` delivery has finished, so a returning
    /// teardown really does mean "no more buffers from this attempt".
    func invalidate() {
        lock.withLock {
            acceptingBuffers = false
            valid = false
        }
    }
}

// MARK: - One-shot latch

/// A boolean resolved exactly once, by whichever party gets there first, and awaited at
/// most once. Resumption always happens outside the lock, and a result that lands
/// before anybody waits is replayed rather than lost.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

// MARK: - Start guard

/// The arming latch: resolved either by the first converted buffer or by the arming
/// timeout, and carrying the timestamp of the very first raw tap callback.
private final class ArmingGate: @unchecked Sendable {
    private let latch = OneShotLatch()
    private let lock = NSLock()
    private var firstTap: TimeInterval?

    var firstTapUptime: TimeInterval? { lock.withLock { firstTap } }

    func noteTapFired(at uptime: TimeInterval) {
        lock.withLock {
            if firstTap == nil { firstTap = uptime }
        }
    }

    func signal(_ value: Bool) {
        latch.resolve(value)
    }

    func wait() async -> Bool {
        await latch.wait()
    }
}

// MARK: - Meter throttle

/// Audio-queue confined. Keeps the ~30 Hz meter cadence off the per-buffer rate so the
/// main actor sees at most one hop per frame of UI.
private final class LevelThrottle {
    private let interval: TimeInterval
    private var lastEmit: TimeInterval?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldEmit(at time: TimeInterval) -> Bool {
        guard let lastEmit else {
            self.lastEmit = time
            return true
        }
        guard time - lastEmit >= interval else { return false }
        self.lastEmit = time
        return true
    }
}

// MARK: - Buffer copying

extension AVAudioPCMBuffer {
    /// A buffer handed to a tap block is only valid for the duration of that block, so
    /// anything delivered onto another queue has to own its own frames.
    fileprivate func detachedCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        // Setting frameLength updates every mDataByteSize, so it must precede the copy.
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else {
                return nil
            }
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            memcpy(to, from, byteCount)
        }
        return copy
    }
}
