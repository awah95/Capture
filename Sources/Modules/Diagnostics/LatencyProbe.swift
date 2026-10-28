import Foundation

/// `Captur --probe-latency [runs] [file.flac]` — how long Groq actually takes.
///
/// The fifth instrument, and it exists because LV5 has a number in it that nobody could
/// check without the owner's voice. LV5 measures *perceived latency*: the wait after you
/// stop speaking, budgeted at 800 ms p50 (spec §15). That whole budget is dominated by
/// one round trip, and a round trip can be measured against a recording the owner has
/// already made rather than one they have to make now.
///
/// **This is not LV5 and must never be recorded as LV5.** It excludes capture
/// finalization, stitching and insertion, and it re-sends one file rather than speaking
/// twenty fresh ones. What it does give is the shape of the distribution — and the two
/// real dictations on record disagreed by 10× (46 ms and 482 ms), which is exactly the
/// kind of spread a single sample cannot tell you about.
enum LatencyProbe {

    static func run(runs: Int, path: String?) async {
        let key = Keychain.apiKey() ?? ""
        guard !key.isEmpty else {
            print("No Groq API key in the Keychain — nothing to measure.")
            return
        }

        guard let url = resolve(path) else {
            print("No saved recording to replay. Dictate once, then run this again.")
            return
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        print("--- transcription latency ---")
        print("  file       \(url.lastPathComponent) (\(bytes) bytes)")
        print("  runs       \(runs)")
        print("  model      \(GroqClient.defaultModel)")
        print("")
        print("  NOT LV5: this is the Groq round trip only — no capture finalization,")
        print("  no stitching, no insertion, and one file rather than twenty spoken.")
        print("")

        let client = GroqClient()
        var samples: [Double] = []
        var text: String?

        for run in 1...max(1, runs) {
            let startedAt = Date()
            do {
                let transcript = try await client.transcribe(fileURL: url, apiKey: key, prompt: nil)
                let elapsed = Date().timeIntervalSince(startedAt) * 1_000
                samples.append(elapsed)
                if text == nil { text = transcript }
                print(String(format: "  [%2d/%d] %6.0f ms", run, runs, elapsed))
            } catch {
                // A failed call is reported and excluded rather than counted as zero:
                // a zero would flatter the p50 by exactly the amount that went wrong.
                print("  [\(run)/\(runs)] FAILED — \(error)")
            }
        }

        guard !samples.isEmpty else { return print("\n  no successful calls") }
        let sorted = samples.sorted()
        print("")
        print(String(format: "  n = %d   min %.0f   p50 %.0f   p95 %.0f   max %.0f  (ms)",
                     sorted.count,
                     sorted[0],
                     percentile(sorted, 0.50),
                     percentile(sorted, 0.95),
                     sorted[sorted.count - 1]))
        if let text, !text.isEmpty {
            print("  transcript: \(text.prefix(72))")
        }
        print("")
        print("  Perceived latency (LV5) is this plus finalization and insertion.")
        print("  Budget: 800 ms p50 for the whole thing, Verbatim, ≤ 8 s dictation.")
    }

    /// Nearest rank — every printed number is a real call.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(0, min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded())))
        return sorted[rank]
    }

    /// The named file, or the most recent **session** recording the app has saved.
    /// Segment files are skipped: they are fragments, and a fragment's round trip is not
    /// the round trip a dictation pays.
    static func resolve(_ path: String?) -> URL? {
        if let path { return URL(fileURLWithPath: path) }
        let directory = AppPaths.supportDirectory().appendingPathComponent("audio", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "flac" && !$0.lastPathComponent.contains("-segment-") }
            .max { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
    }
}
