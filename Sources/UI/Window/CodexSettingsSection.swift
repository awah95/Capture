import SwiftUI

struct CodexSettingsSection: View {
    let integration: CodexIntegration
    @ObservedObject var settings: AppSettings

    var body: some View {
        CapturCard("Codex CLI", symbol: "terminal") {
            Toggle("Enable installed Codex CLI for mode correction", isOn: $settings.codexCLIEnabled)
            Text("Advanced option. Dictated text and enabled context go to your Codex account. "
                 + "This runs the Codex agent in a read-only sandbox, not a tool-free text API. "
                 + "The sandbox permits reads; stopping a tool attempt cannot undo an action already run.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.codexCLIEnabled {
                TextField("Codex executable path (blank = automatic)", text: $settings.codexExecutablePath)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Refresh models") { Task { await integration.refresh() } }
                        .disabled(integration.isRefreshing)
                    if integration.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text(integration.status).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Install Codex and run codex login in Terminal. Capture lets Codex manage its own login; "
                     + "no API key is copied into Capture. Choose Codex CLI, a model, and its thinking effort in each mode. "
                     + "Hidden text models are included. Catalog entries do not guarantee account access. "
                     + "Corrections use standard CLI authentication with custom CLI configuration and rules ignored. "
                     + "Temperature is not sent to Codex. Requests stop after two minutes and retain your transcript on failure.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: settings.codexCLIEnabled) { await integration.refreshIfNeeded() }
    }
}
