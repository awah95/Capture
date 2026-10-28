import Foundation

/// Checks the installed CLI without constructing app stores, capturing audio, or inserting text.
/// Discovery alone sends no correction. --correct sends only this fixed synthetic fixture.
enum CodexProbe {
    static func run(arguments: [String]) async -> Bool {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        do {
            let configuration = CodexConfiguration(enabled: true, executablePath: value("--codex-path") ?? "")
            let catalog = try await CodexCLIService.discover(configuration: configuration)
            print("Codex login available: \(catalog.signedIn)")
            for model in catalog.models {
                print("\(model.id)\(model.hidden ? " [hidden]" : ""): \(model.efforts.map(\.rawValue).joined(separator: ", "))")
            }
            if arguments.contains("--correct") {
                guard catalog.signedIn else { throw CodexError.signedOut }
                guard let model = value("--model") ?? catalog.models.first(where: { $0.isDefault })?.id
                    ?? catalog.models.first?.id else { throw CodexError.invalidResponse }
                let effort = value("--effort").flatMap(ReasoningEffort.init(rawValue:)) ?? .providerDefault
                let output = try await CodexCLIService.correct(configuration: configuration,
                    systemMessage: PromptAssembler.systemMessage(mode: .clean, vocabularyTerms: [], appName: nil, clipboard: nil),
                    text: "um send the sample report thursday no friday", model: model, effort: effort, timeout: 120)
                print("Synthetic correction (\(model), \(effort.rawValue)): \(output)")
            }
            return true
        } catch {
            print("Codex check failed: \(error.localizedDescription)")
            return false
        }
    }
}
