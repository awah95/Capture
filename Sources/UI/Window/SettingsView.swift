import AppKit
import SwiftUI

/// Settings, spec §10.5 — the complete configuration surface in one native scroll.
///
/// General, Microphone, Shortcuts, Transcription, AI Providers, Context, Privacy,
/// Permissions, Diagnostics, and About all ship here. Privacy arrived with Task 27
/// once `RetentionSweeper` existed to answer for it; `docs/wiring/task27-wiring.md` lists
/// the closures `AppComposition` still has to connect, and every control whose closure is
/// missing says so on screen rather than doing nothing quietly.
///
/// The screen owns no state. Everything a control reads or writes goes through
/// `SettingsViewModel`, which is why the rules that matter — suspend/resume around a
/// recorder, revert on a Carbon refusal, the key never touching `UserDefaults` — are
/// testable without a window.
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    /// Observed separately so a permission refresh redraws these rows: `model` does not
    /// republish its dependencies' changes.
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: FirstRunController
    var codex: CodexIntegration? = nil
    var availableModes: () -> [Mode] = { Mode.builtIns }

    @FocusState private var keyFieldFocused: Bool
    @FocusState private var openRouterKeyFieldFocused: Bool
    @State private var languageDraft = ""
    @State private var websiteDraft = ""
    @State private var websiteModeDraft = "clean"
    @State private var websiteError: String?

    var body: some View {
        ZStack {
            CapturPalette.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    CapturPageHeader(
                        title: "Settings",
                        subtitle: "Tune capture, transcription, privacy, and the shortcuts that keep Captur close at hand."
                    )
                    general
                    microphone
                    shortcuts
                    transcription
                    localCleanupModel
                    aiProviders
                    if let codex { CodexSettingsSection(integration: codex, settings: settings) }
                    contextSettings
                    privacy
                    permissionSection
                    diagnostics
                    about
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 32)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 520, idealHeight: 760)
        .onAppear {
            model.viewDidAppear()
            languageDraft = settings.transcriptionLanguage
        }
        .onDisappear { model.viewDidDisappear() }
    }

    // MARK: - General

    private var general: some View {
        CapturCard("General", symbol: "switch.2", caption: "System appearance stays authoritative when Match System is selected.") {
            launchAtLogin

            Picker("Appearance", selection: Binding(
                get: { settings.appearance },
                set: { model.setAppearance($0) })) {
                Text("Match System").tag(AppAppearance.system)
                Text("Light").tag(AppAppearance.light)
                Text("Dark").tag(AppAppearance.dark)
            }

            LabeledContent("Dictation HUD") {
                Button("Reset position") { model.resetHUDPosition() }
                    .help("Puts the capsule back where it starts, on every display.")
            }

            Toggle("Pause playback while recording", isOn: Binding(
                get: { settings.pauseMediaDuringRecording },
                set: { model.setPauseMediaDuringRecording($0) }))

            Text("Pauses the active macOS Now Playing session, including supported browser audio, "
                 + "then resumes the same media when recording ends. Stopped playback is left alone. "
                 + "Music and Spotify are a fallback if system playback detection is unavailable; "
                 + "that fallback requires Automation permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle("Lower volume while recording", isOn: Binding(
                    get: { settings.lowerOutputVolumeDuringRecording },
                    set: { model.setLowerOutputVolumeDuringRecording($0) }))
                HStack {
                    Slider(value: Binding(
                        get: { settings.recordingOutputVolume },
                        set: { model.setRecordingOutputVolume($0) }), in: 0...1)
                        .frame(width: 160)
                        .accessibilityLabel("Mac output volume during recording")
                    Text("\(Int(settings.recordingOutputVolume * 100))%")
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(!settings.lowerOutputVolumeDuringRecording || settings.pauseMediaDuringRecording)
            }

            Text("Lowers the Mac’s current output to this level only while recording, then restores its previous volume. "
                 + "Already quieter audio stays unchanged. Pause playback takes priority. "
                 + "Outputs without a macOS volume control stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Start and stop sounds", isOn: Binding(
                get: { settings.soundFeedback },
                set: { model.setSoundFeedback($0) }))

            LabeledContent("Sound volume") {
                Slider(value: Binding(
                    get: { settings.soundFeedbackVolume },
                    set: { model.setSoundFeedbackVolume($0) }), in: 0...1)
                    .frame(width: 160)
            }
            .disabled(!settings.soundFeedback)
            .help("At zero, no sound is played at all rather than played silently.")

            mediaAndSoundCaption
        }
    }

    /// Launch at login. `SMAppService` is the store — Captur keeps no copy of this
    /// setting — so the row shows whatever macOS currently reports, including the
    /// `requiresApproval` state a plain toggle would misreport as "on".
    @ViewBuilder
    private var launchAtLogin: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { model.launchAtLogin.isOn },
            set: { model.setLaunchAtLogin($0) }))

        if let advice = model.launchAtLogin.advice {
            VStack(alignment: .leading, spacing: 6) {
                Label(advice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                // The one case where the fix is a switch this app is not allowed to
                // flip, so the row hands the user the pane that owns it.
                if model.launchAtLogin.needsApproval {
                    Button("Open Login Items…") { model.openLoginItemsSettings() }
                }
            }
        }
    }

    @ViewBuilder
    private var mediaAndSoundCaption: some View {
        if let notice = model.mediaAndSoundNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Microphone

    private var microphone: some View {
        CapturCard("Microphone", symbol: "mic", caption: "Captur records only from the microphones in this priority list.") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Priority")
                Text("The first device on this list that is plugged in wins. "
                     + "If none are connected, recording stops instead of switching to an unlisted microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.preferredMicrophones.isEmpty {
                    Text("No preference — Captur automatically selects an available microphone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    List {
                        ForEach(model.preferredMicrophones) { microphone in
                            priorityRow(microphone)
                        }
                        .onMove { model.movePreferredMicrophones(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(height: min(CGFloat(model.preferredMicrophones.count) * 30 + 12, 160))
                    .listStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Menu("Add device…") {
                        ForEach(model.addableMicrophones) { device in
                            Button(deviceLabel(device)) { model.addPreferredMicrophone(device.id) }
                        }
                    }
                    .disabled(model.addableMicrophones.isEmpty)
                    .fixedSize()

                    Button("Re-scan") { model.refreshDevices() }
                }
            }

            Toggle("Ignore iPhone and Continuity inputs", isOn: Binding(
                get: { settings.micPolicy.excludeContinuityInputs },
                set: { model.setExcludeContinuityInputs($0) }))
                .help("A nearby iPhone otherwise volunteers as a microphone mid-sentence.")

            Toggle("Echo cancellation", isOn: Binding(
                get: { settings.voiceProcessing },
                set: { model.setVoiceProcessing($0) }))
                .disabled(!settings.pauseMediaDuringRecording)
                .help("macOS echo cancellation can duck playback. It applies only when Pause playback is enabled; otherwise Captur uses input-only recording to preserve output.")

            unwiredCaption

            // A live input meter is deliberately absent: it would mean either a polling
            // timer (§15 forbids one) or this screen owning an AVAudioEngine of its own,
            // fighting the capture path for the device. Diagnostics already has a meter
            // and owns an engine legitimately. Input gain is absent because macOS has no
            // portable per-device gain control and the audio path exposes none.
        }
    }

    private func priorityRow(_ microphone: PreferredMicrophone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: microphone.isConnected ? "mic" : "mic.slash")
                .foregroundStyle(microphone.isConnected ? .primary : .tertiary)
                .frame(width: 16)

            Text(microphone.isConnected ? microphone.name : microphone.uid)
                .foregroundStyle(microphone.isConnected ? .primary : .secondary)
                .lineLimit(1)

            if !microphone.isConnected {
                Text(microphone.name).font(.caption).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // Drag is not the only way up and down the list: a bordered List inside a
            // Form is awkward to drag in, and drag alone is not keyboard-reachable.
            Button {
                model.movePreferredMicrophone(uid: microphone.uid, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Move \(microphone.name) up")

            Button {
                model.movePreferredMicrophone(uid: microphone.uid, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Move \(microphone.name) down")

            Button {
                model.removePreferredMicrophone(microphone.uid)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(microphone.name)")
        }
    }

    private func deviceLabel(_ device: AudioInputDevice) -> String {
        device.isContinuityDevice ? "\(device.name)  (Continuity)" : device.name
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        CapturCard("Shortcuts", symbol: "keyboard", caption: "Shortcut conflicts are validated before a binding is accepted.") {
            Picker("Push-to-talk", selection: Binding(
                get: { model.pushToTalkOption },
                set: { model.setPushToTalk($0) })) {
                ForEach(SettingsViewModel.PushToTalkOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .help("Hold to record. Tap it quickly to latch a recording instead.")

            if let error = model.pushToTalkError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only when the picker is on "Custom shortcut…" — a recorder for a modifier
            // key would be a control that cannot do anything, since a bare modifier is not
            // a registerable hotkey.
            if model.pushToTalkOption == .custom {
                shortcutRow(.pushToTalkChord)
                Text("Hold this to record; tap it quickly to latch. Captur takes the "
                     + "keystroke, so it will not also reach the app you are in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(SettingsViewModel.ShortcutSlot.toggles) { slot in
                shortcutRow(slot)
            }

            LabeledContent("") {
                Button("Restore Defaults") { model.restoreShortcutDefaults() }
            }
        }
    }

    /// One recorder row. Extracted so the push-to-talk chord is wired through exactly the
    /// same calls as the toggles rather than a near-copy that can drift from them.
    private func shortcutRow(_ slot: SettingsViewModel.ShortcutSlot) -> some View {
        ShortcutRecorderField(
            title: slot.title,
            combo: model.combo(for: slot),
            isRecording: model.recordingSlot == slot,
            isEditable: model.isEditable(slot),
            disabledReason: model.disabledReason(for: slot),
            errorMessage: model.shortcutError(for: slot),
            onBeginRecording: { model.beginRecording(slot) },
            onCancel: { model.cancelRecording() },
            onCapture: { model.capture($0, for: slot) },
            onReject: { model.rejectCapture($0, for: slot) },
            onClear: { model.clearBinding(slot) })
    }

    private var localCleanupModel: some View {
        CapturCard("Local cleanup models", symbol: "sparkles") {
            Text("Download a model, then select it in Modes → Cleanup. For fully local dictation, also choose on-device transcription.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.cleanupModels) { descriptor in
                cleanupModelRow(descriptor)
                Divider()
            }
            Text("Only one local cleanup model is kept in memory. Switching models unloads the previous one; modes using the same model keep it warm. Speech recognition has its own separate model. Failures keep the original text with a notice. No automatic cloud fallback.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.refreshCleanupModels() }
        .task { await model.observeCleanupMemory() }
    }

    @ViewBuilder
    private func cleanupModelRow(_ descriptor: CleanupModelDescriptor) -> some View {
        LabeledContent(descriptor.name, value: descriptor.format)
        Text(descriptor.detail).font(.caption).foregroundStyle(.secondary)
        Text("Limit: \(descriptor.inputLimitDescription)").font(.caption).foregroundStyle(.secondary)
        switch model.cleanupState(descriptor.id) {
        case .checking: ProgressView("Checking model…")
        case .notDownloaded:
            Button("Download \(descriptor.name)") { model.downloadCleanupModel(descriptor.id) }
        case .downloading(let progress):
            ProgressView(value: progress.fraction)
            Text(progress.detail).font(.caption)
            Button("Cancel download") { model.cancelCleanupDownload(descriptor.id) }
        case .ready(let updateAvailable):
            Label("Downloaded", systemImage: "checkmark.circle")
            if updateAvailable { Button("Update \(descriptor.name)") { model.downloadCleanupModel(descriptor.id) } }
            Button("Remove \(descriptor.name)", role: .destructive) { model.removeCleanupModel(descriptor.id) }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            Button("Retry download") { model.downloadCleanupModel(descriptor.id) }
        }
        cleanupMemoryStatus(descriptor.id)
    }

    @ViewBuilder
    private func cleanupMemoryStatus(_ choice: ModeCleanupChoice) -> some View {
        switch model.cleanupMemory[choice] ?? .unloaded {
        case .unloaded:
            Text("Not loaded in memory").font(.caption).foregroundStyle(.secondary)
            if case .ready = model.cleanupState(choice) {
                Button("Load into memory") { model.loadCleanupModel(choice) }
            }
        case .loading:
            ProgressView("Loading into memory…")
        case .ready:
            Label("Ready · loaded in memory", systemImage: "bolt.fill").font(.caption)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Transcription

    private var transcription: some View {
        CapturCard("Transcription", symbol: "waveform.badge.mic") {
            Toggle("Use on-device transcription", isOn: Binding(
                get: { model.usesLocalTranscription },
                set: { model.setUseLocalTranscription($0) }))

            Text("English speech-to-text can stay on this Mac. Models live in Captur's "
                 + "Application Support folder, survive app updates, and load from disk "
                 + "after the first download. Cleanup is selected separately for each mode in Modes. Modes using a cloud AI provider send the transcript and any enabled context to that provider for formatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.usesLocalTranscription { localModelTable }
            Toggle("Use vocabulary for speech recognition", isOn: $settings.speechVocabularyEnabled)
            Text("Supplies spelling hints to Whisper and Moonshine, and enables optional acoustic vocabulary boosting for Unified and Ultra. AI refinement and your explicit replacements keep their own vocabulary behavior.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.transcriptionProvider.supportsAcousticVocabularyBoosting {
                Toggle("Parakeet acoustic vocabulary boosting", isOn: $settings.parakeetVocabularyBoosting)
                    .disabled(!settings.speechVocabularyEnabled)
                Text("Optional CTC rescoring, limited to 60 seconds of audio per capture across segments. Full recordings over 60 seconds skip the extra final pass. Adds processing time and model memory; off by default. Download the additional model once before using it. Without the model, Captur keeps the original transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                switch model.vocabularyModelState {
                case .preparing: ProgressView("Preparing vocabulary model…")
                case .ready: Label("Vocabulary model ready", systemImage: "checkmark.circle")
                case .failed(let message): Text(message).foregroundStyle(.red)
                case .idle: EmptyView()
                }
                Button("Download / prepare vocabulary model") { model.prepareVocabularyModel() }
                    .disabled(model.vocabularyModelState == .preparing)
            }

            Toggle("Live transcription while recording", isOn: Binding(
                get: { model.liveTranscriptionEnabled },
                set: { model.setLiveTranscriptionEnabled($0) }))
                .disabled(!model.liveTranscriptionSupported)

            liveTranscriptionStatus

            if model.showsBatchFinalTranscriptionOption {
                Toggle("Recheck final text after recording", isOn: Binding(
                    get: { model.retranscribeFinalWithBatch },
                    set: { model.setRetranscribeFinalWithBatch($0) }))
                Text("Keeps live words in the capsule, then transcribes the complete "
                     + "recording once more before inserting. This is more accuracy-oriented, "
                     + "adds a short delay, and uses no network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Groq transcription model", selection: Binding(
                get: { model.selectedModel },
                set: { model.setTranscriptionModel($0) })) {
                ForEach(WhisperModel.allCases) { whisper in
                    Text(whisper.title).tag(whisper)
                }
            }
            .disabled(model.usesLocalTranscription)
            Text(model.selectedModel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Language", text: $languageDraft, prompt: Text("Detect automatically"))
                    .onSubmit { model.setTranscriptionLanguage(normalizedLanguage) }
                Button("Set") { model.setTranscriptionLanguage(normalizedLanguage) }
                    .disabled(normalizedLanguage == settings.transcriptionLanguage)
            }
            .disabled(model.usesLocalTranscription)
            Text(model.usesLocalTranscription
                 ? "Unified and Moonshine are English-only. Ultra detects its supported languages automatically; this setting applies to Groq."
                 : "A two-letter code such as en, de, fr. Leave it empty to let Whisper decide.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Low-latency segmentation", isOn: Binding(
                get: { settings.lowLatencySegmentation },
                set: { model.setLowLatencySegmentation($0) }))
                .help(model.usesLocalTranscription
                      ? "Prepares pause-delimited chunks before the final result. This is separate from live transcript previews."
                      : "Uploads each pause-delimited chunk while you are still speaking.")

            unwiredCaption
        }
    }

    private var aiProviders: some View {
        CapturCard("AI providers", symbol: "key") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Groq API key")
                GroqKeyField(model: model.keyModel, focus: $keyFieldFocused)
                Text("Used for Groq transcription and for modes whose refinement provider is Groq.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let openRouter = model.openRouterKeyModel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenRouter API key")
                    ProviderKeyField(model: openRouter, focus: $openRouterKeyFieldFocused)
                    Text("Used only by modes whose refinement provider is OpenRouter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Keys are stored in your login Keychain. They never enter preferences, "
                 + "dictation history, logs, or diagnostics.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var liveTranscriptionStatus: some View {
        let provider = model.selectedTranscriptionProvider
        switch provider.liveTranscriptionCapability {
        case .unsupported(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .included(let detail):
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .additionalDownload(let size, let detail):
            let state = model.liveTranscriptionModelState(provider)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(detail) Additional download: \(size).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .notDownloaded:
                    Text("Not downloaded. Turning live transcription on downloads it once and keeps it in Application Support.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .downloading(let progress):
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text(progress.detail)
                        Spacer()
                        Text(progressText(progress))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                case .ready(let updateAvailable):
                    HStack(spacing: 6) {
                        Label(
                            updateAvailable ? "Live model update available" : "Live model downloaded",
                            systemImage: updateAvailable
                                ? "arrow.down.circle" : "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(updateAvailable ? Color.orange : Color.green)
                        if updateAvailable {
                            Button("Upgrade") {
                                model.updateLiveTranscriptionModel(provider)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }
                    }
                case .failed(let message):
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var localModelTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                Text("SIZE").frame(width: 72, alignment: .leading)
                Text("STATUS").frame(width: 118, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            if model.unattributedLegacyDictationCount > 0 {
                Text("Legacy history · \(model.unattributedLegacyDictationCount) dictations · "
                     + "\(model.unattributedLegacyWords) raw words · "
                     + "\(StatsFormat.duration(model.unattributedLegacyAudioSeconds)) audio · "
                     + "provider/model unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }

            ForEach(Array(LocalModelDescriptor.all.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { Divider() }
                localModelRow(descriptor)
                    .padding(.vertical, 9)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func localModelRow(_ descriptor: LocalModelDescriptor) -> some View {
        let state = model.localModelState(descriptor.provider)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Button {
                    model.selectLocalModel(descriptor.provider)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: model.selectedLocalProvider == descriptor.provider
                              ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(descriptor.name).fontWeight(.medium)
                                if descriptor.isRecommended {
                                    Text("RECOMMENDED")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text("Available: \(descriptor.version)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let installed = model.localModelInstalledVersions[descriptor.provider] {
                                Text("Installed: \(installed)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(model.localModelSize(descriptor))
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)

                localModelAction(descriptor, state: state)
                    .frame(width: 118, alignment: .leading)
            }

            Text(descriptor.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 25)

            localModelUsage(descriptor.provider)
                .padding(.leading, 25)

            if let error = model.localModelErrors[descriptor.provider] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 25)
            }

            if case .downloading(let progress) = state {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text(progress.detail)
                        Spacer()
                        Text(progressText(progress))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 25)
            }
        }
    }

    @ViewBuilder
    private func localModelUsage(_ provider: TranscriptionProvider) -> some View {
        if !model.localModelUsageAvailable {
            Text("Usage unavailable until dictation history can be read.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            let usage = model.localModelUsage(for: provider)
            if usage.hasData {
                let latency = usage.latencyP50Ms.map { p50 in
                    usage.latencyP95Ms.map { " · latency p50 \(p50) ms / p95 \($0) ms" }
                        ?? " · latency p50 \(p50) ms"
                } ?? ""
                Text("Last 30 days · \(usage.dictationCount) dictations · "
                     + "\(usage.outputWordCount) words · "
                     + "\(StatsFormat.duration(usage.uniqueAudioSeconds)) unique / "
                     + "\(StatsFormat.duration(usage.processedAudioSeconds)) processed · "
                     + "\(usage.processedPassCount) passes"
                     + (usage.retryPassCount > 0 ? " · \(usage.retryPassCount) retries" : "")
                     + (usage.unsuccessfulPassCount > 0
                        ? " · \(usage.unsuccessfulPassCount) unsuccessful" : "")
                     + latency)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No attributed use in the last 30 days. Legacy history is not guessed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func localModelAction(
        _ descriptor: LocalModelDescriptor,
        state: LocalModelState
    ) -> some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small)
        case .notDownloaded:
            Button("Download") { model.downloadLocalModel(descriptor.provider) }
                .controlSize(.small)
        case .downloading:
            Text("Downloading")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready(let updateAvailable):
            HStack(spacing: 6) {
                if updateAvailable {
                    Button("Upgrade") { model.upgradeLocalModel(descriptor.provider) }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                }
                Button("Remove") { model.removeLocalModel(descriptor.provider) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .failed:
            Button("Retry") { model.downloadLocalModel(descriptor.provider) }
                .controlSize(.small)
        }
    }

    private func progressText(_ progress: LocalModelDownloadProgress) -> String {
        let percent = Int((progress.fraction * 100).rounded())
        guard let eta = progress.etaSeconds else { return "\(percent)%" }
        let seconds = max(0, Int(eta.rounded()))
        return seconds >= 60
            ? "\(percent)% · ~\((seconds + 59) / 60) min left"
            : "\(percent)% · ~\(seconds)s left"
    }

    private var normalizedLanguage: String {
        languageDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @ViewBuilder
    private var unwiredCaption: some View {
        if let notice = model.unwiredNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextSettings: some View {
        CapturCard("Context", symbol: "scope") {
            Toggle("Allow mode context", isOn: $settings.contextEnabled)
            Text("Choose what each mode can send in Modes → Context. All text sources are off by default. Local transcription can still use a cloud AI refinement mode.")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                Toggle("Use only recently copied clipboard text", isOn: $settings.recentClipboardOnly)
                Text("On: copy within about 3 seconds before recording. Off: use the current clipboard at recording start. Clipboard changes are sampled every half second; protected and oversized items are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Include the last copy made during recording", isOn: $settings.clipboardDuringRecording)
                Toggle("Activate modes by website", isOn: $settings.websiteActivation)
                Text("Exact domain matches take priority over app rules; a dedicated mode shortcut takes priority over both. Supported browsers must expose their active document URL through Accessibility. No URL available means the app rule wins.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.websiteActivation {
                    ForEach(settings.websiteModes.keys.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text(availableModes().first { $0.id == settings.websiteModes[host] }?.name ?? "Unavailable mode").foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) { settings.websiteModes.removeValue(forKey: host) }
                        }
                    }
                    HStack {
                        TextField("Domain, e.g. mail.google.com", text: $websiteDraft)
                        Picker("Mode", selection: $websiteModeDraft) {
                            ForEach(availableModes()) { mode in Text(mode.name).tag(mode.id) }
                        }
                        Button("Add rule") {
                            guard let host = WebsiteContext.normalizedRule(websiteDraft),
                                  !websiteModeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                websiteError = "Enter a domain without a path and choose a mode."
                                return
                            }
                            settings.websiteModes[host] = websiteModeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            websiteDraft = ""
                            websiteError = nil
                        }
                    }
                    Text("If a custom mode is deleted, its website rule falls back to the app or default mode.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let websiteError { Text(websiteError).foregroundStyle(.red) }
                }
            }.disabled(!settings.contextEnabled)
            Toggle("Preserve start clipboard while website routing resolves", isOn: $settings.clipboardBeforeWebsiteResolution)
                .disabled(!settings.contextEnabled)
            Text("Off: read clipboard only after the resolved mode permits it; a copy changed during routing may be omitted. On: temporarily read the start clipboard if any possible website mode allows it, even if the resolved mode does not, then discard it if disallowed.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check editor compatibility…") { model.probeEditorContext() }
                .disabled(model.contextProbeRunning)
            Text("Checks bounded selection, editor text, domain and field labels after 3 seconds. Shows counts only; sends nothing and saves no text. Switch to your target editor after clicking.")
                .font(.caption).foregroundStyle(.secondary)
            if let report = model.contextProbeResult { Text(report).font(.caption).textSelection(.enabled) }
            Toggle("Save context counts and availability in History", isOn: $settings.storeContextMetadata)
            Text("Saves source sizes and capture time only. Selected text, editor text, clipboard text and website domains are never saved as context. Full name and computer name are never collected. Existing transcript and audio retention settings still apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy

    /// Spec §16. Four controls, one of which deletes the user's data irreversibly — so
    /// it asks first, and the question says how much is about to go.
    private var privacy: some View {
        CapturCard("Privacy", symbol: "hand.raised") {
            Picker("Keep audio for", selection: Binding(
                get: { settings.retentionPolicy },
                set: { model.setRetentionPolicy($0) })) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            Text(settings.retentionPolicy.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = model.retentionNotice {
                warning(notice)
            }

            LabeledContent("Audio on disk") { diskUsageLabel }

            LabeledContent("") {
                Button("Delete All Audio…", role: .destructive) {
                    model.requestDeleteAllAudio()
                }
                .disabled(!model.canDeleteAllAudio || model.isDeletingAllAudio)
            }

            if let reason = model.deleteAllDisabledReason {
                warning(reason)
            }

            Toggle("Never store audio", isOn: Binding(
                get: { settings.neverStoreAudio },
                set: { model.setNeverStoreAudio($0) }))
            Text("Deletes each recording the moment it has been transcribed. History keeps "
                 + "the text; playback and retry are lost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = model.neverStoreAudioNotice {
                warning(notice)
            }

            if let error = model.privacyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Delete all audio?", isPresented: Binding(
            get: { model.pendingDeleteAll != nil },
            set: { if !$0 { model.cancelDeleteAllAudio() } })) {
            Button("Cancel", role: .cancel) { model.cancelDeleteAllAudio() }
            Button("Delete", role: .destructive) { model.confirmDeleteAllAudio() }
        } message: {
            Text(model.pendingDeleteAll?.message ?? "")
        }
    }

    /// A size, or an honest "Unknown". Never a zero standing in for an answer nobody
    /// has — the same rule the AI spend row follows.
    @ViewBuilder
    private var diskUsageLabel: some View {
        switch model.audioDiskUsage {
        case .loading:
            Text(model.audioDiskUsageText).foregroundStyle(.secondary)
        case .bytes:
            Text(model.audioDiskUsageText)
        case .unavailable(let reason):
            Label(model.audioDiskUsageText, systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(reason)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Permissions

    /// The same rows as the setup checklist, from the same controller, refreshed the
    /// same way — on window open and on app activation. No timer.
    private var permissionSection: some View {
        CapturCard("Permissions", symbol: "checkmark.shield", caption: "Captur reads the same prerequisite state shown during setup.") {
            ForEach(permissions.prerequisites.filter {
                $0.id != .groqKey && $0.id != .openRouterKey
            }) { prerequisite in
                HStack(spacing: 10) {
                    Image(systemName: prerequisite.isSatisfied ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(prerequisite.isSatisfied ? Color.green : Color.secondary)
                        .accessibilityLabel(prerequisite.isSatisfied ? "Granted" : "Not granted")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(FirstRunView.title(for: prerequisite.id))
                        Text(FirstRunView.detail(for: prerequisite.id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button(FirstRunView.actionTitle(for: prerequisite.id,
                                                    isSatisfied: prerequisite.isSatisfied)) {
                        model.requestPermission(prerequisite.id)
                    }
                }
            }

            LabeledContent("") {
                Button("Re-check") { model.refreshPermissions() }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        CapturCard("Diagnostics", symbol: "stethoscope", caption: "The self-test records locally and keeps diagnostic evidence explicit.") {
            LabeledContent("Audio self-test") {
                Button("Open Diagnostics…") { model.openDiagnostics() }
            }
        }
    }

    // MARK: - About

    private var about: some View {
        CapturCard("About Captur", symbol: "info.circle") {
            LabeledContent("Version", value: "\(model.version) (\(model.build))")
            LabeledContent("AI this month") { spendLabel }
            LabeledContent("On-device speech") {
                Link("FluidAudio · Parakeet Unified",
                     destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
            }
        }
    }

    /// Real data or an honest absence. Never a fabricated number.
    @ViewBuilder
    private var spendLabel: some View {
        switch model.spend {
        case .loading:
            Text("Reading the dictation log…").foregroundStyle(.secondary)
        case .amount(_, let dictations) where dictations == 0:
            Text("Nothing yet this month").foregroundStyle(.secondary)
        case .amount(let usd, let dictations):
            Text((model.spendUnknownCostCount > 0 ? "At least " : "")
                 + "\(Self.currency.string(from: usd as NSNumber) ?? "—") "
                 + "· \(dictations) dictation\(dictations == 1 ? "" : "s")"
                 + (model.spendUnknownCostCount > 0
                    ? " · \(model.spendUnknownCostCount) unknown"
                    : ""))
        case .unavailable(let reason):
            Label(reason, systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    /// Four decimals: a month of dictation costs cents, and `$0.00` would read as free.
    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter
    }()
}
