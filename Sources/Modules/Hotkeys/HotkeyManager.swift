import AppKit
import Carbon.HIToolbox

/// The hotkeys that exist only for the length of a capture, as a pure function of
/// the two facts that decide them. Extracted so the gating rule — the part that
/// breaks the user's keyboard if it is wrong — is unit-testable without Carbon.
///
/// Plain ⏎ is registered system-wide while a capture holds the microphone. That is
/// intended (spec §4.1: the user is dictating, not typing) and it is only safe
/// because it is transient: the moment the phase stops holding the microphone this
/// returns an empty map and the registration goes away.
enum CaptureTransients {

    /// Plain Esc, no modifiers.
    static let escape = KeyCombo(keyCode: 53, carbonModifiers: 0)
    /// Plain Return, no modifiers.
    static let returnKey = KeyCombo(keyCode: 36, carbonModifiers: 0)

    static func bindings(captureActive: Bool, suspended: Bool) -> [HotkeyAction: KeyCombo] {
        guard captureActive, !suspended else { return [:] }
        return [.cancelCapture: escape, .endCapture: returnKey]
    }
}

/// Pure decision helper for the Esc capture-cancel binding. Kept as the named rule
/// it has always been; it is now one entry of `CaptureTransients`.
enum EscGate {
    /// Esc→cancelCapture is registered only while a capture is active *and* the
    /// manager is not suspended (Settings recorder open).
    static func shouldRegisterEsc(captureActive: Bool, suspended: Bool) -> Bool {
        CaptureTransients.bindings(captureActive: captureActive, suspended: suspended)[.cancelCapture] != nil
    }
}

/// One registered hotkey, as an opaque handle.
///
/// A class holding a Carbon ref rather than the ref itself, so a test registrar can
/// hand back a handle without manufacturing an `EventHotKeyRef` it would then have to
/// keep away from Carbon's real functions.
final class CarbonHotkeyHandle {
    let ref: EventHotKeyRef?
    init(ref: EventHotKeyRef?) { self.ref = ref }
}

/// Carbon's global hotkey table, behind a seam.
///
/// It exists because the registration path is where this file kept its only real
/// defect — a refused `OSStatus` discarded, so `apply` could never throw and the
/// Settings recorder's revert-and-explain path could never fire — and that path cannot
/// be tested against real Carbon: a test would have to genuinely occupy ⌘Space
/// system-wide to observe a refusal.
protocol CarbonHotkeyRegistering: AnyObject {
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  signature: OSType,
                  id: UInt32) -> Result<CarbonHotkeyHandle, HotkeyError>
    func unregister(_ handle: CarbonHotkeyHandle)
}

/// The production registrar. The only place in the app that talks to
/// `RegisterEventHotKey`.
final class CarbonHotkeyRegistrar: CarbonHotkeyRegistering {
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  signature: OSType,
                  id: UInt32) -> Result<CarbonHotkeyHandle, HotkeyError> {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return .failure(.registrationFailed(status)) }
        return .success(CarbonHotkeyHandle(ref: ref))
    }

    func unregister(_ handle: CarbonHotkeyHandle) {
        if let ref = handle.ref { UnregisterEventHotKey(ref) }
    }
}

/// T7. System-wide hotkeys via Carbon `RegisterEventHotKey` for the rebindable
/// combos + Esc, plus an `NSEvent.flagsChanged` monitor pair for the modifier-only
/// push-to-talk key. All `onAction` callbacks fire on the main actor.
@MainActor
final class HotkeyManager: HotkeyManaging, ModeDigitHotkeyRegistering {
    var onAction: ((HotkeyAction) -> Void)?

    /// How a registration failure reaches the user when there is no `throws` to carry
    /// it: the capture-scoped transients (Esc, ⏎) are registered by a phase change, and
    /// a deferred binding is registered by `resume()`, neither of which any caller is
    /// in a position to `try`. Swallowing those was the second half of the same defect
    /// — a capture nobody could cancel with nothing on screen to explain why.
    var onRegistrationFailure: ((HotkeyAction, HotkeyError) -> Void)?

    // MARK: State

    private var bindings: HotkeyBindings = .default
    private var captureActive = false
    private var suspended = false

    // MARK: Carbon registrations

    private struct Registration {
        let handle: CarbonHotkeyHandle
        let action: HotkeyAction
    }

    private struct TransientRegistration {
        let id: UInt32
        let handle: CarbonHotkeyHandle
        let combo: KeyCombo
    }

    private static let signature: OSType = 0x51434D4B // 'QCMK'
    private var comboRegs: [UInt32: Registration] = [:]   // hotkey id → registration

    /// What *should* be registered right now — including while suspended, so
    /// `resume()` can put back exactly what `suspend()` took away.
    private var desiredTransients: [HotkeyAction: KeyCombo] = [:]
    /// What Carbon is actually holding. The two are reconciled by `syncTransients`,
    /// which is the single place a transient can be created or destroyed.
    private var liveTransients: [HotkeyAction: TransientRegistration] = [:]

    /// The 1–9 mode switch (spec §4.1). Same desired/live split as the transients
    /// above, for the same reason: `suspend()` has to be able to give a digit back to
    /// the Settings recorder and `resume()` has to be able to take it again.
    private var desiredModeDigits: [ModeDigitBinding] = []
    private var liveModeDigits: [UInt32: CarbonHotkeyHandle] = [:]   // hotkey id → handle
    private var modeDigitsByHotKeyID: [UInt32: Int] = [:]            // hotkey id → digit
    private var modeDigitHandler: ((Int) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var nextHotKeyID: UInt32 = 1

    // MARK: Push-to-talk

    private var detector = PushToTalkDetector(key: .disabled)
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// The Carbon registration for a CHORD push-to-talk binding, and the only hotkey in
    /// this file that acts on both edges. Kept apart from `comboRegs` because that map is
    /// press-only by design.
    private var pttChordReg: (id: UInt32, handle: CarbonHotkeyHandle)?
    private var holdWatchdog: Task<Void, Never>?

    private let registrar: any CarbonHotkeyRegistering

    /// Non-nil only while a `resume()` is replaying bindings that were deferred by a
    /// `suspend()`, so the verdict can be reported rather than dropped.
    private var deferredFailure: (HotkeyAction, HotkeyError)?

    init(registrar: any CarbonHotkeyRegistering = CarbonHotkeyRegistrar()) {
        self.registrar = registrar
    }

    /// Lets one test assert that the seam did not quietly change what ships.
    var registrarIsCarbon: Bool { registrar is CarbonHotkeyRegistrar }

    deinit {
        // Best-effort synchronous teardown (deinit is nonisolated). The transient
        // sweep matters most: a leaked plain-Return registration would leave the
        // machine's Return key swallowed.
        if let eventHandler { RemoveEventHandler(eventHandler) }
        for reg in comboRegs.values { registrar.unregister(reg.handle) }
        for reg in liveTransients.values { registrar.unregister(reg.handle) }
        for handle in liveModeDigits.values { registrar.unregister(handle) }
        if let chord = pttChordReg { registrar.unregister(chord.handle) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        holdWatchdog?.cancel()
    }

    // MARK: HotkeyManaging

    func apply(_ bindings: HotkeyBindings) throws {
        self.bindings = bindings
        guard !suspended else { return }   // deferred until resume(), which reports
        activate()
        // Every binding is attempted before the first refusal is thrown: a conflict on
        // one shortcut must not cost the user the others.
        if let (_, error) = deferredFailure {
            deferredFailure = nil
            throw error
        }
    }

    /// The teardown guarantee for ⏎ and Esc. `AppComposition.observePhase` calls this
    /// on **every** phase change with `phase.holdsMicrophone`, so the moment a capture
    /// stops owning the microphone — by any route, including a failure — the
    /// capture-scoped registrations go away.
    func setCaptureActive(_ active: Bool) {
        captureActive = active
        let wanted = CaptureTransients.bindings(captureActive: active, suspended: false)
        for action in [HotkeyAction.cancelCapture, .endCapture] {
            desiredTransients[action] = wanted[action]
        }
        syncTransients()
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        teardownCombos()
        syncTransients()          // drops every live transient, keeps what is desired
        try? syncModeDigits()     // likewise: a suspended manager holds no digits
        teardownPushToTalk()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        activate()
        // `resume()` cannot throw, and the bindings it is replaying may include one a
        // suspended `apply` never got a Carbon verdict on. Report it rather than let a
        // shortcut the system already owns look accepted.
        if let (action, error) = deferredFailure {
            deferredFailure = nil
            onRegistrationFailure?(action, error)
        }
    }

    /// Registers a hotkey that exists only while some state is on screen. Unlike a
    /// global `NSEvent` monitor, a Carbon hotkey CONSUMES the keystroke, which is the
    /// whole point: ⌘R must not also reach whatever app is frontmost.
    func registerTransient(_ combo: KeyCombo, action: HotkeyAction) throws {
        desiredTransients[action] = combo
        guard !suspended else { return }   // deferred until resume()

        if let live = liveTransients[action] {
            guard live.combo != combo else { return }
            registrar.unregister(live.handle)
            liveTransients[action] = nil
        }
        installHandlerIfNeeded()
        switch carbonRegister(combo) {
        case .success(let registration):
            liveTransients[action] = registration
        case .failure(let error):
            desiredTransients[action] = nil
            throw error
        }
    }

    func unregisterTransient(_ action: HotkeyAction) {
        desiredTransients[action] = nil
        syncTransients()
    }

    // MARK: Mode digits (1–9)

    /// Kept apart from `liveTransients` rather than folded into it: that map is keyed
    /// by `HotkeyAction`, one combo per case, and this is up to eighteen registrations
    /// that all mean the same action with a different argument.
    func registerModeDigits(_ bindings: [ModeDigitBinding],
                            onDigit: @escaping (Int) -> Void) throws {
        desiredModeDigits = bindings
        modeDigitHandler = onDigit
        guard !suspended else { return }   // deferred until resume()
        try syncModeDigits()
    }

    func unregisterModeDigits() {
        desiredModeDigits = []
        modeDigitHandler = nil
        try? syncModeDigits()   // an empty desired set cannot refuse anything
    }

    /// Reconciles Carbon against `desiredModeDigits`, which a suspended manager
    /// treats as empty.
    ///
    /// Torn down and rebuilt wholesale rather than diffed. The set changes at most
    /// twice per dictation, and a diff over eighteen entries would be a second place
    /// for a plain digit to be left behind — which is the failure that stops the
    /// user's number keys working everywhere on the machine.
    @discardableResult
    private func syncModeDigits() throws -> Int {
        for handle in liveModeDigits.values { registrar.unregister(handle) }
        liveModeDigits.removeAll()
        modeDigitsByHotKeyID.removeAll()

        let wanted = suspended ? [] : desiredModeDigits
        guard !wanted.isEmpty else { return 0 }
        installHandlerIfNeeded()

        // Every combo is attempted before the first refusal is raised: one occupied
        // digit must cost the user that digit, not the other eight.
        var refusal: ModeDigitRefusal?
        for binding in wanted {
            let id = nextHotKeyID
            nextHotKeyID += 1
            switch registrar.register(keyCode: binding.combo.keyCode,
                                      modifiers: binding.combo.carbonModifiers,
                                      signature: Self.signature,
                                      id: id) {
            case .success(let handle):
                liveModeDigits[id] = handle
                modeDigitsByHotKeyID[id] = binding.digit
            case .failure(let error):
                if refusal == nil {
                    refusal = ModeDigitRefusal(digit: binding.digit, underlying: error)
                }
            }
        }

        if let refusal { throw refusal }
        return liveModeDigits.count
    }

    // MARK: Activation

    private func activate() {
        rebuildCombos()
        syncTransients()
        // A refusal here has no caller to `try`; `resume()` reports the deferred
        // combo failure and the digits are a best-effort convenience beside it.
        try? syncModeDigits()
        rebuildPushToTalk()
    }

    // MARK: Combos

    private func rebuildCombos() {
        teardownCombos()
        installHandlerIfNeeded()
        register(bindings.toggleDictation, action: .toggleDictation)
        register(bindings.toggleThought, action: .toggleThought)
        register(bindings.showHistoryPalette, action: .showHistoryPalette)
    }

    private func register(_ combo: KeyCombo?, action: HotkeyAction) {
        guard let combo else { return }   // nil combos are skipped
        let id = nextHotKeyID
        nextHotKeyID += 1
        switch registrar.register(keyCode: combo.keyCode,
                                  modifiers: combo.carbonModifiers,
                                  signature: Self.signature,
                                  id: id) {
        case .success(let handle):
            comboRegs[id] = Registration(handle: handle, action: action)
        case .failure(let error):
            // First refusal wins: it is the one the user is most likely to have just
            // typed, and reporting a later one would name the wrong shortcut.
            if deferredFailure == nil { deferredFailure = (action, error) }
        }
    }

    private func teardownCombos() {
        for reg in comboRegs.values { registrar.unregister(reg.handle) }
        comboRegs.removeAll()
    }

    // MARK: Transients (Esc, ⏎, ⌘R)

    /// The one place a transient is created or destroyed. Reconciles Carbon against
    /// `desiredTransients`, which a suspended manager treats as empty.
    private func syncTransients() {
        let wanted = suspended ? [:] : desiredTransients

        for action in Array(liveTransients.keys) where wanted[action] != liveTransients[action]?.combo {
            if let live = liveTransients[action] { registrar.unregister(live.handle) }
            liveTransients[action] = nil
        }
        for (action, combo) in wanted where liveTransients[action] == nil {
            installHandlerIfNeeded()
            switch carbonRegister(combo) {
            case .success(let registration):
                liveTransients[action] = registration
            case .failure(let error):
                // Nobody is in a position to `try` this — a phase change registered it.
                // Reported rather than dropped: Esc cancels a live capture, and a
                // capture that cannot be cancelled must not also be a silent one.
                onRegistrationFailure?(action, error)
            }
        }
    }

    private func carbonRegister(_ combo: KeyCombo) -> Result<TransientRegistration, HotkeyError> {
        let id = nextHotKeyID
        nextHotKeyID += 1
        switch registrar.register(keyCode: combo.keyCode,
                                  modifiers: combo.carbonModifiers,
                                  signature: Self.signature,
                                  id: id) {
        case .success(let handle):
            return .success(TransientRegistration(id: id, handle: handle, combo: combo))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: Carbon event handler

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        // BOTH kinds. The release edge exists solely for a chord push-to-talk binding;
        // every other hotkey in the app is press-only and `handleHotKey` drops their
        // releases on the floor. Measured before it was relied on: see
        // `HotkeyReleaseProbe` — the release fires on the KEY, so letting go of ⌘ or ⇧
        // first does not lose it.
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventCallback,
            2,
            &specs,
            selfPtr,
            &eventHandler
        )
    }

    /// Dispatched from the Carbon callback on the main thread.
    ///
    /// `released` is meaningful for exactly one registration — the push-to-talk chord,
    /// which is the only hotkey that means two different things on the two edges. For
    /// everything else a release is discarded: a toggle that fired on both edges would
    /// start a recording and immediately stop it.
    ///
    /// Internal rather than `fileprivate` so that rule can be tested. It decides whether a
    /// keystroke starts or stops a recording, and the alternative is verifying it by hand
    /// on a real keyboard every time this file changes.
    func handleHotKey(id: UInt32, released: Bool) {
        if let chord = pttChordReg, chord.id == id {
            if released {
                cancelHoldWatchdog()
                onAction?(.pushToTalkUp)
            } else {
                startHoldWatchdog()
                onAction?(.pushToTalkDown)
            }
            return
        }

        guard !released else { return }

        if let reg = comboRegs[id] {
            onAction?(reg.action)
        } else if let action = liveTransients.first(where: { $0.value.id == id })?.key {
            onAction?(action)
        } else if let digit = modeDigitsByHotKeyID[id] {
            modeDigitHandler?(digit)
        }
    }

    // MARK: Push-to-talk monitors

    /// Installs whichever of the two push-to-talk mechanisms the binding asks for, and
    /// never both: a chord gets a Carbon registration, a bare modifier gets the flags
    /// monitors, and `.disabled` gets neither.
    private func rebuildPushToTalk() {
        teardownPushToTalk()
        let binding = bindings.pushToTalk.normalized
        detector = PushToTalkDetector(binding: binding)

        if let combo = binding.chordCombo {
            installHandlerIfNeeded()
            let id = nextHotKeyID
            nextHotKeyID += 1
            switch registrar.register(keyCode: combo.keyCode,
                                      modifiers: combo.carbonModifiers,
                                      signature: Self.signature,
                                      id: id) {
            case .success(let handle):
                pttChordReg = (id: id, handle: handle)
            case .failure(let error):
                // Same rule as the other combos: a refusal is carried to whoever can
                // report it rather than leaving a picker that looks set and does nothing.
                if deferredFailure == nil { deferredFailure = (.pushToTalkDown, error) }
            }
            return
        }

        guard binding.modifierKey != .disabled else { return }

        // Global monitor requires Accessibility trust; when untrusted AppKit
        // returns nil (no crash) and the Carbon combos keep working. The local
        // monitor covers events delivered to our own (rare) key window.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        switch detector.process(keyCode: event.keyCode, flags: event.modifierFlags) {
        case .down: onAction?(.pushToTalkDown)
        case .up:   onAction?(.pushToTalkUp)
        case .none: break
        }
    }

    private func teardownPushToTalk() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let chord = pttChordReg { registrar.unregister(chord.handle) }
        pttChordReg = nil
        cancelHoldWatchdog()
    }

    // MARK: The missed-release watchdog

    /// Rescues a hold whose release edge never arrives.
    ///
    /// `--probe-hotkey-release` measured the ordering trap away — the release fires on the
    /// key even when ⌘ and ⇧ are let go half a second earlier — so this is not covering
    /// the case that motivated the probe. It covers the ones a probe cannot rule out: the
    /// app losing the event to a switch, a lock, or a Carbon hiccup. Without it, a lost
    /// release leaves `PushToTalkLatch` stuck in `.held`, which means a live microphone
    /// AND a dead push-to-talk key, because the next press is filtered as flag noise.
    ///
    /// It is deliberately NOT a maximum recording length. Latched recordings never arm it
    /// (they end on the up edge), and the interval is far past any real hold, so the only
    /// thing it can end is a hold that is no longer happening. If it ever fires during a
    /// genuine hold, that is a bug in this file, not a limit the user hit.
    static let holdWatchdogInterval: TimeInterval = 120

    private func startHoldWatchdog() {
        cancelHoldWatchdog()
        holdWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdWatchdogInterval))
            guard !Task.isCancelled, let self else { return }
            self.holdWatchdog = nil
            // Idempotent by construction: if the real release lands later, the latch is
            // already idle and `up` returns `.none`.
            self.onAction?(.pushToTalkUp)
        }
    }

    private func cancelHoldWatchdog() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
    }
}

// MARK: - Carbon C callback

/// Free function so it converts cleanly to an `EventHandlerUPP` C pointer.
/// Carbon dispatches hotkey events on the main run loop / main thread, so the
/// hop into the MainActor-isolated manager is a safe `assumeIsolated`.
private func hotKeyEventCallback(
    _ callRef: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let eventRef, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    let released = GetEventKind(eventRef) == UInt32(kEventHotKeyReleased)
    MainActor.assumeIsolated {
        manager.handleHotKey(id: id, released: released)
    }
    return noErr
}
