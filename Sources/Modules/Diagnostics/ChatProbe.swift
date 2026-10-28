import Foundation

/// `Captur --probe-chat` — does the mode transformation actually work against its
/// configured provider?
///
/// The seventh instrument, and it exists because `GroqChatClient` shipped with 18 tests,
/// zero of which had ever met the real API. Its SSE field names, its `[DONE]` sentinel
/// and its model ids all follow the OpenAI-compatible contract *on paper*; the agent that
/// wrote it said plainly that none of it was verified against a live request, because it
/// was forbidden from making one.
///
/// That is the exact shape of every bug this project has had: code that is correct by
/// construction, tested by its own assumptions, and wrong about the world. A stub cannot
/// tell you that a provider renamed a field.
@MainActor
enum ChatProbe {

    static func run(modeID: String?) async {
        let store = ModeStore(directory: AppPaths.supportDirectory())
        let mode = (modeID.flatMap { store.mode(id: $0) })
            ?? Mode.builtIns.first { $0.usesLLM }
            ?? Mode.verbatim

        let key: String
        switch mode.refinementProvider {
        case .groq: key = Keychain.apiKey() ?? ""
        case .openRouter: key = Keychain.openRouterAPIKey() ?? ""
        }
        guard !key.isEmpty else {
            print("No \(mode.refinementProvider.title) API key in the Keychain — nothing to probe.")
            return
        }

        // Deliberately messy: filler words, a false start, and a spoken punctuation mark.
        // A pass-through would leave every one of them in place, so the transcript itself
        // says whether the model did anything.
        let dictation = "um so i think we should uh ship the thing on friday comma "
            + "actually no wait lets ship it on thursday period"

        let systemMessage = PromptAssembler.systemMessage(
            mode: mode,
            vocabularyTerms: [],
            appName: "Notes",
            clipboard: nil)

        print("--- chat probe ---")
        print("  mode       \(mode.name) (\(mode.id))  usesLLM=\(mode.usesLLM)")
        print("  provider   \(mode.refinementProvider.title)")
        print("  model      \(mode.model)")
        print("  thinking   \(mode.reasoningEffort.title)")
        print("  temp       \(mode.temperature)")
        print("  timeout    \(mode.refinementProvider.defaultTimeout)s")
        print("")
        print("  in:  \(dictation)")

        guard mode.usesLLM else {
            print("\n  This mode does not use an LLM — nothing to send. "
                  + "Pass a mode id, e.g. --probe-chat clean")
            return
        }

        let client = ProviderRefinementClient()
        let deltaCounter = DeltaCounter()
        let startedAt = Date()
        do {
            let result = try await client.complete(
                systemMessage: systemMessage,
                userMessage: dictation,
                provider: mode.refinementProvider,
                model: mode.model,
                reasoning: mode.reasoningEffort,
                temperature: mode.temperature,
                apiKey: key,
                timeout: mode.refinementProvider.defaultTimeout,
                onDelta: { _ in deltaCounter.increment() })
            let elapsed = Date().timeIntervalSince(startedAt) * 1_000
            let deltas = deltaCounter.value

            print("  out: \(result.text)")
            print("")
            print(String(format: "  %.0f ms, %d streamed deltas", elapsed, deltas))
            if let usage = result.usage {
                print("  tokens     \(usage.promptTokens ?? 0) in / "
                      + "\(usage.completionTokens ?? 0) out / "
                      + "\(usage.reasoningTokens ?? 0) thinking")
                if let cost = usage.costUSD {
                    print("  cost       $\(cost) (\(usage.costKind.rawValue))")
                } else {
                    print("  cost       unknown")
                }
            } else {
                print("  usage      no final receipt")
            }
            // A single delta carrying everything would mean the stream was not really a
            // stream — worth knowing, because the whole client is built around it being one.
            if deltas <= 1 { print("  ⚠︎ only \(deltas) delta — the response did not stream") }
            if result.text == dictation {
                print("  ⚠︎ output is identical to input — nothing was applied")
            }
            if elapsed > mode.refinementProvider.defaultTimeout * 1_000 {
                print("  ⚠︎ slower than the configured timeout: "
                      + "a real dictation would fall back to raw")
            }
        } catch {
            // The failure IS the finding. This is the one path that cannot be checked
            // against a stub, so print it exactly rather than summarising it.
            print("")
            print("  FAILED: \(error)")
            print("  A mode transformation would fall back to the raw transcript here —")
            print("  which is the specified behaviour, but it means modes do nothing.")
        }
    }

    private final class DeltaCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
