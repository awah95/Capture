import AVFoundation
import Foundation

// MARK: Audio

enum AudioTransport: String, Sendable { case builtIn, usb, bluetooth, continuity, virtual, other }

struct AudioInputDevice: Equatable, Sendable, Identifiable {
    let id: String                 // CoreAudio device UID
    let name: String
    let transport: AudioTransport
    var isContinuityDevice: Bool   // true for iPhone/Continuity inputs
}

struct MicSelectionPolicy: Codable, Equatable, Sendable {
    var preferredDeviceUIDs: [String]     // ordered allowlist; empty enables automatic selection
    var excludeContinuityInputs: Bool     // default true
    static let `default` = MicSelectionPolicy(preferredDeviceUIDs: [], excludeContinuityInputs: true)
}

/// Retained for callers that still describe a finished audio file. The engine no
/// longer produces one — whoever consumes converted buffers owns the output.
struct RecordingResult: Equatable, Sendable {
    let fileURL: URL
    let duration: TimeInterval
}

/// Everything the engine could observe about a capture the moment it went live.
/// Diagnostics reads this; it is the only honest record of what the hardware actually
/// negotiated, as opposed to what was requested.
struct CaptureStartInfo: Equatable, Sendable {
    let device: AudioInputDevice
    let hardwareSampleRate: Double
    let hardwareChannels: UInt32
    let voiceProcessingActive: Bool
    let fellBackToSystemDefault: Bool
    /// `startRecording()` entry → the first buffer actually observed at the tap.
    let armedLatency: TimeInterval
}

enum AudioEngineError: Error, Equatable {
    case permissionDenied, deviceUnavailable
    case engineStartFailed(String), notRecording, fileFinalizationFailed(String)
}

extension AudioEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission was denied."
        case .deviceUnavailable: return "The selected microphone is unavailable."
        case .engineStartFailed(let reason), .fileFinalizationFailed(let reason): return reason
        case .notRecording: return "No recording is active."
        }
    }
}

/// T5. AVAudioEngine capture with voice processing (AEC), device pinning, metering.
///
/// Deliberately **not** `@MainActor`. Per-buffer work (tap, conversion, level maths)
/// runs on `AudioQueue.queue`; exactly two things hop to main — the throttled meter
/// level and the active-device-change notification. Levels are normalized linear
/// amplitude 0...1 (RMS of the converted mono buffer).
protocol AudioEngineControlling: AnyObject {
    /// MAIN actor, throttled to ~30 Hz. (level, hostTimeSeconds)
    var onLevel: ((Double, TimeInterval) -> Void)? { get set }
    /// MAIN actor. nil = the active input was lost.
    var onActiveDeviceChange: ((AudioInputDevice?) -> Void)? { get set }
    /// AUDIO QUEUE, once per captured buffer, already 16 kHz mono float32.
    var onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var activeDevice: AudioInputDevice? { get }
    var isRecording: Bool { get }
    func availableInputDevices() -> [AudioInputDevice]
    func startRecording(policy: MicSelectionPolicy, voiceProcessing: Bool) async throws -> CaptureStartInfo
    func stopRecording() async
    func cancelRecording() async
}

// MARK: Hotkeys

enum HotkeyAction: String, CaseIterable, Sendable {
    case pushToTalkDown, pushToTalkUp
    case toggleDictation, toggleThought, showHistoryPalette, cancelCapture
    /// ⏎ while a capture holds the microphone. Spec §4.1: a latched recording ends
    /// when you tap again *or* press Return.
    case endCapture
    /// ⌘R while a retryable error capsule is on screen (spec §9).
    case retryLast
}

enum HotkeyError: Error, Equatable {
    /// Carbon refused the combo — almost always because something else owns it.
    case registrationFailed(OSStatus)
}

enum PushToTalkKey: String, Codable, CaseIterable, Sendable { case rightOption, rightCommand, fnGlobe, disabled }

struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32          // Carbon virtual keycode
    var carbonModifiers: UInt32  // cmdKey/optionKey/controlKey/shiftKey bitmask
}

/// What push-to-talk is bound to. Two cases because there are genuinely two mechanisms,
/// and neither can do the other's job:
///
/// - `.modifier` — a bare modifier key (Right ⌥ and friends). Down/up edges come from
///   `NSEvent.flagsChanged`, because a bare modifier **cannot** be a Carbon hotkey:
///   `RegisterEventHotKey` needs a key, and a modifier on its own is not one.
/// - `.chord` — ⌘⇧D and the like, via `RegisterEventHotKey`. Its up edge is Carbon's
///   `kEventHotKeyReleased`, which was *measured* before this case was added — including
///   the case that decides whether it is safe, releasing the modifiers before the key
///   (`--probe-hotkey-release`, 2026-07-26: the release fires on the key, 523 ms after
///   the modifiers dropped). A chord is also *consumed*, unlike a flags monitor, so
///   dictating with ⌘⇧D does not also fire whatever ⌘⇧D means in the front app.
///
/// Exactly one is live at a time. `.disabled` is its own case rather than
/// `.modifier(.disabled)`; `normalized` collapses the latter into the former so two
/// spellings of "off" can never both exist.
enum PushToTalkBinding: Equatable, Sendable {
    case modifier(PushToTalkKey)
    case chord(KeyCombo)
    case disabled

    /// The one canonical spelling. `.modifier(.disabled)` is representable — the picker
    /// and the decoder can both produce it — and it means the same thing as `.disabled`,
    /// so it is folded here rather than compared for at every use site.
    var normalized: PushToTalkBinding {
        if case .modifier(.disabled) = self { return .disabled }
        return self
    }

    /// The modifier key the `flagsChanged` detector should watch — `.disabled` for a
    /// chord binding, because the detector must be inert while Carbon owns the edges.
    var modifierKey: PushToTalkKey {
        if case .modifier(let key) = normalized { return key }
        return .disabled
    }

    /// The combo to register with Carbon, or nil when this binding is not a chord.
    var chordCombo: KeyCombo? {
        if case .chord(let combo) = normalized { return combo }
        return nil
    }
}

/// Readable, stable JSON — `{"kind":"chord","combo":{…}}` rather than the compiler's
/// synthesized `{"chord":{"_0":{…}}}` — and, more importantly, a decoder that still
/// accepts the shape this key was stored in before chords existed: a bare string,
/// `"pushToTalk":"rightOption"`.
///
/// That legacy path is not politeness. `AppSettings` decodes with `try?` and falls back
/// to `HotkeyBindings.default`, so a decode failure here would silently reset **every**
/// shortcut the user had customized, with nothing printed. Pinned by
/// `HotkeyBindingsMigrationTests`.
extension PushToTalkBinding: Codable {
    private enum CodingKeys: String, CodingKey { case kind, key, combo }
    private enum Kind: String, Codable { case modifier, chord, disabled }

    init(from decoder: Decoder) throws {
        // Legacy: the whole value was a PushToTalkKey raw string.
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            guard let key = PushToTalkKey(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: single, debugDescription: "unknown push-to-talk key \"\(raw)\"")
            }
            self = PushToTalkBinding.modifier(key).normalized
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .modifier:
            let key = try container.decode(PushToTalkKey.self, forKey: .key)
            self = PushToTalkBinding.modifier(key).normalized
        case .chord:
            self = .chord(try container.decode(KeyCombo.self, forKey: .combo))
        case .disabled:
            self = .disabled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch normalized {
        case .modifier(let key):
            try container.encode(Kind.modifier, forKey: .kind)
            try container.encode(key, forKey: .key)
        case .chord(let combo):
            try container.encode(Kind.chord, forKey: .kind)
            try container.encode(combo, forKey: .combo)
        case .disabled:
            try container.encode(Kind.disabled, forKey: .kind)
        }
    }
}

struct HotkeyBindings: Codable, Equatable, Sendable {
    var pushToTalk: PushToTalkBinding         // .modifier(.rightOption)
    var toggleDictation: KeyCombo?            // ⌥Space
    var toggleThought: KeyCombo?              // ⌥⇧Space
    var showHistoryPalette: KeyCombo?         // ⌃⌥Space
    static let `default` = HotkeyBindings(
        pushToTalk: .modifier(.rightOption),
        toggleDictation: KeyCombo(keyCode: 49, carbonModifiers: 0x0800),
        toggleThought: KeyCombo(keyCode: 49, carbonModifiers: 0x0A00),
        showHistoryPalette: KeyCombo(keyCode: 49, carbonModifiers: 0x1800))

    /// Every combo this binding set asks Carbon for, labelled — the input to the conflict
    /// check. Push-to-talk is in here only when it is a chord, which is exactly when it
    /// can collide with a toggle.
    var registeredCombos: [(label: String, combo: KeyCombo)] {
        var result: [(label: String, combo: KeyCombo)] = []
        if let combo = pushToTalk.chordCombo { result.append(("Push-to-talk", combo)) }
        if let combo = toggleDictation { result.append(("Start / stop dictation", combo)) }
        if let combo = toggleThought { result.append(("Capture a thought", combo)) }
        if let combo = showHistoryPalette { result.append(("Show history", combo)) }
        return result
    }

    /// The label already using `combo`, ignoring `slot`'s own current value.
    ///
    /// Without this, binding ⌘⇧D to push-to-talk while it is still the dictation toggle
    /// registers the same chord twice and every press fires both actions — a recording
    /// that starts and immediately toggles itself off.
    func conflict(with combo: KeyCombo, excluding slot: String) -> String? {
        registeredCombos.first { $0.combo == combo && $0.label != slot }?.label
    }
}

/// T7. Carbon RegisterEventHotKey for combos + NSEvent flagsChanged monitor for the
/// push-to-talk modifier (down/up). Esc→cancelCapture and ⏎→endCapture are only
/// registered while capturing.
///
/// The transient pair is a protocol *requirement* rather than an extension because
/// the registration it hands out is Carbon state, and a protocol extension cannot
/// hold any.
@MainActor protocol HotkeyManaging: AnyObject {
    var onAction: ((HotkeyAction) -> Void)? { get set }
    func apply(_ bindings: HotkeyBindings) throws
    /// Gates the capture-scoped bindings (Esc, ⏎).
    func setCaptureActive(_ active: Bool)
    func suspend()
    func resume()
    /// Registers a Carbon hotkey that exists only while a state is on screen, and
    /// CONSUMES the keystroke (a global NSEvent monitor cannot).
    func registerTransient(_ combo: KeyCombo, action: HotkeyAction) throws
    func unregisterTransient(_ action: HotkeyAction)
}

// MARK: Insertion

enum InsertionOutcome: Equatable, Sendable {
    case insertedDirect                      // AX value/selected-text insertion
    case pastedViaKeyboard                   // CGEvent ⌘V with clipboard save/restore
    case clipboardFallback(reason: String)   // marked payload left on clipboard
    case refusedSecureField                  // §8: nothing inserted, nothing copied
}

/// T6. Also owns the macOS port of ClipboardPublisher (marked NSPasteboard payload,
/// changeCount guard, expiry — port Reference/iOS/Shared/ClipboardPublisher.swift).
@MainActor protocol TextInserting: AnyObject {
    func hasAccessibilityPermission() -> Bool
    func requestAccessibilityPermission()
    func frontmostAppBundleID() -> String?
    /// The frontmost app's display name, captured at the same moment as its bundle id.
    /// Recorded rather than derived later, because the honest answer to "what was this
    /// dictated into" is what the app called itself at the time.
    func frontmostAppName() -> String?
    func insert(_ text: String) async -> InsertionOutcome
    func insertSelectionEdit(_ text: String, originalSelection: String, targetBundleID: String?) async -> InsertionOutcome
}

extension TextInserting {
    func insertSelectionEdit(_ text: String, originalSelection: String, targetBundleID: String?) async -> InsertionOutcome {
        await insert(text)
    }
}

// MARK: Open Brain

struct OpenBrainConfig: Equatable, Sendable {
    var endpoint: URL          // https://<ref>.supabase.co/functions/v1/open-brain-rest
    var brainKey: String       // sent as x-brain-key header
}

struct OpenBrainCapturePayload: Codable, Equatable, Sendable {
    var content: String
    var type: String?          // e.g. "thought", "task"
    var source_type: String?   // "quickcapture-mac"
    var metadata: [String: String]?
}

enum OpenBrainError: Error, Equatable {
    case notConfigured, offline
    case http(status: Int, message: String)
    case invalidResponse
}

/// T8. POST {endpoint}/capture, JSON body = payload, header x-brain-key.
/// 2xx → returns created thought id (response "thought"."id" / "id"). Non-2xx → .http.
protocol OpenBrainCapturing: Sendable {
    func capture(_ payload: OpenBrainCapturePayload, config: OpenBrainConfig) async throws -> String
}

// MARK: Transcription (same shape as iOS donor)

protocol GroqTransporting: Sendable {
    func transcribeAudio(fileURL: URL, apiKey: String, prompt: String?) async throws -> String
}
