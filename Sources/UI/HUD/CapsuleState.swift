import AppKit
import Foundation

// MARK: - Content

/// Spec §9 colour: monochrome plus exactly one accent, amber for warnings, red for
/// the recording dot and errors, green for success.
enum CapsuleTint: Equatable, Sendable {
    case neutral, accent, warning, danger, success
}

/// Everything the capsule draws, as one value. The view owns no state of its own
/// beyond its animations, so every rule in the §9 table is a pure function and is
/// tested as one.
struct CapsuleContent: Equatable {
    /// Bars are drawn at all.
    var showsWaveform: Bool = false
    /// The bars are being driven by the microphone. **This is the only thing that may
    /// start a 30 fps timeline** — a frozen waveform (`.transcribing`) draws the last
    /// buffer it had and ticks nothing.
    var waveformIsLive: Bool = false
    var showsPulsingDot: Bool = false
    /// The indeterminate progress sweep for the two open-ended phases.
    var showsShimmer: Bool = false
    var primaryText: String?
    var symbolName: String?
    var tint: CapsuleTint = .neutral
    var autoDismissAfter: TimeInterval?
    var targetWidth: CGFloat = CapsuleState.collapsedWidth
}

/// A transient notice layered *over* the current phase.
///
/// `PipelinePhase` deliberately has no `modeSwitched` or `warning` case — neither is
/// a state of the capture, both are things worth saying about a capture that is still
/// recording. The capsule shows the notice for its duration and then falls back to
/// whatever the phase is by then.
enum CapsuleNotice: Equatable, Sendable {
    case modeSwitched(name: String)
    case warning(text: String)
}

// MARK: - State

/// The §9 table, as arithmetic.
enum CapsuleState {

    // MARK: Geometry

    static let collapsedWidth: CGFloat = 132
    static let maximumWidth: CGFloat = 340
    static let height: CGFloat = 30
    static let cornerRadius: CGFloat = 15
    static let horizontalPadding: CGFloat = 12
    static let elementSpacing: CGFloat = 6
    static let dotDiameter: CGFloat = 8
    static let symbolWidth: CGFloat = 14

    /// What is left for the waveform once the capsule is at its collapsed width and
    /// the dot and padding have been paid for. Deriving it this way is what makes
    /// `width(forPrimaryText: nil, showsWaveform: true) == collapsedWidth` true by
    /// construction rather than by coincidence.
    static let waveformWidth: CGFloat =
        collapsedWidth - (2 * horizontalPadding) - dotDiameter - elementSpacing   // 94

    // MARK: Durations

    static let elapsedAppearsAfter: TimeInterval = 10
    static let successDismissAfter: TimeInterval = 1.2
    static let errorDismissAfter: TimeInterval = 4
    static let modeSwitchedDismissAfter: TimeInterval = 1.4
    static let warningDismissAfter: TimeInterval = 2.5

    // MARK: Text

    static let textPointSize: CGFloat = 12
    static let textFont = NSFont.systemFont(ofSize: textPointSize, weight: .medium)
    static let separator = " · "
    static let audioSavedHint = "audio saved"
    static let retryHint = "⌘R to retry"

    /// ⌘R. Registered as a transient Carbon hotkey only while a retryable error
    /// capsule is on screen — the capsule never becomes key, so an ordinary
    /// keystroke could never reach it (spec §4.1).
    static let retryCombo = KeyCombo(keyCode: 15, carbonModifiers: 0x0100)  // kVK_ANSI_R + cmdKey

    // MARK: Content

    /// - Parameter elapsed: the authoritative recording elapsed-seconds. Callers with
    ///   a `.recording` phase pass its associated value; `content(for:)` does that.
    static func content(for phase: PipelinePhase, elapsed: TimeInterval) -> CapsuleContent {
        switch phase {
        case .idle:
            return CapsuleContent(targetWidth: collapsedWidth)

        case .arming:
            // A steady dot and explicit startup status. Not the *pulsing* dot: §9
            // breathes the dot only while recording, and arming is over in 150 ms.
            return CapsuleContent(
                primaryText: "Starting…",
                symbolName: "circle.fill",
                tint: .danger,
                targetWidth: width(forPrimaryText: "Starting…", showsWaveform: false))

        case .recording:
            let text = elapsed >= elapsedAppearsAfter
                ? "Listening\(separator)\(formatElapsed(elapsed))"
                : "Listening"
            let fitted = fit(text, showsWaveform: true)
            return CapsuleContent(
                showsWaveform: true,
                waveformIsLive: true,
                showsPulsingDot: true,
                primaryText: fitted.text,
                tint: .danger,
                targetWidth: fitted.width)

        case .transcribing:
            let fitted = fit("Transcribing…", showsWaveform: true)
            return CapsuleContent(
                showsWaveform: true,
                waveformIsLive: false,
                showsShimmer: true,
                primaryText: fitted.text,
                tint: .neutral,
                targetWidth: fitted.width)

        case .refining(let modeName):
            let fitted = fit(modeName, showsWaveform: false)
            return CapsuleContent(
                showsShimmer: true,
                primaryText: fitted.text,
                symbolName: "wand.and.stars",
                tint: .accent,
                targetWidth: fitted.width)

        case .success(let words, let wpm):
            let fitted = fit("\(words) \(words == 1 ? "word" : "words")\(separator)\(wpm) wpm",
                             showsWaveform: false)
            return CapsuleContent(
                primaryText: fitted.text,
                symbolName: "checkmark.circle.fill",
                tint: .success,
                autoDismissAfter: successDismissAfter,
                targetWidth: fitted.width)

        case .error(let message, let retryable):
            let fitted = fit(errorText(message: message, retryable: retryable), showsWaveform: false)
            return CapsuleContent(
                primaryText: fitted.text,
                symbolName: retryable ? "exclamationmark.triangle.fill" : "exclamationmark.octagon.fill",
                tint: .danger,
                autoDismissAfter: errorDismissAfter,
                targetWidth: fitted.width)
        }
    }

    /// Convenience for callers holding a phase and nothing else.
    static func content(for phase: PipelinePhase) -> CapsuleContent {
        content(for: phase, elapsed: elapsedSeconds(of: phase))
    }

    static func content(for notice: CapsuleNotice) -> CapsuleContent {
        switch notice {
        case .modeSwitched(let name):
            let fitted = fit(name, showsWaveform: false)
            return CapsuleContent(
                primaryText: fitted.text,
                symbolName: "wand.and.stars",
                tint: .accent,
                autoDismissAfter: modeSwitchedDismissAfter,
                targetWidth: fitted.width)

        case .warning(let text):
            let fitted = fit(text, showsWaveform: false)
            return CapsuleContent(
                primaryText: fitted.text,
                symbolName: "exclamationmark.triangle.fill",
                tint: .warning,
                autoDismissAfter: warningDismissAfter,
                targetWidth: fitted.width)
        }
    }

    /// Moonshine-only live decoding. The waveform yields the line to the transcript
    /// once words exist; the pulsing recording dot remains, so this still reads as a
    /// live capture rather than finalized text.
    static func content(forLiveTranscript text: String) -> CapsuleContent {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return content(for: .recording(elapsed: 0, modeName: ""))
        }

        let leading = dotDiameter
        let naturalWidth = (2 * horizontalPadding) + leading + elementSpacing + measure(normalized)
        let targetWidth = min(max(naturalWidth, collapsedWidth), maximumWidth)
        let available = max(0, targetWidth - (2 * horizontalPadding) - leading - elementSpacing)
        return CapsuleContent(
            showsPulsingDot: true,
            primaryText: tailTruncated(normalized, toWidth: available),
            tint: .danger,
            targetWidth: targetWidth)
    }

    static func elapsedSeconds(of phase: PipelinePhase) -> TimeInterval {
        if case .recording(let elapsed, _) = phase { return elapsed }
        return 0
    }

    // MARK: Width

    static func width(forPrimaryText text: String?, showsWaveform: Bool) -> CGFloat {
        var width = (2 * horizontalPadding) + leadingWidth(showsWaveform: showsWaveform)
        if let text, !text.isEmpty {
            width += elementSpacing + measure(text)
        }
        return min(max(width, collapsedWidth), maximumWidth)
    }

    /// How much room the text has inside a capsule of the given width.
    static func textWidth(inCapsuleWidth width: CGFloat, showsWaveform: Bool) -> CGFloat {
        max(0, width - (2 * horizontalPadding) - leadingWidth(showsWaveform: showsWaveform) - elementSpacing)
    }

    /// The dot-plus-waveform or the glyph that always precedes the text.
    private static func leadingWidth(showsWaveform: Bool) -> CGFloat {
        showsWaveform ? dotDiameter + elementSpacing + waveformWidth : symbolWidth
    }

    static func measure(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: textFont]).width)
    }

    // MARK: Truncation

    /// Middle truncation, done in the model rather than left to the layout, so the
    /// string that reaches the view already fits its box. A HUD line that gets cut
    /// loses its tail — and the tail is where "⌘R to retry" lives.
    static func truncated(_ text: String, toWidth available: CGFloat) -> String {
        guard available > 0 else { return "" }
        guard measure(text) > available else { return text }

        let characters = Array(text)
        var low = 0
        var high = characters.count - 1
        var best = "…"
        while low <= high {
            let keep = (low + high) / 2
            let head = (keep + 1) / 2
            let candidate = String(characters.prefix(head))
                + "…"
                + String(characters.suffix(keep - head))
            if measure(candidate) <= available {
                best = candidate
                low = keep + 1
            } else {
                high = keep - 1
            }
        }
        return best
    }

    /// Keeps the newest words visible as a streaming decoder revises a growing line.
    static func tailTruncated(_ text: String, toWidth available: CGFloat) -> String {
        guard available > 0 else { return "" }
        guard measure(text) > available else { return text }

        let characters = Array(text)
        var low = 0
        var high = characters.count
        var best = "…"
        while low <= high {
            let keep = (low + high) / 2
            let candidate = "…" + String(characters.suffix(keep))
            if measure(candidate) <= available {
                best = candidate
                low = keep + 1
            } else {
                high = keep - 1
            }
        }
        return best
    }

    private static func fit(_ text: String?, showsWaveform: Bool) -> (text: String?, width: CGFloat) {
        guard let text, !text.isEmpty else {
            return (nil, width(forPrimaryText: nil, showsWaveform: showsWaveform))
        }
        let capsuleWidth = width(forPrimaryText: text, showsWaveform: showsWaveform)
        let available = textWidth(inCapsuleWidth: capsuleWidth, showsWaveform: showsWaveform)
        return (truncated(text, toWidth: available), capsuleWidth)
    }

    // MARK: Formatting

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// One line: the reason, then the two things the user needs to know about it.
    ///
    /// `retryable` is the pipeline's word for "the audio is still on disk", so it
    /// gates both the saved-audio reassurance and the ⌘R offer. Promising a saved
    /// file for a microphone that never started would be a lie.
    static func errorText(message: String, retryable: Bool) -> String {
        let reason = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard retryable else { return reason }
        var parts = [reason]
        if !reason.lowercased().contains(audioSavedHint) { parts.append(audioSavedHint) }
        parts.append(retryHint)
        return parts.joined(separator: separator)
    }
}
