import Foundation

/// Isolated text-only checks. No app composition, stores, microphone, insertion or cloud.
enum CleanupProbe {
    struct Options {
        let choice: ModeCleanupChoice
        let root: URL
        let fixtures: URL?
        let download: Bool

        init(arguments: [String], registry: LocalCleanupRegistry = .builtIn) throws {
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else { return nil }
                return arguments[index + 1]
            }
            guard let id = value("--probe-cleanup"), let choice = ModeCleanupChoice(rawValue: id),
                  let directory = value("--model-directory") else { throw ProbeError.usage }
            guard registry.model(choice) != nil else { throw LocalCleanupError.unavailable(choice) }
            self.choice = choice
            root = URL(fileURLWithPath: directory, isDirectory: true)
            if arguments.contains("--fixtures"), value("--fixtures") == nil { throw ProbeError.usage }
            fixtures = value("--fixtures").map { URL(fileURLWithPath: $0) }
            download = arguments.contains("--download-model")
        }
    }
    enum ProbeError: LocalizedError {
        case usage
        var errorDescription: String? {
            "Use --probe-cleanup <registered-id> --model-directory <isolated-directory> [--fixtures <json>] [--download-model]"
        }
    }

    static func run(arguments: [String], registry: LocalCleanupRegistry = .builtIn) async -> Bool {
        do {
            let options = try Options(arguments: arguments, registry: registry)
            guard let registration = registry.registration(options.choice) else { throw LocalCleanupError.unavailable(options.choice) }
            let fixtures: [CleanComparisonProbe.Fixture]
            if let url = options.fixtures {
                fixtures = try JSONDecoder().decode([CleanComparisonProbe.Fixture].self, from: Data(contentsOf: url))
            } else {
                fixtures = [.init(id: "correction", transcript: "um send the report thursday no friday", audioPath: nil),
                            .init(id: "question", transcript: "could you tell me when the meeting starts", audioPath: nil)]
            }
            let coordinator = LocalCleanupCoordinator(registry: registry,
                runtimes: [options.choice: registration.makeRuntime(options.root)])
            var succeeded = true
            do {
                if options.download { try await coordinator.download(options.choice) { _ in } }
                let start = Date()
                try await coordinator.prepare(options.choice)
                emit(["model": registration.model.usageModelID, "choice": options.choice.rawValue,
                      "loadMs": Int(Date().timeIntervalSince(start) * 1_000)])
                var mode = Mode.clean
                mode.cleanupChoice = options.choice
                let prompt = mode.usesModePrompt(in: registry) ? PromptAssembler.systemMessage(
                    mode: mode, vocabularyTerms: [], appName: nil, clipboard: nil, registry: registry) : ""
                for fixture in fixtures {
                    try Task.checkCancellation()
                    let start = Date()
                    var row: [String: Any] = ["id": fixture.id, "model": registration.model.usageModelID,
                                              "choice": options.choice.rawValue, "input": fixture.transcript]
                    do {
                        row["output"] = try await coordinator.clean(fixture.transcript, request: .init(
                            choice: options.choice, systemMessage: prompt, temperature: 0))
                    } catch {
                        succeeded = false
                        row["error"] = error.localizedDescription
                        row["fallback"] = fixture.transcript
                    }
                    row["cleanupMs"] = Int(Date().timeIntervalSince(start) * 1_000)
                    emit(row)
                }
            } catch {
                succeeded = false
                emit(["error": error.localizedDescription, "choice": options.choice.rawValue])
            }
            await coordinator.shutdown()
            return succeeded
        } catch {
            emit(["error": error.localizedDescription])
            return false
        }
    }

    private static func emit(_ row: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }
}
