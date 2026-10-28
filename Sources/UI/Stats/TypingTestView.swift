import SwiftUI

/// The 60-second typing test, spec §11.2.
///
/// ## The countdown, and why there is no `Timer`
///
/// Spec §15 asks for ~0 % idle CPU and Task 29 greps for stray timers, so nothing here
/// polls. Three separate things need the passing of time and each gets the cheapest source
/// that can provide it:
///
/// 1. **The digits.** `Text(timerInterval:countsDown:)` — SwiftUI renders a live countdown
///    from a date range with no timer of ours, no state changes, and no view rebuilds. It
///    stops when the view leaves the hierarchy because there is nothing to stop.
/// 2. **The bar.** `ProgressView(timerInterval:countsDown:)`, for the same reason.
/// 3. **The deadline.** One `Task.sleep` inside `.task(id:)`, which sleeps **once** for the
///    whole remaining interval and then finishes the run. It is a single wake-up, not a
///    poll, and `.task` cancels it when the sheet is dismissed, so it cannot outlive the
///    view and cannot fire against a session nobody is looking at.
///
/// The sleep hands `session.deadline` to `finish(at:)` rather than re-reading a clock, so
/// an overdue wake-up cannot change what was measured — and `finish(at:)` still refuses
/// anything short of the full minute, so a cancelled sleep cannot bank a half-run.
struct TypingTestView: View {

    let session: TypingTestSession
    /// Called after a run has been scored and saved. The stats page reloads on it, so the
    /// hero turns from the prompt into a figure without the window being reopened.
    var onFinished: () -> Void = {}
    var onClose: () -> Void

    @FocusState private var isTyping: Bool

    private static let width: CGFloat = 660

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let score = session.score {
                result(score)
            } else {
                passage
                input
            }

            footer
        }
        .padding(24)
        .frame(width: Self.width)
        .background(CapturPalette.canvas)
        // One wake-up at the deadline. `id:` is the deadline itself, so the task starts
        // when the first keystroke sets one and restarts if the run is reset.
        .task(id: session.deadline) {
            guard let deadline = session.deadline else { return }
            let remaining = session.remainingSeconds(at: Date()) ?? 0
            // A small settle margin: `Task.sleep` may wake a hair early, and
            // `finish(at:)` refuses anything short of the full minute.
            try? await Task.sleep(for: .seconds(remaining + 0.05))
            guard !Task.isCancelled else { return }
            if session.finish(at: deadline) != nil {
                onFinished()
            }
        }
        .onAppear { isTyping = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            CapturMark()
            VStack(alignment: .leading, spacing: 3) {
                Text("Typing baseline")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.25)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            countdown
        }
    }

    private var subtitle: String {
        if session.score != nil { return "Your typing baseline has been saved." }
        if session.isRunning { return "Keep going. Accuracy counts." }
        return "Sixty seconds. Start typing whenever you are ready."
    }

    /// The one figure that is allowed to be large while the test is running. The result
    /// screen has its own hero and this disappears, so there is never more than one.
    @ViewBuilder
    private var countdown: some View {
        if let startedAt = session.startedAt, let deadline = session.deadline {
            Text(timerInterval: startedAt...deadline, countsDown: true)
                .font(.system(size: 32, weight: .medium, design: .default))
                .monospacedDigit()
                .tracking(-0.8)
                .foregroundStyle(.primary)
                .accessibilityLabel("Time remaining")
        } else {
            Text("1:00")
                .font(.system(size: 32, weight: .medium, design: .default))
                .monospacedDigit()
                .tracking(-0.8)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: The passage

    /// Three runs — right so far, wrong from the first mistake, not yet reached — rather
    /// than a per-character `AttributedString` rebuilt on every keystroke. See
    /// `TypingTestSession.split(typed:prompt:)`.
    private var passage: some View {
        let split = session.progressSplit
        return VStack(alignment: .leading, spacing: 8) {
            Text("Passage")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text("\(Text(split.correct).foregroundStyle(.secondary))\(Text(split.wrong).foregroundStyle(Color.red))\(Text(split.remaining).foregroundStyle(.primary))")
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .lineSpacing(5)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(height: 204)
        .capturSurface(inset: true, radius: 11)
        .accessibilityLabel("Passage to type")
    }

    // MARK: Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your typing")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { session.typed },
                set: { session.type($0) }))
                .font(.system(size: 15, design: .default))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 104)
                .background(CapturPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isTyping ? CapturPalette.accent.opacity(0.72)
                                              : CapturPalette.border,
                                      lineWidth: isTyping ? 1.25 : 0.75))
                .focused($isTyping)
                .accessibilityLabel("Type the passage here")

            if session.didRefuseInput {
                // Saying why is the difference between a rule and an app that appears
                // broken.
                Label("That was pasted, not typed. The test only measures typing.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if session.isRunning, let startedAt = session.startedAt,
                      let deadline = session.deadline {
                ProgressView(timerInterval: startedAt...deadline, countsDown: false)
                    .progressViewStyle(.linear)
                    .labelsHidden()
                    .tint(CapturPalette.accent)
            }
        }
        .padding(14)
        .capturSurface(inset: true, radius: 11)
    }

    // MARK: Result

    /// The hero, spec §11.3: one per view, ≥ 48 pt, body sans.
    private func result(_ score: TypingTestScore) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HeroFigure(
                value: "\(Int(score.wordsPerMinute.rounded())) wpm",
                detail: "your typing baseline")

            ChartValueTable(rows: [
                ChartValueTable.Row(
                    label: "Accuracy", value: AppBreakdownChart.percent(score.accuracy)),
                ChartValueTable.Row(
                    label: "Every keystroke",
                    value: "\(Int(score.grossWordsPerMinute.rounded())) wpm"),
                ChartValueTable.Row(
                    label: "Characters typed", value: "\(score.typedCharacters)"),
                ChartValueTable.Row(
                    label: "Characters correct", value: "\(score.correctCharacters)"),
            ])

            Text("Time saved is measured against this. Run it again whenever your typing "
                 + "changes — the newest run replaces this one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .capturSurface(inset: true, radius: 11)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if session.score != nil {
                Button("Run it again") { session.restart() }
                    .buttonStyle(.bordered)
            } else if session.isRunning {
                // Named for what it does. "Cancel" would leave it ambiguous whether the
                // partial run counts — it does not, and neither does anything else.
                Button("Stop without saving") { session.abandon() }
                    .buttonStyle(.bordered)
            }

            Spacer()

            Button(session.score != nil ? "Done" : "Close") {
                // Leaving an unfinished run discards it. Leaving a finished one has
                // nothing to discard — the baseline was saved when it was scored.
                if session.score == nil { session.abandon() }
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderedProminent)
        }
    }
}
