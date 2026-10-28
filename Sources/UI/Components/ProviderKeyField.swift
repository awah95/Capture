import SwiftUI

enum ProviderKeyValidation: Equatable {
    case untested
    case validating
    case valid
    case failed(String)
}

/// Key-field state for providers added after Captur's original Groq-only setup.
/// The visible draft is cleared on save and the stored secret is never read back.
@MainActor
final class ProviderKeyFieldModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var validation: ProviderKeyValidation = .untested
    @Published private(set) var hasStoredKey: Bool

    let provider: RefinementProviderID
    private let read: () -> String?
    private let write: (String?) -> Void
    private let session: URLSession
    private let endpoint: URL

    init(
        provider: RefinementProviderID,
        read: @escaping () -> String?,
        write: @escaping (String?) -> Void,
        session: URLSession = .shared,
        endpoint: URL? = nil
    ) {
        self.provider = provider
        self.read = read
        self.write = write
        self.session = session
        self.endpoint = endpoint ?? Self.validationEndpoint(for: provider)
        hasStoredKey = !(read()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
            return
        }
        write(trimmed)
        hasStoredKey = true
        draft = ""
        validation = .untested
    }

    func clear() {
        write(nil)
        hasStoredKey = false
        draft = ""
        validation = .untested
    }

    func validate() async {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty
            ? (read()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : typed
        guard !key.isEmpty else {
            validation = .failed("Enter a key first.")
            return
        }

        validation = .validating
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                validation = .failed("\(provider.title)'s reply could not be read.")
                return
            }
            switch http.statusCode {
            case 200...299: validation = .valid
            case 401:
                validation = .failed("\(provider.title) rejected that key (HTTP 401).")
            case 403:
                validation = .failed("That key is not allowed to access this account (HTTP 403).")
            case 429:
                validation = .failed("Rate limited (HTTP 429). Try again shortly.")
            default:
                validation = .failed("\(provider.title) answered HTTP \(http.statusCode).")
            }
        } catch {
            validation = .failed("Could not reach \(provider.title): \(error.localizedDescription)")
        }
    }

    nonisolated private static func validationEndpoint(for provider: RefinementProviderID) -> URL {
        switch provider {
        case .groq: return URL(string: "https://api.groq.com/openai/v1/models")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/key")!
        }
    }
}

struct ProviderKeyField: View {
    @ObservedObject var model: ProviderKeyFieldModel
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(model.hasStoredKey
                        ? "A key is saved — paste a new one to replace it"
                        : placeholder,
                        text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .focused(focus)
                .onSubmit { model.save() }

            HStack(spacing: 8) {
                Button(saveTitle) { model.save() }
                    .disabled(isDraftEmpty && !model.hasStoredKey)
                Button("Test key") { Task { await model.validate() } }
                    .disabled(model.validation == .validating
                              || (!model.hasStoredKey && isDraftEmpty))
                status
            }
        }
    }

    private var placeholder: String {
        model.provider == .openRouter ? "sk-or-v1-…" : "gsk_…"
    }

    private var isDraftEmpty: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var saveTitle: String {
        isDraftEmpty && model.hasStoredKey ? "Remove saved key" : "Save"
    }

    @ViewBuilder private var status: some View {
        switch model.validation {
        case .untested:
            if model.hasStoredKey {
                Label("Saved, not tested", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .valid:
            Label("Key works", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
