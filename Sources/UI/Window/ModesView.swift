import AppKit
import SwiftUI

/// The modes screen, spec §10.3: the list on the left, the editor on the right, and
/// the per-app mapping table under it.
///
/// No window of its own — Task 21 drops this into the sidebar window. Every rule
/// lives in `ModesViewModel`; this file is layout, copy, and the one control the
/// screen needs that AppKit does not hand over for free (a keystroke recorder).
struct ModesView: View {
    @Bindable var model: ModesViewModel

    @State private var newBundleID = ""

    var body: some View {
        ZStack {
            CapturPalette.canvas.ignoresSafeArea()

            HStack(spacing: 0) {
                modeList
                    .frame(minWidth: 220, idealWidth: 236, maxWidth: 252)
                Divider()
                editorColumn
            }
        }
        // Tiled windows can be narrower than the preferred AppKit minimum. Let the
        // editor wrap within the shell's detail column instead of clipping its footer.
        .frame(minWidth: 560, minHeight: 560)
        .onDisappear { model.endRecordingHotkey() }
    }

    // MARK: - The list

    private var modeList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CapturMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Modes")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Shape every capture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider()

            List(selection: selection) {
                ForEach(model.modes) { mode in
                    row(for: mode)
                        .tag(mode.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 2) {
                Button {
                    model.addMode()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a mode")

                Button {
                    if let id = model.selectedModeID { model.duplicate(modeID: id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate the selected mode")
                .disabled(model.selectedModeID == nil)

                Button {
                    if let id = model.selectedModeID { model.delete(modeID: id) }
                } label: {
                    Image(systemName: selectedIsBuiltIn ? "arrow.uturn.backward" : "minus")
                }
                // A built-in cannot be deleted, only restored — and there is nothing
                // to restore until the user has changed something.
                .disabled(selectedIsBuiltIn && !model.canResetSelectedMode)
                .help(selectedIsBuiltIn
                      ? "Restore this built-in mode's shipped settings"
                      : "Delete this mode")

                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(CapturPalette.inset)
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedModeID },
                set: { if let id = $0 { model.select(modeID: id) } })
    }

    private var selectedIsBuiltIn: Bool {
        guard let id = model.selectedModeID else { return false }
        return model.store.mode(id: id)?.isBuiltIn ?? false
    }

    private func row(for mode: Mode) -> some View {
        HStack(spacing: 9) {
            Image(systemName: mode.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(mode.id == model.defaultModeID ? CapturPalette.accent : Color.secondary)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(mode.name)
                    .font(.callout.weight(.medium))
                if mode.id == model.defaultModeID {
                    Text("Default mode").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if let hotkey = mode.hotkey {
                Text(ModesViewModel.displayString(for: hotkey))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Set as Default") {
                if mode.id == model.selectedModeID {
                    model.saveAndUseSelectedModeAsDefault()
                } else {
                    model.setDefaultMode(id: mode.id)
                }
            }
                .disabled(mode.id == model.defaultModeID)
            Button("Duplicate") { model.duplicate(modeID: mode.id) }
            Divider()
            Button(mode.isBuiltIn ? "Restore Default" : "Delete") {
                model.delete(modeID: mode.id)
            }
            .disabled(mode.isBuiltIn && !isEdited(mode))
        }
    }

    private func isEdited(_ mode: Mode) -> Bool {
        guard let shipped = Mode.builtIns.first(where: { $0.id == mode.id }) else { return true }
        return shipped != mode
    }

    // MARK: - The editor

    private var editorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CapturPageHeader(
                    title: "Mode editor",
                    subtitle: "Choose how Captur understands, refines, and inserts your words."
                )
                if let notice = model.pipelineNotice {
                    notWiredBanner(notice)
                }
                if let error = model.store.lastSaveError {
                    Text("Your mode settings could not be saved: \(error)")
                        .font(.callout).foregroundStyle(.red)
                }
                identitySection
                if model.draft.usesLLM {
                    cleanupSection
                    if model.draftUsesModePrompt { promptSection }
                    previewSection
                    if model.draftUsesModePrompt { contextSection }
                } else {
                    passThroughNote
                }
                behaviourSection
                perAppSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// Honesty, not decoration: until Task 16 wires modes into the pipeline, a saved
    /// prompt changes nothing at dictation time and the screen has to say so rather
    /// than let the user believe their edit took effect.
    private func notWiredBanner(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(notice).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .capturSurface(inset: true, radius: 10)
    }

    private var identitySection: some View {
        CapturCard("Identity", symbol: "signature", caption: "The symbol identifies this mode in the menu bar while recording.") {
            HStack(spacing: 10) {
                symbolPicker
                TextField("Name", text: $model.draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if model.draft.isBuiltIn {
                    Text("Built-in").font(.caption).foregroundStyle(.secondary)
                }
            }

            issueLines(for: [.nameEmpty])
        }
    }

    private var symbolPicker: some View {
        Menu {
            ForEach(ModesViewModel.symbolChoices, id: \.self) { symbol in
                Button {
                    model.draft.symbol = symbol
                } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        } label: {
            Image(systemName: model.draft.symbol.isEmpty ? "questionmark" : model.draft.symbol)
                .frame(width: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Symbol, shown in the menu bar while recording")
    }

    private var cleanupSection: some View {
        CapturCard("Cleanup", symbol: "sparkles") {
            Picker("Process text with", selection: Binding(
                get: { model.draft.cleanupChoice },
                set: { model.setDraftCleanupChoice($0) })) {
                ForEach(model.cleanupChoices, id: \.self) { choice in
                    Text(choice.title(in: model.cleanupRegistry)).tag(choice)
                }
            }
            if model.draft.mode.usesLocalCleanup {
                Text(model.cleanupDescriptor?.detail ?? "This local model is unavailable in this build. Choose a registered model; your saved selection is preserved.")
                    .font(.caption).foregroundStyle(.secondary)
                if let availability = model.cleanupAvailability {
                    if availability.isDownloaded && !availability.updateAvailable {
                        Label("Model downloaded", systemImage: "checkmark.circle")
                    } else {
                        Label(availability.updateAvailable ? "Model needs an update" : "Model is not downloaded",
                              systemImage: "exclamationmark.triangle")
                    }
                } else {
                    ProgressView("Checking local model…")
                }
                Button(model.hasUnsavedChanges ? "Save & manage local model in Settings" : "Manage local model in Settings") {
                    model.manageCleanupModel()
                }
                Text("If cleanup fails or the model is unavailable, Captur keeps your transcript and shows a notice. It never switches to a cloud provider automatically. Audio stays local only when on-device transcription is also enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: model.draft.cleanupChoice) {
            if model.draft.mode.usesLocalCleanup { await model.refreshCleanupAvailability() }
        }
    }

    private var promptSection: some View {
        CapturCard("Prompt and model", symbol: "text.badge.sparkles", caption: "Custom model identifiers are supported. Validation stays visible before you save.") {
            TextEditor(text: $model.draft.systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .padding(6)
                .capturSurface(inset: true, radius: 9)

            if model.draft.mode.usesProviderRefinement {
                HStack(spacing: 10) {
                    Text("Provider").font(.callout)
                    Picker("", selection: Binding(
                        get: { model.draft.refinementProvider },
                        set: { model.setDraftProvider($0) })) {
                        ForEach(RefinementProviderID.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                HStack(spacing: 10) {
                    Text("Model").font(.callout)
                    TextField("Provider model id", text: Binding(
                        get: { model.draft.model },
                        set: { model.setDraftModel($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Menu {
                        ForEach(model.availableModelPresets) { preset in
                            Button(preset.title) { model.setDraftModel(preset.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Curated models for the selected provider; custom ids are allowed")
                }

                HStack(spacing: 10) {
                    Text("Thinking").font(.callout)
                    Picker("", selection: $model.draft.reasoningEffort) {
                        ForEach(model.availableReasoningEfforts) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

            }
            HStack(spacing: 10) {
                Text("Temperature").font(.callout)
                Slider(value: $model.draft.temperature,
                       in: ModesViewModel.temperatureRange,
                       step: 0.05)
                    .frame(maxWidth: 240)
                Text(String(format: "%.2f", model.draft.temperature))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            issueLines(for: [.modelMissing,
                             .modelIsTranscriptionModel(model.draft.model),
                             .modelUnrecognised(model.draft.model),
                             .reasoningUnsupported(model.draft.reasoningEffort,
                                                   model: model.draft.model),
                             .temperatureNotFinite,
                             .temperatureOutOfRange(model.draft.temperature)])
        }
    }

    private var previewSection: some View {
        CapturCard("Preview", symbol: "play.rectangle", caption: "Uses your latest saved dictation and never invents sample text.") {
            HStack(spacing: 10) {
                Button("Try it on your last dictation") {
                    Task { await model.runPreview() }
                }
                .disabled(model.previewState == .running)

                if model.previewState == .running {
                    ProgressView().controlSize(.small)
                }
            }

            previewResult
        }
    }

    @ViewBuilder
    private var previewResult: some View {
        switch model.previewState {
        case .idle:
            EmptyView()

        case .running:
            EmptyView()

        case .unavailable(let message):
            // The same shape every other absence in the app uses (spec §10.6).
            EmptyState(message: message, symbol: "waveform")
                .frame(height: 120)
                .capturSurface(inset: true, radius: 9)

        case .skipped(let text):
            previewBox(text, note: "This mode inserts the transcript unchanged — no model was called.")

        case .done(let text):
            previewBox(text, note: nil)

        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func previewBox(_ text: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .capturSurface(inset: true, radius: 9)
        }
    }

    private var contextSection: some View {
        CapturCard("Context", symbol: "scope", caption: "Only the sources enabled here can be sent to this mode’s AI provider.") {
            Toggle("Send the target app’s name", isOn: $model.draft.includeAppNameContext)
            Toggle("Use selected text", isOn: $model.draft.contextOptions.selectedText)
            Toggle("Spoken commands edit selected text", isOn: $model.draft.contextOptions.editSelectedText)
                .disabled(!model.draft.contextOptions.selectedText)
            Text("When enabled and a complete selection fits the limit, speech becomes an editing request such as ‘make this more concise’. Output replaces the selection only if the target app and selected text still match; otherwise it is kept on the clipboard. Keep the target field selected until completion. With no usable selection, normal dictation applies.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use text around the caret", isOn: $model.draft.contextOptions.editorText)
            Toggle("Use clipboard text", isOn: $model.draft.includeClipboardContext)
            Toggle("Send window title and input label", isOn: $model.draft.contextOptions.applicationDetails)
            Toggle("Refresh editor context before AI refinement", isOn: $model.draft.contextOptions.refreshEditorBeforeRefinement)
            Text("Selection stays fixed at recording start. Refresh reads the target app only if it is still frontmost; it may capture a later document in that app. Window titles can contain private document names.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Send website domain", isOn: $model.draft.contextOptions.website)
            Toggle("Send recording date and time", isOn: $model.draft.contextOptions.dateTime)
            Text("Only enabled sources go to this mode’s AI provider. Selection: up to 1,000 characters; editor and clipboard: up to 2,000 each. Snapshot scheduled when recording starts. Clipboard timing and the master switch are in Settings → Context. Unsupported or protected fields are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Preview and History retries omit editor, selection, clipboard, website and date context. Raw context is never saved. Context helps spelling unless the explicit selected-text editing option is enabled. Switching modes during recording discards text context; the new mode’s context applies to the next recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var passThroughNote: some View {
        CapturCard("Direct dictation", symbol: "arrow.right.to.line", caption: "No provider is called and no context is sent.") {
            Text("This mode inserts the transcript as spoken, with no model, prompt, or added refinement latency.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviourSection: some View {
        CapturCard("Shortcut and insertion", symbol: "keyboard", caption: "A mode shortcut overrides app and website routing for that capture.") {
            HStack(spacing: 10) {
                Text("Shortcut").font(.callout)
                ModeHotkeyField(model: model)
            }

            if let hotkey = model.draft.hotkey,
               let conflict = model.hotkeyConflict(for: hotkey, excluding: model.draft.id) {
                issueLine(ModeValidationIssue.hotkeyConflict(conflict))
            }

            Picker("Auto-paste", selection: autoPasteChoice) {
                Text("Follow the global setting").tag(AutoPasteChoice.followGlobal)
                Text("Always").tag(AutoPasteChoice.always)
                Text("Never").tag(AutoPasteChoice.never)
            }
            .pickerStyle(.radioGroup)
        }
    }

    /// The three states `autoPaste` actually has. "Follow the global setting" is not
    /// the same answer as "Never", and collapsing them would silently change what a
    /// mode does — see `NullableOverride` in `ModeStore`.
    private enum AutoPasteChoice: Hashable { case followGlobal, always, never }

    private var autoPasteChoice: Binding<AutoPasteChoice> {
        Binding(
            get: {
                switch model.draft.autoPaste {
                case .none: return .followGlobal
                case .some(true): return .always
                case .some(false): return .never
                }
            },
            set: { choice in
                switch choice {
                case .followGlobal: model.draft.autoPaste = nil
                case .always: model.draft.autoPaste = true
                case .never: model.draft.autoPaste = false
                }
            })
    }

    // MARK: - Per-app mapping

    private var perAppSection: some View {
        CapturCard("Per-app modes", symbol: "app.badge") {
            Text("The mode a capture starts in when this app is frontmost. A mode chosen by its own shortcut still wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.perAppRows.isEmpty {
                EmptyState(message: "No app has a mode of its own.", symbol: "app.dashed")
                    .frame(height: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.perAppRows) { row in
                        perAppRow(row)
                        if row.id != model.perAppRows.last?.id { Divider() }
                    }
                }
                .capturSurface(inset: true, radius: 9)
            }

            HStack(spacing: 8) {
                TextField("com.example.app", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                Menu("Add") {
                    Button("This bundle ID") {
                        model.setPerAppMode(model.defaultModeID, forBundleID: newBundleID)
                        newBundleID = ""
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    let running = model.runningApps()
                    if !running.isEmpty {
                        Divider()
                        ForEach(running, id: \.bundleID) { app in
                            Button(app.name) {
                                model.setPerAppMode(model.defaultModeID, forBundleID: app.bundleID)
                            }
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func perAppRow(_ row: ModesViewModel.PerAppRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                if row.displayName != row.bundleID {
                    Text(row.bundleID).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Picker("", selection: perAppSelection(for: row)) {
                ForEach(model.modes) { mode in
                    Text(mode.name).tag(mode.id)
                }
            }
            .labelsHidden()
            .frame(width: 160)

            Button {
                model.setPerAppMode(nil, forBundleID: row.bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop using a per-app mode for \(row.displayName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func perAppSelection(for row: ModesViewModel.PerAppRow) -> Binding<String> {
        Binding(get: { row.modeID },
                set: { model.setPerAppMode($0, forBundleID: row.bundleID) })
    }

    // MARK: - Footer and shared bits

    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                if !issue.isBlocking {
                    Label(issue.message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if model.selectedModeIsDefault {
                Label("Default Mode", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(model.hasUnsavedChanges ? "Save & Use as Default" : "Use as Default") {
                    model.saveAndUseSelectedModeAsDefault()
                }
                .disabled(model.selectedModeID == nil)
                .help("Use this mode when no shortcut or per-app mode overrides it")
            }

            Button("Revert") { model.revert() }
                .disabled(!model.hasUnsavedChanges)
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasUnsavedChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(CapturPalette.surface)
        .overlay(alignment: .top) { Divider() }
    }

    /// The complaints from the last save attempt that belong to this section. Matched
    /// by case rather than by index so a reordered `validate` cannot mis-file one.
    @ViewBuilder
    private func issueLines(for kinds: [ModeValidationIssue]) -> some View {
        ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
            if kinds.contains(where: { sameKind($0, issue) }) {
                issueLine(issue)
            }
        }
    }

    private func issueLine(_ issue: ModeValidationIssue) -> some View {
        Label(issue.message, systemImage: issue.isBlocking ? "exclamationmark.circle" : "info.circle")
            .font(.caption)
            .foregroundStyle(issue.isBlocking ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sameKind(_ lhs: ModeValidationIssue, _ rhs: ModeValidationIssue) -> Bool {
        switch (lhs, rhs) {
        case (.nameEmpty, .nameEmpty),
             (.modelMissing, .modelMissing),
             (.modelIsTranscriptionModel, .modelIsTranscriptionModel),
             (.modelUnrecognised, .modelUnrecognised),
             (.reasoningUnsupported, .reasoningUnsupported),
             (.temperatureNotFinite, .temperatureNotFinite),
             (.temperatureOutOfRange, .temperatureOutOfRange),
             (.hotkeyConflict, .hotkeyConflict):
            return true
        default:
            return false
        }
    }
}

// MARK: - The keystroke field

/// A minimal keystroke recorder, local to this screen on purpose.
///
/// Task 25 owns the *global* shortcut recorder in Settings; this one exists because
/// a mode hotkey has to be recordable today and the two surfaces have different
/// rules (a mode hotkey may be cleared, and it is validated against the global
/// bindings rather than being one of them). Whichever lands second should absorb the
/// other — see `docs/wiring/task23-wiring.md`.
///
/// AppKit rather than SwiftUI because `onKeyPress` reports a character, and a Carbon
/// hotkey needs the positional virtual keycode.
private struct ModeHotkeyField: View {
    @Bindable var model: ModesViewModel

    var body: some View {
        HStack(spacing: 8) {
            KeyCaptureRepresentable(isRecording: model.isRecordingHotkey,
                                    onCapture: capture,
                                    onCancel: { model.endRecordingHotkey() })
                .frame(width: 0, height: 0)

            Button(label) {
                if model.isRecordingHotkey {
                    model.endRecordingHotkey()
                } else {
                    model.beginRecordingHotkey()
                }
            }
            .frame(minWidth: 150)

            if model.draft.hotkey != nil {
                Button("Clear") {
                    model.draft.hotkey = nil
                    model.endRecordingHotkey()
                }
            }
        }
    }

    private var label: String {
        if model.isRecordingHotkey { return "Press a shortcut…" }
        guard let hotkey = model.draft.hotkey else { return "Add a shortcut" }
        return ModesViewModel.displayString(for: hotkey)
    }

    /// Records whatever was pressed, conflict or not. The conflict is *shown* rather
    /// than swallowed: silently refusing the keystroke would leave the user pressing
    /// it again, wondering which of the two of them is broken.
    private func capture(_ combo: KeyCombo) {
        model.draft.hotkey = combo
        model.endRecordingHotkey()
    }
}

private struct KeyCaptureRepresentable: NSViewRepresentable {
    var isRecording: Bool
    var onCapture: (KeyCombo) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.isRecording = isRecording
        // Taking first responder is what routes the keystroke here instead of to the
        // text field the user was last in.
        if isRecording {
            view.window?.makeFirstResponder(view)
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

/// Captures one keystroke while `isRecording`, and gets out of the way otherwise.
private final class KeyCaptureView: NSView {
    var onCapture: ((KeyCombo) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording = false

    override var acceptsFirstResponder: Bool { isRecording }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        // Esc means "never mind", not "bind Esc" — and Esc is a capture binding
        // anyway, so it could not be bound.
        if event.keyCode == 53, Self.carbonModifiers(event.modifierFlags) == 0 {
            onCancel?()
            return
        }
        onCapture?(KeyCombo(keyCode: UInt32(event.keyCode),
                            carbonModifiers: Self.carbonModifiers(event.modifierFlags)))
    }

    /// A ⌘ combo is delivered as a key equivalent and never reaches `keyDown`, so
    /// without this ⌘-anything could not be recorded. Only while recording: at any
    /// other time this must not eat the window's own ⌘S.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// NSEvent flags → the Carbon bitmask `KeyCombo` stores.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= 0x0100 }
        if flags.contains(.shift) { mask |= 0x0200 }
        if flags.contains(.option) { mask |= 0x0800 }
        if flags.contains(.control) { mask |= 0x1000 }
        return mask
    }
}
