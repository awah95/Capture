import Foundation

/// What the hardware actually did, as opposed to what was asked of it.
///
/// This exists because the previous version of this app shipped with a full green
/// test suite and a microphone that recorded nothing. Unit tests cannot see a dead
/// tap; this report can. Every number here is observed, never assumed.
struct DiagnosticsReport: Equatable {
    var deviceName: String = ""
    var deviceUID: String = ""
    var transport: String = ""
    var isContinuity: Bool = false

    var hardwareSampleRate: Double = 0
    var hardwareChannels: UInt32 = 0

    var voiceProcessingRequested: Bool = false
    var voiceProcessingActive: Bool = false
    var fellBackToSystemDefault: Bool = false

    var buffersReceived: Int = 0
    var nonSilentBufferCount: Int = 0
    var peakLevel: Double = 0
    var rmsLevel: Double = 0

    var fileBytes: Int = 0
    var durationSeconds: Double = 0
    var fileFormat: String = ""

    var armedLatencyMs: Int = 0
    /// Stage name → milliseconds. Only stages that ran appear.
    var timings: [String: Int] = [:]
    var transcript: String?
    var errors: [String] = []

    static let empty = DiagnosticsReport()

    /// The order stages actually happen in. A dictionary has no order, and a report
    /// whose stages shuffle between runs is unreadable when you are comparing two.
    private static let stageOrder = ["capture", "convert", "upload", "whisper", "llm", "insert", "total"]

    /// Plain text for the clipboard. Never contains an API key.
    func formatted() -> String {
        var lines: [String] = []

        lines.append("Captur diagnostics")
        lines.append("")

        lines.append("INPUT")
        lines.append("  device       \(deviceName.isEmpty ? "—" : deviceName)")
        lines.append("  uid          \(deviceUID.isEmpty ? "—" : deviceUID)")
        lines.append("  transport    \(transport)\(isContinuity ? "  ⚠︎ Continuity" : "")")
        if fellBackToSystemDefault {
            lines.append("  ⚠︎ none of the preferred devices were present — fell back to the system default")
        }
        if hardwareSampleRate > 0 {
            lines.append("  negotiated   \(Int(hardwareSampleRate)) Hz, \(hardwareChannels) ch")
        }

        lines.append("")
        lines.append("ECHO CANCELLATION")
        if voiceProcessingRequested && !voiceProcessingActive {
            lines.append("  ⚠︎ requested but NOT active — dictating over speaker audio will contaminate the transcript")
        } else if voiceProcessingActive {
            lines.append("  active")
        } else {
            lines.append("  off (not requested)")
        }

        lines.append("")
        lines.append("CAPTURE")
        lines.append("  buffers      \(buffersReceived)")
        lines.append("  non-silent   \(nonSilentBufferCount)")
        lines.append("  peak / rms   \(String(format: "%.3f", peakLevel)) / \(String(format: "%.3f", rmsLevel))")
        lines.append("  armed in     \(armedLatencyMs) ms")

        if buffersReceived == 0 {
            lines.append("  ✗ NO BUFFERS — the tap never fired. The engine is running but no audio is arriving.")
        } else if nonSilentBufferCount == 0 {
            lines.append("  ✗ SILENT — buffers arrived but every one of them was silence.")
        }

        if durationSeconds > 0 || fileBytes > 0 {
            lines.append("")
            lines.append("FILE")
            lines.append("  format       \(fileFormat.isEmpty ? "—" : fileFormat)")
            lines.append("  duration     \(String(format: "%.2f", durationSeconds)) s")
            lines.append("  size         \(fileBytes.formatted()) bytes")
            if let compression = compressionLine() {
                lines.append("  \(compression)")
            }
            if durationSeconds > 0 {
                let kbPerSecond = Double(fileBytes) / 1_024 / durationSeconds
                lines.append("  rate         \(String(format: "%.1f", kbPerSecond)) KB/s of speech")
            }
        }

        let ranStages = Self.stageOrder.filter { timings[$0] != nil }
        if !ranStages.isEmpty {
            lines.append("")
            lines.append("TIMINGS")
            for stage in ranStages {
                let ms = timings[stage] ?? 0
                lines.append("  \(stage.padding(toLength: 12, withPad: " ", startingAt: 0)) \(ms) ms")
            }
        }

        if let transcript, !transcript.isEmpty {
            lines.append("")
            lines.append("TRANSCRIPT")
            lines.append("  \(transcript)")
        }

        if !errors.isEmpty {
            lines.append("")
            lines.append("ERRORS")
            for error in errors {
                lines.append("  \(error)")
            }
        }

        return Self.redactingSecrets(lines.joined(separator: "\n"))
    }

    /// What downsampling to 16 kHz mono and encoding to FLAC actually bought, measured
    /// against the raw float32 stream the hardware handed us.
    private func compressionLine() -> String? {
        guard durationSeconds > 0, fileBytes > 0,
              hardwareSampleRate > 0, hardwareChannels > 0 else { return nil }
        let rawBytes = durationSeconds * hardwareSampleRate * Double(hardwareChannels) * 4
        guard rawBytes > 0 else { return nil }
        let ratio = rawBytes / Double(fileBytes)
        guard ratio >= 1 else { return nil }
        return "compression  \(String(format: "%.0f", ratio))× smaller than the raw \(Int(hardwareSampleRate)) Hz "
            + "\(hardwareChannels == 1 ? "mono" : "stereo") capture"
    }

    /// Strips anything shaped like a Groq key. A diagnostic report is meant to be
    /// pasted into a chat window, so it must never carry a credential.
    private static func redactingSecrets(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "gsk_[A-Za-z0-9_-]+") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<redacted>")
    }
}
