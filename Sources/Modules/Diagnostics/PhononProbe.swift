import Foundation

/// Local-only ASR check. Requires an explicit support directory and audio paths;
/// never reads history, captures a microphone, sends audio, or changes preferences.
enum PhononProbe {
    static func run(arguments: [String]) async -> Bool {
        func values(_ flag: String) -> [String] {
            arguments.indices.compactMap { index in
                guard arguments[index] == flag, index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else { return nil }
                return arguments[index + 1]
            }
        }
        func emit(_ value: [String: Any]) {
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: bytes, encoding: .utf8) { print(text) }
        }
        guard let directory = values("--support-directory").first, directory.hasPrefix("/"),
              !values("--audio").isEmpty else {
            print("Use --probe-phonon --support-directory <absolute-directory> [--download-model] --audio <file> [--audio <file> …]")
            return false
        }
        do {
            let runtime = PhononTranscriptionRuntime(supportDirectory: URL(fileURLWithPath: directory))
            let start = Date()
            if arguments.contains("--download-model") {
                try await runtime.prepare(progress: { update in
                    // Phase text only; audio contents never enter progress messages.
                    if update.fraction == 1 { print(update.detail) }
                })
            } else { try await runtime.prepare() }
            emit(["provider": "localPhonon", "model": TranscriptionProvider.localPhonon.batchUsageModelID,
                  "loadSeconds": Date().timeIntervalSince(start)])
            for path in values("--audio") {
                let start = Date()
                let text = try await runtime.transcribe(fileURL: URL(fileURLWithPath: path))
                emit(["file": URL(fileURLWithPath: path).lastPathComponent, "text": text,
                      "transcribeMs": Date().timeIntervalSince(start) * 1_000])
            }
            return true
        } catch {
            print("Phonon-2 check failed: \(error.localizedDescription)")
            return false
        }
    }
}
