import Foundation
import Observation

@MainActor
@Observable
final class CodexIntegration {
    private var catalogModels: [CodexModel] = []
    private(set) var isRefreshing = false
    private(set) var signedIn = false
    private(set) var lastRefreshed: Date?
    private(set) var error: String?
    private let settings: AppSettings
    private let discover: @Sendable (CodexConfiguration) async throws -> CodexCatalog
    private var lastConfiguration: CodexConfiguration?

    init(settings: AppSettings,
         discover: @escaping @Sendable (CodexConfiguration) async throws -> CodexCatalog = {
             try await CodexCLIService.discover(configuration: $0)
         }) {
        self.settings = settings
        self.discover = discover
    }

    var configuration: CodexConfiguration {
        CodexConfiguration(enabled: settings.codexCLIEnabled, executablePath: settings.codexExecutablePath)
    }

    var models: [CodexModel] {
        configuration.enabled && lastConfiguration == configuration ? catalogModels : []
    }

    var preferredModel: CodexModel? {
        models.first { $0.id == "gpt-6.1-terra" }
            ?? models.first { $0.isDefault } ?? models.first
    }

    var status: String {
        if !settings.codexCLIEnabled { return "Codex CLI is off." }
        if isRefreshing { return "Discovering models and reasoning options…" }
        if lastRefreshed != nil, lastConfiguration != configuration {
            return "Codex executable changed. Refresh models for this installation."
        }
        if let error { return error }
        if let lastRefreshed {
            return "\(models.count) text models discovered · updated \(lastRefreshed.formatted(date: .omitted, time: .shortened)). "
                + (signedIn ? "Codex manages your login." : "Run codex login in Terminal before using a model.")
        }
        return "Enable Codex and refresh to discover models for its current account."
    }

    func model(_ id: String) -> CodexModel? { models.first { $0.id == id } }

    func refreshIfNeeded() async {
        guard configuration.enabled else { return }
        if lastConfiguration == configuration, let lastRefreshed,
           Date().timeIntervalSince(lastRefreshed) < 300 { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let requested = configuration
        guard requested.enabled else { return }
        if lastConfiguration != requested { catalogModels = []; lastRefreshed = nil; signedIn = false }
        isRefreshing = true
        error = nil
        defer { isRefreshing = false }
        do {
            let catalog = try await discover(requested)
            guard !Task.isCancelled, configuration == requested else { return }
            catalogModels = catalog.models
            signedIn = catalog.signedIn
            lastRefreshed = Date()
            lastConfiguration = requested
            if models.isEmpty { error = "Codex returned no text-capable models. Check its account and CLI version." }
        } catch is CancellationError {
            // Navigating away never turns a cancelled refresh into a setup failure.
        } catch {
            guard configuration == requested else { return }
            self.error = error.localizedDescription
                + (models.isEmpty ? "" : " Previously discovered models are still listed; refresh to verify availability.")
        }
    }
}
