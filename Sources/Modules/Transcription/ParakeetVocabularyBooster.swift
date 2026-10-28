import FluidAudio
import Foundation

/// Optional CTC rescoring. Kept outside the shared ASR managers so vocabulary from
/// overlapping captures cannot change another capture's decoder configuration.
actor ParakeetVocabularyBooster {
    static let shared = ParakeetVocabularyBooster()
    nonisolated static let maximumSamples = 60 * 16_000
    private var models: CtcModels?
    private var tokenizer: CtcTokenizer?
    private var preparation: Task<(CtcModels, CtcTokenizer), Error>?
    private var cachedTerms: [String] = []
    private var cachedSession: VocabularyBoostingSession?
    private var cachedInverseTextNormalized = true

    nonisolated static var isDownloaded: Bool {
        let directory = CtcModels.defaultCacheDirectory()
        return CtcModels.modelsExist(at: directory) &&
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
    }

    /// Downloads are explicit Settings actions; dictation never downloads this model.
    func prepare(allowDownload: Bool) async throws {
        if models != nil, tokenizer != nil { return }
        if let preparation {
            let loaded = try await preparation.value
            models = loaded.0; tokenizer = loaded.1
            return
        }
        guard allowDownload || Self.isDownloaded else { throw CocoaError(.fileNoSuchFile) }
        let task = Task<(CtcModels, CtcTokenizer), Error> {
            let directory = CtcModels.defaultCacheDirectory()
            if allowDownload { try await CtcModels.download() }
            let models = try await CtcModels.load(from: directory)
            let tokenizer = try await CtcTokenizer.load(from: directory)
            return (models, tokenizer)
        }
        preparation = task
        do {
            let loaded = try await task.value
            models = loaded.0; tokenizer = loaded.1
            preparation = nil
        } catch {
            preparation = nil
            throw error
        }
    }

    func rescore(text: String, timings: [TokenTiming], samples: [Float], terms: [String], inverseTextNormalized: Bool = true) async -> String {
        let terms = SpeechVocabulary.bounded(terms)
        guard !terms.isEmpty, !timings.isEmpty, !samples.isEmpty, samples.count <= Self.maximumSamples, !Task.isCancelled else { return text }
        do {
            try await prepare(allowDownload: false)
            guard let models, let tokenizer, !Task.isCancelled else { return text }
            let session: VocabularyBoostingSession
            if terms == cachedTerms, inverseTextNormalized == cachedInverseTextNormalized, let cachedSession {
                session = cachedSession
            } else {
                let vocabulary = CustomVocabularyContext(terms: terms.compactMap { term in
                    let tokens = tokenizer.encode(term)
                    return tokens.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: tokens)
                })
                guard !vocabulary.terms.isEmpty else { return text }
                session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models,
                    config: inverseTextNormalized ? VocabularyBoostingSession.itnDefaultConfig : .default)
                cachedTerms = terms
                cachedInverseTextNormalized = inverseTextNormalized
                cachedSession = session
            }
            guard !Task.isCancelled else { return text }
            return await session.rescore(text: text, tokenTimings: timings, audioSamples: samples)?.text ?? text
        } catch {
            // Vocabulary is assistance. A missing model must never erase recognized speech.
            return text
        }
    }
}
