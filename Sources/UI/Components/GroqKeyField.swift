import SwiftUI

/// What the last validation attempt concluded. `untested` is the honest default:
/// a key that has been saved but not exercised is not yet known to work.
enum GroqKeyValidation: Equatable {
    case untested
    case validating
    case valid
    /// A message safe to show a user. It never contains the key.
    case failed(String)
}

/// The state behind `GroqKeyField`.
///
/// Split from the view so the rules that matter — trimming, empty-means-delete, and
/// the mapping from HTTP status to a sentence — are testable without a window.
///
/// Two invariants hold throughout: the key is never written anywhere except the
/// injected store (so never `UserDefaults`, never a log line, never a diagnostic
/// report), and a stored key is never read back into the visible field.
@MainActor
final class GroqKeyFieldModel: ObservableObject {

    /// What the user has typed or pasted. Cleared on save.
    @Published var draft: String = ""
    @Published private(set) var validation: GroqKeyValidation = .untested
    /// Whether a key exists in the store. The user is told *that* a key is saved,
    /// never *which* key.
    @Published private(set) var hasStoredKey: Bool

    /// `nonisolated` because it is used as a default argument to `init`, which is
    /// evaluated outside the actor. A main-actor-isolated constant there is a warning
    /// today and an error under Swift 6. `URL?` is `Sendable`, so this is free.
    nonisolated static let defaultValidationEndpoint =
        URL(string: "https://api.groq.com/openai/v1/models")

    private let store: any GroqKeyStoring
    private let session: URLSession
    private let endpoint: URL?

    init(store: any GroqKeyStoring,
         session: URLSession = .shared,
         endpoint: URL? = GroqKeyFieldModel.defaultValidationEndpoint) {
        self.store = store
        self.session = session
        self.endpoint = endpoint
        self.hasStoredKey = Self.isPresent(store.groqKey())
    }

    /// Writes the trimmed draft. An empty (or whitespace-only) field deletes the
    /// stored key rather than saving `""`.
    func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
            return
        }
        store.setGroqKey(trimmed)
        hasStoredKey = true
        draft = ""
        // A new key invalidates the old verdict. Saying "valid" about a key that was
        // never tested is exactly the failure this field exists to prevent.
        validation = .untested
    }

    func clear() {
        store.setGroqKey(nil)
        hasStoredKey = false
        draft = ""
        validation = .untested
    }

    /// Asks Groq whether the key actually works: `GET /openai/v1/models`, the cheapest
    /// authenticated call the API has. Uses the draft if the user has typed one,
    /// otherwise the stored key — so "Save, then Validate" and "Validate what I already
    /// have" both do the obvious thing.
    func validate() async {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty
            ? (store.groqKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : typed

        guard !key.isEmpty else {
            validation = .failed("Enter a key first.")
            return
        }
        guard let endpoint else {
            validation = .failed("The Groq endpoint is misconfigured.")
            return
        }

        validation = .validating

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                validation = .failed("Groq's reply could not be read.")
                return
            }
            validation = Self.verdict(forStatus: http.statusCode)
        } catch {
            // `error` is a URLError or a decoding error; neither carries the key.
            validation = .failed("Could not reach Groq: \(error.localizedDescription)")
        }
    }

    /// HTTP status → a sentence the user can act on. Never quotes the key.
    static func verdict(forStatus status: Int) -> GroqKeyValidation {
        switch status {
        case 200...299:
            return .valid
        case 401:
            return .failed("Groq rejected that key (HTTP 401). Check you pasted the whole key.")
        case 403:
            return .failed("That key is not allowed to list models (HTTP 403).")
        case 429:
            return .failed("Rate limited (HTTP 429). The key looks fine — try again shortly.")
        default:
            return .failed("Groq answered HTTP \(status).")
        }
    }

    private static func isPresent(_ key: String?) -> Bool {
        !(key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}

/// The Groq API key field. Reused verbatim by Settings (Task 25) — it must not be
/// reimplemented there.
struct GroqKeyField: View {
    @ObservedObject var model: GroqKeyFieldModel
    /// Owned by the host so the checklist can move the caret here when the user
    /// presses the key row's button.
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(model.hasStoredKey ? "A key is saved — paste a new one to replace it"
                                           : "gsk_…",
                        text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .focused(focus)
                .onSubmit { model.save() }

            HStack(spacing: 8) {
                Button(saveTitle) { model.save() }
                    .disabled(saveDisabled)

                Button("Test key") {
                    Task { await model.validate() }
                }
                .disabled(model.validation == .validating || (!model.hasStoredKey && isDraftEmpty))

                statusLabel
            }
        }
    }

    private var isDraftEmpty: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An empty field deletes the key, so the button must say so. A "Save" that
    /// silently wipes a working key on a stray click is the kind of thing that only
    /// gets found in the field.
    private var saveTitle: String {
        (isDraftEmpty && model.hasStoredKey) ? "Remove saved key" : "Save"
    }

    private var saveDisabled: Bool {
        isDraftEmpty && !model.hasStoredKey
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.validation {
        case .untested:
            if model.hasStoredKey {
                Label("Saved, not tested", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
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
