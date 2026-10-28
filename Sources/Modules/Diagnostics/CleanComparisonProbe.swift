import Foundation

/// Replays a public fixture through actual ASR and both cleanup choices. Runs
/// before app composition/migration; never inserts text or changes preferences.
@MainActor
enum CleanComparisonProbe {
    struct Fixture: Decodable {
        let id: String
        let transcript: String
        let audioPath: String?
    }

    static func run(arguments: [String]) async -> Bool {
        guard let index = arguments.firstIndex(of: "--compare-clean"), index + 2 < arguments.count else {
            print("Usage: Captur --compare-clean fixtures.json model-directory")
            return false
        }
        do {
            let fixtures = try JSONDecoder().decode([Fixture].self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
            let root = URL(fileURLWithPath: arguments[index + 2])
            let registry = LocalCleanupRegistry.builtIn
            let choice: ModeCleanupChoice
            if let index = arguments.firstIndex(of: "--cleanup-model") {
                guard index + 1 < arguments.count, let selected = ModeCleanupChoice(rawValue: arguments[index + 1]) else {
                    throw CleanupProbe.ProbeError.usage
                }
                choice = selected
            } else { choice = .localS1Mini }
            guard let registration = registry.registration(choice) else { throw LocalCleanupError.unavailable(choice) }
            let local = registration.makeRuntime(root)
            if arguments.contains("--download-local-model") {
                try await local.download { progress in
                    if progress.fraction == 1 { print(progress.detail) }
                }
                print("DOWNLOAD VERIFIED \(registration.model.usageModelID)")
            }
            let settings = AppSettings()
            // Copy mode preferences before loading so even recovery of a malformed
            // file cannot rename or write the user's mode settings.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let modeFile = AppPaths.supportDirectory().appendingPathComponent("modes.json")
            if FileManager.default.fileExists(atPath: modeFile.path) {
                try FileManager.default.copyItem(at: modeFile, to: scratch.appendingPathComponent("modes.json"))
            }
            let mode = ModeStore(directory: scratch).mode(id: "clean") ?? .clean
            let key = mode.refinementProvider == .groq ? settings.groqAPIKey : settings.openRouterAPIKey
            let cloud = ProviderRefinementClient()
            print("MODEL \(registration.model.usageModelID)")
            print("BASELINE \(mode.refinementProvider.rawValue) \(mode.model) \(mode.reasoningEffort.rawValue) temp=\(mode.temperature)")
            print("ASR \(settings.transcriptionProvider.rawValue); replay latency = ASR + cleanup, excludes microphone finalization and OS insertion")
            let succeeded = await compare(fixtures: fixtures, local: local, registration: registration,
                          settings: settings, mode: mode, key: key, cloud: cloud)
            await local.unload()
            return succeeded
        } catch {
            print("COMPARE FAILED: \(error)")
            return false
        }
    }

    private static func compare(fixtures: [Fixture], local: any ManagedLocalCleanup,
                                registration: LocalCleanupRegistration, settings: AppSettings,
                                mode: Mode, key: String?, cloud: ProviderRefinementClient) async -> Bool {
        var succeeded = true
        do {
            for fixture in fixtures {
                var raw = fixture.transcript
                var asrMs = 0.0
                if let path = fixture.audioPath {
                    let start = Date()
                    let url = URL(fileURLWithPath: path)
                    switch settings.transcriptionProvider {
                    case .groq:
                        raw = try await GroqClient().transcribe(fileURL: url, apiKey: settings.groqAPIKey ?? "", prompt: nil, model: settings.transcriptionModel)
                    case .localUnified:
                        guard await FluidAudioTranscriptionRuntime.shared.availability().isDownloaded else { throw S1MiniError.notDownloaded }
                        raw = try await FluidAudioTranscriptionRuntime.shared.transcribe(fileURL: url)
                    case .localMoonshine:
                        guard await MoonshineTranscriptionRuntime.shared.availability().isDownloaded else { throw S1MiniError.notDownloaded }
                        raw = try await MoonshineTranscriptionRuntime.shared.transcribe(fileURL: url)
                    case .localUltra:
                        guard await UltraTranscriptionRuntime.shared.availability().isDownloaded else { throw S1MiniError.notDownloaded }
                        raw = try await UltraTranscriptionRuntime.shared.transcribe(fileURL: url)
                    case .localPhonon:
                        raw = try await PhononTranscriptionRuntime.shared.transcribe(fileURL: url)
                    }
                    asrMs = Date().timeIntervalSince(start) * 1_000
                }
                for choice in ["local", "current"] {
                    let start = Date()
                    var row: [String: Any] = ["id": fixture.id, "choice": choice, "raw": raw, "asrMs": asrMs]
                    do {
                        let text: String
                        if choice == "local" {
                            var localMode = mode
                            localMode.cleanupChoice = registration.model.id
                            let prompt = localMode.usesModePrompt ? PromptAssembler.systemMessage(
                                mode: localMode, vocabularyTerms: [], appName: nil, clipboard: nil) : ""
                            text = try await local.clean(raw, request: .init(choice: registration.model.id,
                                systemMessage: prompt, temperature: localMode.temperature))
                        }
                        else {
                            text = try await cloud.complete(
                                systemMessage: PromptAssembler.systemMessage(mode: mode, vocabularyTerms: [], appName: nil, clipboard: nil),
                                userMessage: raw, provider: mode.refinementProvider, model: mode.model,
                                reasoning: mode.reasoningEffort, temperature: mode.temperature, apiKey: key ?? "",
                                timeout: mode.refinementProvider.defaultTimeout, onDelta: { _ in }).text
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                throw RefinementError.decoding(mode.refinementProvider)
                            }
                        }
                        row["output"] = text
                        row["cleanupMs"] = Date().timeIntervalSince(start) * 1_000
                        row["replayTotalMs"] = asrMs + Date().timeIntervalSince(start) * 1_000
                    } catch {
                        succeeded = false
                        row["error"] = error.localizedDescription
                        row["fallback"] = raw
                    }
                    row["cleanupMs"] = Date().timeIntervalSince(start) * 1_000
                    row["replayTotalMs"] = asrMs + Date().timeIntervalSince(start) * 1_000
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                }
            }
            return succeeded
        } catch {
            print("COMPARE FAILED: \(error)")
            return false
        }
    }
}
