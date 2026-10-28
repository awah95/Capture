import Foundation
import Observation

// MARK: - The draft

/// One mode, unpacked for editing.
///
/// The editor works on a draft rather than mutating the store as the user types,
/// for two reasons that both cost the user something if ignored: a half-typed
/// temperature or a blank name would be persisted mid-keystroke, and a hotkey
/// would be claimed before anyone had checked whether something else owns it.
/// `save()` is the only door into `ModeStore`.
struct ModeDraft: Equatable {
    var id: String
    var name: String
    var symbol: String
    /// Carried, never edited. `ModeStore` refuses to change it anyway; keeping it
    /// here means `mode` reconstitutes the real thing rather than a lookalike.
    var isBuiltIn: Bool
    var usesLLM: Bool
    var systemPrompt: String
    var cleanupChoice: ModeCleanupChoice
    var refinementProvider: RefinementProviderID
    var model: String
    var reasoningEffort: ReasoningEffort
    var temperature: Double
    var includeClipboardContext: Bool
    var contextOptions: ModeContextOptions
    var includeAppNameContext: Bool
    /// nil = follow the global auto-paste setting. Not the same as `false`, which is
    /// "this mode never auto-pastes" — see `NullableOverride` in `ModeStore`.
    var autoPaste: Bool?
    var hotkey: KeyCombo?

    init(mode: Mode) {
        id = mode.id
        name = mode.name
        symbol = mode.symbol
        isBuiltIn = mode.isBuiltIn
        usesLLM = mode.usesLLM
        systemPrompt = mode.systemPrompt
        cleanupChoice = mode.cleanupChoice
        refinementProvider = mode.refinementProvider
        model = mode.model
        reasoningEffort = mode.reasoningEffort
        temperature = mode.temperature
        includeClipboardContext = mode.includeClipboardContext
        includeAppNameContext = mode.includeAppNameContext
        contextOptions = mode.contextOptions
        autoPaste = mode.autoPaste
        hotkey = mode.hotkey
    }

    var mode: Mode {
        Mode(id: id,
             name: name,
             symbol: symbol,
             isBuiltIn: isBuiltIn,
             usesLLM: usesLLM,
             systemPrompt: systemPrompt,
             cleanupChoice: cleanupChoice,
             refinementProvider: refinementProvider,
             model: model,
             reasoningEffort: reasoningEffort,
             temperature: temperature,
             includeClipboardContext: includeClipboardContext,
             includeAppNameContext: includeAppNameContext,
             contextOptions: contextOptions,
             autoPaste: autoPaste,
             hotkey: hotkey)
    }

    /// The draft as it would be stored: user-visible text trimmed, so a trailing
    /// space in a model id cannot fail a dictation an hour later.
    var normalized: ModeDraft {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

// MARK: - Conflicts

/// Why a keystroke cannot be given to a mode.
///
/// Named `ModeHotkeyConflict` rather than `HotkeyConflict` because the global
/// shortcut recorder (Task 25) is a separate surface with its own rules; the two
/// must not be confused for one type.
enum ModeHotkeyConflict: Equatable {
    /// Another mode already owns it. Two modes cannot share one keystroke.
    case otherMode(id: String, name: String)
    /// One of the always-on bindings from `HotkeyBindings`.
    case globalBinding(String)
    /// One of the bindings that exists only while a capture is on screen: Esc, ⏎,
    /// ⌘R, and the 1–9 mode switch (spec §4.1).
    case captureBinding(String)
    /// A Carbon hotkey with no modifiers is registered system-wide, so it would
    /// swallow that key in every app on the Mac.
    case needsModifier
}

// MARK: - Validation

/// What is wrong with a draft. Everything blocks the save except an unrecognised
/// model id, which is a warning by design — spec §6.2 resolves an unknown model at
/// launch and warns rather than failing a dictation over it, and the editor must
/// not be stricter than the thing it configures.
enum ModeValidationIssue: Equatable {
    case nameEmpty
    case modelMissing
    /// A Whisper id in a mode's `model`. Different namespace: that field is a *chat*
    /// model, and `whisper-large-v3-turbo` is a transcription one. The mistake is
    /// invisible until a dictation fails.
    case modelIsTranscriptionModel(String)
    case modelUnrecognised(String)
    case reasoningUnsupported(ReasoningEffort, model: String)
    case temperatureOutOfRange(Double)
    case temperatureNotFinite
    case hotkeyConflict(ModeHotkeyConflict)

    var isBlocking: Bool {
        if case .modelUnrecognised = self { return false }
        return true
    }

    var message: String {
        switch self {
        case .nameEmpty:
            return "A mode needs a name."
        case .modelMissing:
            return "An LLM mode needs a model."
        case .modelIsTranscriptionModel(let id):
            return "\(id) transcribes audio; a mode needs a chat model."
        case .modelUnrecognised(let id):
            return "Captur hasn't seen \(id) in \(RefinementModelPreset.all.count) shipped "
                + "presets. The selected provider will check it when the mode runs."
        case .reasoningUnsupported(let effort, let model):
            return "\(model) does not advertise \(effort.title.lowercased()) reasoning."
        case .temperatureOutOfRange(let value):
            return "Temperature is \(value); choose a value from 0 to 2."
        case .temperatureNotFinite:
            return "Temperature has to be a number between 0 and 2."
        case .hotkeyConflict(let conflict):
            switch conflict {
            case .otherMode(_, let name):
                return "\(name) already uses that shortcut."
            case .globalBinding(let label):
                return "That shortcut is \(label)."
            case .captureBinding(let label):
                return "That keystroke means \(label) while you are dictating."
            case .needsModifier:
                return "Add ⌃, ⌥, ⇧ or ⌘ — a bare key would be taken from every app."
            }
        }
    }
}

// MARK: - Preview

/// The state of the "try it on your last dictation" button.
enum ModePreviewState: Equatable {
    case idle
    /// Nothing to try, or nothing to try it with.
    case unavailable(String)
    case running
    /// A pass-through mode: no model was called, and this is what it would insert.
    case skipped(String)
    case done(String)
    case failed(String)
}

/// The part of a historical dictation needed to preview a mode faithfully.
///
/// The target app travels with the raw transcript because Captur itself is
/// frontmost while the Modes screen is open. Reading the current application
/// would therefore preview the wrong app context every time.
struct ModePreviewSource: Equatable, Sendable {
    var rawText: String
    var targetAppName: String?
}

enum ModePreviewError: LocalizedError, Equatable {
    case missingAPIKey(RefinementProviderID)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add your \(provider.title) API key in Settings before running a preview."
        case .emptyResponse:
            return "The provider returned an empty preview. Try again."
        }
    }
}

/// Runs the production preview without inserting text or mutating History.
///
/// Kept as a small injected collaborator rather than duplicating the mode pass in
/// the view. It uses the same prompt assembler, chat client, timeout, vocabulary,
/// and privacy gates as a real dictation, while returning the failure to the editor
/// instead of falling back silently to the raw transcript.
@MainActor
struct ModePreviewRunner {
    private var refinement: (any RefinementCompleting)?
    private var legacyChat: (any GroqChatting)?
    var apiKey: (RefinementProviderID) -> String?
    var vocabularyTerms: () -> [VocabularyTerm]
    var clipboard: () -> String?
    var contextEnabled: () -> Bool = { true }
    var localCleanup: (any LocalCleanCompleting)? = nil
    var cleanupRegistry: LocalCleanupRegistry = .builtIn

    init(refinement: any RefinementCompleting,
         apiKey: @escaping (RefinementProviderID) -> String?,
         vocabularyTerms: @escaping () -> [VocabularyTerm],
         clipboard: @escaping () -> String?,
         contextEnabled: @escaping () -> Bool = { true },
         localCleanup: (any LocalCleanCompleting)? = nil,
         cleanupRegistry: LocalCleanupRegistry = .builtIn) {
        self.cleanupRegistry = cleanupRegistry
        self.localCleanup = localCleanup
        self.contextEnabled = contextEnabled
        self.refinement = refinement
        legacyChat = nil
        self.apiKey = apiKey
        self.vocabularyTerms = vocabularyTerms
        self.clipboard = clipboard
    }

    /// Compatibility initializer for the focused Groq preview tests and any
    /// older injected caller. Production uses the provider-neutral initializer.
    init(chat: any GroqChatting,
         apiKey: @escaping () -> String?,
         vocabularyTerms: @escaping () -> [VocabularyTerm],
         clipboard: @escaping () -> String?) {
        refinement = nil
        legacyChat = chat
        self.apiKey = { provider in provider == .groq ? apiKey() : nil }
        self.vocabularyTerms = vocabularyTerms
        self.clipboard = clipboard
    }

    func run(mode: Mode, source: ModePreviewSource) async -> Result<String, Error> {
        guard mode.usesLLM else { return .success(source.rawText) }
        if mode.usesLocalCleanup {
            do {
                if source.rawText.contains(TranscriptStitcher.failureMarker) { return .success(source.rawText) }
                guard let localCleanup else { throw LocalCleanupError.unavailable(mode.cleanupChoice) }
                let systemMessage = mode.usesModePrompt(in: cleanupRegistry) ? PromptAssembler.systemMessage(
                    mode: mode, vocabularyTerms: vocabularyTerms(),
                    appName: mode.includeAppNameContext && contextEnabled() ? source.targetAppName : nil,
                    clipboard: nil, registry: cleanupRegistry) : ""
                return .success(try await localCleanup.clean(source.rawText, request: .init(
                    choice: mode.cleanupChoice, systemMessage: systemMessage, temperature: mode.temperature)))
            } catch { return .failure(error) }
        }
        let keyProvider = legacyChat == nil ? mode.refinementProvider : .groq
        let key = apiKey(keyProvider)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return .failure(ModePreviewError.missingAPIKey(keyProvider))
        }

        let systemMessage = PromptAssembler.systemMessage(
            mode: mode,
            vocabularyTerms: vocabularyTerms(),
            appName: mode.includeAppNameContext && contextEnabled() ? source.targetAppName : nil,
            // Historical context was deliberately not retained. Never mix today's
            // clipboard with a previous dictation.
            clipboard: nil)

        do {
            let output: String
            if let refinement {
                output = try await refinement.complete(
                    systemMessage: systemMessage,
                    userMessage: source.rawText,
                    provider: mode.refinementProvider,
                    model: mode.model,
                    reasoning: mode.reasoningEffort,
                    temperature: mode.temperature,
                    apiKey: key,
                    timeout: mode.refinementProvider.defaultTimeout,
                    onDelta: { _ in }).text
            } else if let legacyChat {
                output = try await legacyChat.complete(
                    systemMessage: systemMessage,
                    userMessage: source.rawText,
                    model: mode.model,
                    temperature: mode.temperature,
                    apiKey: key,
                    timeout: GroqChatClient.defaultTimeout,
                    onDelta: { _ in })
            } else {
                return .failure(ModePreviewError.emptyResponse)
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(ModePreviewError.emptyResponse) }
            return .success(trimmed)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - View model

/// Spec §10.3. The list, the editor, and the per-app mapping table.
///
/// Every rule that is expensive to get wrong lives here rather than in the view:
/// which destructive action a mode gets, how a duplicate is named, which
/// keystrokes are already taken, what a valid model and temperature are, and what
/// the per-app map is allowed to point at.
///
/// It owns no window and reaches nothing on its own — the store, the global
/// bindings, the preview and the app-name lookup are all injected, so the whole
/// screen is testable without a keyboard, a network or a real modes file.
@MainActor
@Observable
final class ModesViewModel {

    /// Deleting means two different things depending on the mode, and the caller is
    /// told which one happened so the UI can word its confirmation honestly.
    enum DeleteOutcome: Equatable {
        /// A built-in: its shipped definition came back. The list keeps six modes.
        case resetToBuiltIn
        case deletedCustom
        case unknownMode
    }

    enum PerAppMappingResult: Equatable {
        case applied
        case cleared
        /// A mode id that no longer names a mode. Rejected rather than stored, so
        /// the table can never show a row that resolves to nothing.
        case rejectedUnknownMode(String)
        case rejectedBlankBundleID
    }

    enum Copy {
        static let noDictationToPreview =
            "Dictate something first — the preview runs on your most recent one."
        static let previewNotConnected =
            "The preview isn't connected to a model yet."
        /// Task 16 wires modes into the pipeline. Until then this screen saves
        /// faithfully and changes nothing at dictation time, and says so.
        static let modesNotWiredYet =
            "Prompts, models and temperature are saved, but dictation doesn't use them yet — "
            + "every capture still inserts the raw transcript."
        static let noModes = "No modes. That should be impossible; the six built-ins are in code."
    }

    static let knownChatModels = RefinementModelPreset.all.map(\.id)

    /// Groq's chat completions accept 0...2. A value outside it is a 400 at
    /// dictation time, a long way from the slider that caused it.
    static let temperatureRange = 0.0...2.0

    /// The symbol picker's palette. SF Symbols that exist in the shipped OS and read
    /// at menu-bar size; the six built-in symbols are first so a duplicate of a
    /// built-in can be told apart from it without inventing a glyph.
    static let symbolChoices = [
        "sparkles", "text.quote", "bubble.left", "envelope", "list.bullet",
        "chevron.left.forwardslash.chevron.right", "wand.and.stars", "pencil",
        "doc.text", "checklist", "quote.bubble", "text.append",
        "character.cursor.ibeam", "keyboard", "brain", "lightbulb",
        "paperplane", "tag", "flag", "star",
    ]

    // MARK: State

    /// The mode being edited. Bound directly by the editor's controls; nothing here
    /// reaches the store until `save()`.
    var draft: ModeDraft
    private(set) var selectedModeID: String?
    /// What the last `save()` complained about. Empty until the user tries.
    private(set) var issues: [ModeValidationIssue] = []
    private(set) var previewState: ModePreviewState = .idle
    private var previewInFlight = false
    /// True while the hotkey field is listening for a keystroke.
    private(set) var isRecordingHotkey = false

    /// The global bindings a mode hotkey must not collide with. A `var` because
    /// Settings (Task 25) can rebind them while this screen is open, and a stale
    /// copy would call a free keystroke taken — or worse, a taken one free.
    var globalBindings: HotkeyBindings

    /// Bundle id → display name. Injected so the per-app table can show "Slack"
    /// without this type touching `NSWorkspace`, and so tests need no installed apps.
    var appName: (String) -> String? = { _ in nil }

    /// Apps to offer in the per-app table's "add" menu. Injected for the same reason.
    var runningApps: () -> [(bundleID: String, name: String)] = { [] }

    /// Called with `true` while the hotkey recorder is listening. `HotkeyManager`
    /// must suspend, or a combo that is already registered (⌥Space) fires the app
    /// instead of landing in the field. The composition root wires this up.
    var suspendGlobalHotkeys: (Bool) -> Void = { _ in }
    var openCleanupSettings: () -> Void = { }
    var modesDidChange: () -> Void = { }
    private(set) var cleanupAvailability: LocalModelAvailability?
    private let localCleanupAvailability: (ModeCleanupChoice) async -> LocalModelAvailability

    let store: ModeStore
    let cleanupRegistry: LocalCleanupRegistry
    var cleanupChoices: [ModeCleanupChoice] {
        let choices = cleanupRegistry.choices
        return choices.contains(draft.cleanupChoice) ? choices : choices + [draft.cleanupChoice]
    }
    var cleanupDescriptor: CleanupModelDescriptor? { cleanupRegistry.model(draft.cleanupChoice) }
    var draftUsesModePrompt: Bool { draft.mode.usesModePrompt(in: cleanupRegistry) }

    /// The most recent usable dictation. `async` so the composition root can read
    /// `DictationRecordLog` — an actor — without keeping a cache of its own.
    private let lastDictation: () async -> ModePreviewSource?
    /// nil means no model is reachable — the honest default. Task 15 owns the Groq
    /// chat client; this screen must never construct one, and never has a key.
    private let preview: ((Mode, ModePreviewSource) async -> Result<String, Error>)?
    private let modesAffectPipeline: Bool

    /// Carbon virtual keycodes for the top-row digits 1–9, in order. There is no
    /// shared constant for these yet: the 1–9 mode switch is registered by the
    /// capture path (spec §4.1), which lands with Task 16.
    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static let modifierMask: UInt32 = 0x1B00   // cmd | shift | option | control

    init(store: ModeStore,
         globalBindings: HotkeyBindings = .default,
         lastDictation: @escaping () async -> ModePreviewSource? = { nil },
         preview: ((Mode, ModePreviewSource) async -> Result<String, Error>)? = nil,
         modesAffectPipeline: Bool = false,
         cleanupRegistry: LocalCleanupRegistry = .builtIn,
         localCleanupAvailability: @escaping (ModeCleanupChoice) async -> LocalModelAvailability = { _ in
             LocalModelAvailability(isDownloaded: false, updateAvailable: false)
         }) {
        self.store = store
        self.cleanupRegistry = cleanupRegistry
        self.globalBindings = globalBindings
        self.lastDictation = lastDictation
        self.preview = preview
        self.modesAffectPipeline = modesAffectPipeline
        self.localCleanupAvailability = localCleanupAvailability

        let opening = store.mode(id: store.defaultModeID) ?? store.modes.first ?? Mode.clean
        draft = ModeDraft(mode: opening)
        selectedModeID = opening.id

        // A mapping can go stale outside this screen — an older build's delete, or a
        // hand-edited file. `ModeResolver` would fall through it, but a Settings row
        // pointing at a mode that no longer exists is a lie about the user's setup.
        dropStalePerAppMappings()
    }

    // MARK: Reads

    var modes: [Mode] { store.modes }
    var defaultModeID: String { store.defaultModeID }
    var selectedModeIsDefault: Bool { selectedModeID == store.defaultModeID }

    var availableModelPresets: [RefinementModelPreset] {
        RefinementModelPreset.presets(for: draft.refinementProvider)
    }

    var availableReasoningEfforts: [ReasoningEffort] {
        RefinementModelPreset.preset(
            provider: draft.refinementProvider,
            modelID: draft.model)?.supportedReasoning ?? ReasoningEffort.allCases
    }

    var hasUnsavedChanges: Bool {
        guard let selectedModeID, let saved = store.mode(id: selectedModeID) else { return false }
        return draft.normalized.mode != saved
    }

    /// A built-in only offers "restore default" once there is something to restore.
    var canResetSelectedMode: Bool {
        guard let selectedModeID,
              let shipped = Mode.builtIns.first(where: { $0.id == selectedModeID }),
              let current = store.mode(id: selectedModeID) else { return false }
        return current != shipped
    }

    /// Non-nil while a saved mode still cannot change a dictation.
    var pipelineNotice: String? {
        modesAffectPipeline ? nil : Copy.modesNotWiredYet
    }

    // MARK: Selection

    func select(modeID: String) {
        guard let mode = store.mode(id: modeID) else { return }
        selectedModeID = modeID
        draft = ModeDraft(mode: mode)
        issues = []
        // A preview belongs to the prompt that produced it. Leaving it under a
        // different mode's editor would credit one mode with another's output.
        previewState = .idle
    }

    func setDraftProvider(_ provider: RefinementProviderID) {
        guard draft.refinementProvider != provider else { return }
        draft.refinementProvider = provider
        draft.model = RefinementModelPreset.defaultPreset(for: provider).id
        draft.reasoningEffort = provider == .openRouter ? .low : .providerDefault
        previewState = .idle
    }

    func setDraftCleanupChoice(_ choice: ModeCleanupChoice) {
        draft.cleanupChoice = choice
        cleanupAvailability = nil
        issues = []
        previewState = .idle
    }

    func refreshCleanupAvailability() async {
        let choice = draft.cleanupChoice
        let availability = await localCleanupAvailability(choice)
        guard !Task.isCancelled, choice == draft.cleanupChoice else { return }
        cleanupAvailability = availability
    }

    func manageCleanupModel() {
        if hasUnsavedChanges || store.lastSaveError != nil {
            if save().contains(where: \.isBlocking) { return }
        }
        guard store.lastSaveError == nil else { return }
        openCleanupSettings()
    }

    func setDraftModel(_ modelID: String) {
        draft.model = modelID
        if !availableReasoningEfforts.contains(draft.reasoningEffort) {
            draft.reasoningEffort = .providerDefault
        }
        previewState = .idle
    }

    /// Throws the draft away and re-reads the stored mode.
    func revert() {
        guard let selectedModeID else { return }
        select(modeID: selectedModeID)
    }

    func setDefaultMode(id: String) {
        guard store.mode(id: id) != nil else { return }
        store.setDefaultModeID(id)
        modesDidChange()
    }

    /// Makes the mode in the editor the global default. If the user has just
    /// previewed an unsaved draft, save that exact draft first; otherwise the next
    /// capture would use older settings than the preview they approved.
    @discardableResult
    func saveAndUseSelectedModeAsDefault() -> [ModeValidationIssue] {
        guard let selectedModeID else { return [] }
        let found = hasUnsavedChanges ? save() : []
        guard !found.contains(where: \.isBlocking) else { return found }
        store.setDefaultModeID(selectedModeID)
        modesDidChange()
        return found
    }

    // MARK: Saving

    /// Validates and, if nothing blocks, writes the draft. Returns what it found so
    /// a caller can react without reading `issues` back.
    @discardableResult
    func save() -> [ModeValidationIssue] {
        let normalized = draft.normalized
        let found = validate(normalized)
        issues = found
        guard !found.contains(where: \.isBlocking) else { return found }

        store.update(normalized.mode)
        // Re-read rather than keeping the draft: the store reduces a built-in to a
        // diff and may hand back something the draft did not say (a structural field
        // it refused to change), and the editor should show what was actually stored.
        if let stored = store.mode(id: normalized.id) {
            draft = ModeDraft(mode: stored)
        }
        modesDidChange()
        return found
    }

    func validate(_ draft: ModeDraft) -> [ModeValidationIssue] {
        var found: [ModeValidationIssue] = []

        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(.nameEmpty)
        }

        if !draft.temperature.isFinite {
            found.append(.temperatureNotFinite)
        } else if draft.mode.usesModePrompt(in: cleanupRegistry) && !Self.temperatureRange.contains(draft.temperature) {
            found.append(.temperatureOutOfRange(draft.temperature))
        }

        // A pass-through mode has no prompt and no model, and that is not a mistake.
        if draft.mode.usesProviderRefinement {
            let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.isEmpty {
                found.append(.modelMissing)
            } else if model.lowercased().contains("whisper") {
                found.append(.modelIsTranscriptionModel(model))
            } else if RefinementModelPreset.preset(
                provider: draft.refinementProvider, modelID: model) == nil {
                found.append(.modelUnrecognised(model))
            }
            if let preset = RefinementModelPreset.preset(
                provider: draft.refinementProvider, modelID: model),
               !preset.supportedReasoning.contains(draft.reasoningEffort) {
                found.append(.reasoningUnsupported(draft.reasoningEffort, model: model))
            }
        }

        if let hotkey = draft.hotkey,
           let conflict = hotkeyConflict(for: hotkey, excluding: draft.id) {
            found.append(.hotkeyConflict(conflict))
        }

        return found
    }

    // MARK: List actions

    /// A new custom mode, seeded with the anti-injection clause. Starting from a
    /// blank prompt would ship a mode that answers the user's dictation back at them
    /// the first time they dictate a question into it.
    @discardableResult
    func addMode() -> Mode {
        let names = Set(store.modes.map { $0.name.lowercased() })
        let name = Self.firstUnused({ $0 == nil ? "New mode" : "New mode \($0!)" }, taken: names)
        let mode = Mode(
            id: Self.unusedID(basedOn: name, taken: Set(store.modes.map(\.id))),
            name: name,
            symbol: "wand.and.stars",
            isBuiltIn: false,
            usesLLM: true,
            systemPrompt: Mode.antiInjectionClause,
            refinementProvider: Mode.clean.refinementProvider,
            model: Mode.clean.model,
            reasoningEffort: Mode.clean.reasoningEffort,
            temperature: 0.2)
        store.update(mode)
        modesDidChange()
        select(modeID: mode.id)
        return mode
    }

    /// A copy with a fresh id, an unused name, and no hotkey.
    ///
    /// The hotkey is deliberately dropped: two modes cannot own one keystroke, so
    /// copying it would hand the user a conflict they did not ask for.
    @discardableResult
    func duplicate(modeID: String) -> Mode? {
        guard let source = store.mode(id: modeID) else { return nil }

        var copy = source
        copy.isBuiltIn = false
        copy.hotkey = nil
        copy.name = Self.copyName(of: source.name,
                                  taken: Set(store.modes.map { $0.name.lowercased() }))
        copy.id = Self.unusedID(basedOn: copy.name, taken: Set(store.modes.map(\.id)))

        store.update(copy)
        modesDidChange()
        select(modeID: copy.id)
        return copy
    }

    /// A built-in is restored, not removed — `ModeStore` has the right primitive for
    /// each, and the six shipped modes are not the user's to delete. Spec §6.2:
    /// their definitions live in code precisely so a later version can improve them.
    @discardableResult
    func delete(modeID: String) -> DeleteOutcome {
        guard let mode = store.mode(id: modeID) else { return .unknownMode }

        if mode.isBuiltIn {
            store.resetToBuiltIn(id: modeID)
            modesDidChange()
            if selectedModeID == modeID { select(modeID: modeID) }
            return .resetToBuiltIn
        }

        store.deleteCustom(id: modeID)
        modesDidChange()
        dropStalePerAppMappings()
        if selectedModeID == modeID {
            let fallback = store.mode(id: store.defaultModeID) ?? store.modes.first ?? Mode.clean
            select(modeID: fallback.id)
        }
        return .deletedCustom
    }

    // MARK: Hotkeys

    /// The three classes a mode hotkey can collide with, most specific first, so the
    /// message names the thing the user would actually lose.
    func hotkeyConflict(for combo: KeyCombo, excluding modeID: String) -> ModeHotkeyConflict? {
        if let other = store.modes.first(where: { $0.id != modeID && $0.hotkey == combo }) {
            return .otherMode(id: other.id, name: other.name)
        }

        for (bound, label) in globalBindingLabels where bound == combo {
            return .globalBinding(label)
        }

        if let label = captureBindingLabel(for: combo) {
            return .captureBinding(label)
        }

        if combo.carbonModifiers & Self.modifierMask == 0 {
            return .needsModifier
        }

        return nil
    }

    private var globalBindingLabels: [(KeyCombo, String)] {
        [(globalBindings.toggleDictation, "Start or stop dictation"),
         (globalBindings.toggleThought, "Capture a thought"),
         (globalBindings.showHistoryPalette, "History palette")]
            .compactMap { combo, label in combo.map { ($0, label) } }
    }

    /// The bindings that exist only while a capture is on screen. They are not in
    /// `HotkeyBindings` — they are registered and torn down around a capture — but a
    /// mode hotkey that duplicates one still fights it every time the user dictates.
    private func captureBindingLabel(for combo: KeyCombo) -> String? {
        if combo == CaptureTransients.escape { return "Cancel a capture" }
        if combo == CaptureTransients.returnKey { return "End a latched recording" }
        if combo == CapsuleState.retryCombo { return "Retry after an error" }

        // 1–9 switch modes while recording. Bare, and — because the digit arrives
        // while a push-to-talk modifier is physically held — also carrying that
        // modifier. Both forms are registered, so both are taken.
        if Self.digitKeyCodes.contains(combo.keyCode) {
            let modifiers = combo.carbonModifiers & Self.modifierMask
            if modifiers == 0 || modifiers == pushToTalkCarbonModifier {
                return "Switch modes while recording"
            }
        }

        return nil
    }

    /// The Carbon bits the push-to-talk binding contributes to a keystroke while held.
    /// Fn/Globe has none — it is not part of the Carbon modifier bitmask — so with that
    /// key or none at all, only the bare digit form is taken.
    ///
    /// Delegates to `ModeDigitHotkeys`, which is what actually performs the registration.
    /// Two copies of this mapping is how this warning goes stale and starts telling the
    /// user a digit is free when the recording has already claimed it.
    private var pushToTalkCarbonModifier: UInt32? {
        ModeDigitHotkeys.carbonModifier(for: globalBindings.pushToTalk)
    }

    func beginRecordingHotkey() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        suspendGlobalHotkeys(true)
    }

    func endRecordingHotkey() {
        guard isRecordingHotkey else { return }
        isRecordingHotkey = false
        suspendGlobalHotkeys(false)
    }

    // MARK: Per-app mapping

    struct PerAppRow: Equatable, Identifiable {
        var bundleID: String
        /// The app's name if it is installed, otherwise its bundle id — never blank.
        var displayName: String
        var modeID: String
        var modeName: String

        var id: String { bundleID }
    }

    var perAppRows: [PerAppRow] {
        store.perAppMap
            .map { bundleID, modeID in
                PerAppRow(bundleID: bundleID,
                          displayName: appName(bundleID) ?? bundleID,
                          modeID: modeID,
                          modeName: store.mode(id: modeID)?.name ?? modeID)
            }
            // Sorted by what the user reads. Dictionary order would reshuffle the
            // table on every edit.
            .sorted {
                let byName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return byName == .orderedSame ? $0.bundleID < $1.bundleID : byName == .orderedAscending
            }
    }

    /// Passing nil clears the app's mapping, returning it to the global default.
    ///
    /// A mode id that no longer names a mode is refused. `ModeResolver` would fall
    /// through a dangling id safely, but storing one means a Settings row that
    /// claims an intention the user cannot see the effect of.
    @discardableResult
    func setPerAppMode(_ modeID: String?, forBundleID bundleID: String) -> PerAppMappingResult {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejectedBlankBundleID }

        guard let modeID else {
            store.setMode(nil, forBundleID: trimmed)
            modesDidChange()
            return .cleared
        }
        guard store.mode(id: modeID) != nil else {
            return .rejectedUnknownMode(modeID)
        }

        store.setMode(modeID, forBundleID: trimmed)
        modesDidChange()
        return .applied
    }

    /// Drops every mapping whose mode is gone. The alternative — rewriting it to the
    /// default — resolves identically (`ModeResolver` falls through to the default
    /// anyway) while inventing a per-app choice the user never made.
    private func dropStalePerAppMappings() {
        let live = Set(store.modes.map(\.id))
        for (bundleID, modeID) in store.perAppMap where !live.contains(modeID) {
            store.setMode(nil, forBundleID: bundleID)
        }
    }

    // MARK: Preview

    /// "Try it on your last dictation", spec §10.3.
    ///
    /// Runs the *draft*, not the stored mode: the button sits next to the prompt
    /// editor, so it has to try what the user is looking at.
    func runPreview() async {
        // A second call while one is in flight would double-bill the user for one
        // question and race over which answer lands.
        guard !previewInFlight else { return }
        previewInFlight = true
        defer {
            previewInFlight = false
            if previewState == .running { previewState = .idle }
        }

        guard let preview else {
            previewState = .unavailable(Copy.previewNotConnected)
            return
        }

        let mode = draft.normalized.mode
        let latest = await lastDictation()
        guard draft.normalized.mode == mode else { return }
        guard var source = latest else {
            previewState = .unavailable(Copy.noDictationToPreview)
            return
        }
        source.rawText = source.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = source.rawText
        guard !raw.isEmpty else {
            previewState = .unavailable(Copy.noDictationToPreview)
            return
        }

        // A pass-through mode inserts the raw transcript, so there is nothing to
        // ask a model. Sending it anyway would bill the user to be shown their own
        // words back.
        guard mode.usesLLM else {
            previewState = .skipped(raw)
            return
        }

        previewState = .running
        let result = await preview(mode, source)
        guard draft.normalized.mode == mode else { return }
        switch result {
        case .success(let text):
            previewState = .done(text)
        case .failure(let error):
            previewState = .failed(error.localizedDescription)
        }
    }

    // MARK: Naming and ids

    /// First unused name in the series `candidate(nil)`, `candidate(2)`, … Compared
    /// case-insensitively: two modes called "Clean copy" and "clean copy" are the
    /// same mistake as two called "Clean copy".
    private static func firstUnused(_ candidate: (Int?) -> String, taken: Set<String>) -> String {
        let first = candidate(nil)
        guard taken.contains(first.lowercased()) else { return first }
        var suffix = 2
        while taken.contains(candidate(suffix).lowercased()) { suffix += 1 }
        return candidate(suffix)
    }

    /// "Clean" → "Clean copy" → "Clean copy 2" → "Clean copy 3".
    ///
    /// The numbering walks the series rather than counting existing copies: with
    /// Clean, Clean copy and Clean copy 2 already present, any count-based scheme
    /// lands on a name that is already taken.
    static func copyName(of name: String, taken: Set<String>) -> String {
        // Duplicating "Clean copy 2" gives "Clean copy 3", not "Clean copy 2 copy".
        var base = name
        if let suffix = base.range(of: #" copy( \d+)?$"#, options: .regularExpression) {
            base.removeSubrange(suffix)
        }
        if base.trimmingCharacters(in: .whitespaces).isEmpty { base = name }

        return firstUnused({ $0 == nil ? "\(base) copy" : "\(base) copy \($0!)" }, taken: taken)
    }

    /// A url-and-filename-safe slug of `name`, made unique against `taken`.
    ///
    /// Ids are persisted in the per-app map, the global default and every history
    /// record, so a collision would silently point two of those at one mode.
    static func unusedID(basedOn name: String, taken: Set<String>) -> String {
        var slug = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !slug.isEmpty, !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        // A name with no ASCII in it at all still needs an id, and it still has to
        // be different from the next one.
        if slug.isEmpty { slug = "mode-\(UUID().uuidString.prefix(8).lowercased())" }

        guard taken.contains(slug) else { return slug }
        var suffix = 2
        while taken.contains("\(slug)-\(suffix)") { suffix += 1 }
        return "\(slug)-\(suffix)"
    }

    // MARK: Keystroke rendering

    /// "⌃⌥⇧K". Modifier order is fixed (the order macOS shows them in), not the
    /// order the bits happen to be set in.
    ///
    /// Local to this screen on purpose: the global shortcut recorder (Task 25) has
    /// its own, and one of the two should absorb the other once both exist.
    static func displayString(for combo: KeyCombo) -> String {
        var text = ""
        if combo.carbonModifiers & 0x1000 != 0 { text += "⌃" }
        if combo.carbonModifiers & 0x0800 != 0 { text += "⌥" }
        if combo.carbonModifiers & 0x0200 != 0 { text += "⇧" }
        if combo.carbonModifiers & 0x0100 != 0 { text += "⌘" }
        return text + keyName(for: combo.keyCode)
    }

    /// Carbon virtual keycodes are positional, so this is a layout-independent
    /// approximation: right for a US layout, and never blank for anything else.
    static func keyName(for keyCode: UInt32) -> String {
        if let name = keyNames[keyCode] { return name }
        return "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        117: "Forward Delete", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
