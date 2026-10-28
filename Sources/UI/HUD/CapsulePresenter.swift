import Combine
import Foundation

// MARK: - Scheduling

/// A cancellable one-shot. **Not a timer**: nothing here repeats, and the capsule
/// schedules work only when a state has a stated lifetime (§9's duration column).
@MainActor
protocol CapsuleScheduledWork: AnyObject {
    func cancel()
}

@MainActor
protocol CapsuleScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any CapsuleScheduledWork
}

@MainActor
final class CapsuleDispatchScheduler: CapsuleScheduling {

    private final class Work: CapsuleScheduledWork {
        private let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any CapsuleScheduledWork {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Work(item: item)
    }
}

// MARK: - Presenter

/// The capsule's whole behaviour, with no window in it.
///
/// It holds the current phase, the notice layered over it, and the two lifetimes that
/// §9 gives the HUD: how long a notice stays up, and how long a terminal state stays
/// up before the capsule leaves the screen. `CapsuleController` is then only glass.
@MainActor
final class CapsulePresenter: ObservableObject {

    @Published private(set) var content: CapsuleContent = CapsuleState.content(for: .idle, elapsed: 0)
    @Published private(set) var isVisible = false
    /// True exactly while a retryable error capsule is on screen — the window in
    /// which ⌘R may be stolen from the rest of the system.
    @Published private(set) var offersRetry = false

    private(set) var phase: PipelinePhase = .idle
    private(set) var notice: CapsuleNotice?
    private(set) var liveTranscript: String?

    private let scheduler: any CapsuleScheduling
    private var noticeWork: (any CapsuleScheduledWork)?
    private var dismissWork: (any CapsuleScheduledWork)?

    /// The default is nil rather than a `CapsuleDispatchScheduler()` literal because
    /// a default argument is evaluated outside the actor.
    init(scheduler: (any CapsuleScheduling)? = nil) {
        self.scheduler = scheduler ?? CapsuleDispatchScheduler()
    }

    // MARK: Input

    func update(phase newPhase: PipelinePhase) {
        let previous = phase
        phase = newPhase
        if !newPhase.isRecording { liveTranscript = nil }

        // Switching mode mid-recording republishes `.recording` with a different mode
        // name. That is the only signal the pipeline gives, and it is enough.
        if let name = Self.modeSwitchName(from: previous, to: newPhase) {
            present(notice: .modeSwitched(name: name))
            return
        }
        // A notice survives the elapsed second ticking underneath it, and dies the
        // moment the capture actually moves on.
        if !Self.sameKind(previous, newPhase) { clearNotice() }
        refresh()
    }

    func update(liveTranscript text: String?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = normalized?.isEmpty == false ? normalized : nil
        refresh()
    }

    func present(notice newNotice: CapsuleNotice) {
        noticeWork?.cancel()
        notice = newNotice
        if let lifetime = CapsuleState.content(for: newNotice).autoDismissAfter {
            noticeWork = scheduler.schedule(after: lifetime) { [weak self] in
                guard let self else { return }
                self.noticeWork = nil
                self.notice = nil
                self.refresh()
            }
        }
        refresh()
    }

    /// Dismissed by hand — the "or until dismissed" half of the error row.
    func dismiss() {
        clearNotice()
        dismissWork?.cancel()
        dismissWork = nil
        isVisible = false
        offersRetry = false
    }

    // MARK: Derivation

    private func refresh() {
        let next = notice.map(CapsuleState.content(for:))
            ?? ((phase.isRecording ? liveTranscript : nil).map(CapsuleState.content(forLiveTranscript:)))
            ?? CapsuleState.content(for: phase, elapsed: CapsuleState.elapsedSeconds(of: phase))
        content = next

        dismissWork?.cancel()
        dismissWork = nil

        if case .idle = phase {
            isVisible = false
            offersRetry = false
            return
        }

        isVisible = true
        offersRetry = notice == nil && Self.isRetryableError(phase)

        // A notice owns the screen for its own lifetime; the terminal state's own
        // dismissal is rescheduled when the notice expires.
        if notice == nil, let lifetime = next.autoDismissAfter {
            dismissWork = scheduler.schedule(after: lifetime) { [weak self] in
                guard let self else { return }
                self.dismissWork = nil
                self.isVisible = false
                self.offersRetry = false
            }
        }
    }

    private func clearNotice() {
        noticeWork?.cancel()
        noticeWork = nil
        notice = nil
    }

    // MARK: Pure helpers

    static func modeSwitchName(from old: PipelinePhase, to new: PipelinePhase) -> String? {
        guard case .recording(_, let oldName) = old,
              case .recording(_, let newName) = new,
              oldName != newName
        else { return nil }
        return newName
    }

    /// Same *case*, regardless of associated values. A recording whose elapsed second
    /// advanced has not changed state, and must not disturb what is on screen.
    static func sameKind(_ lhs: PipelinePhase, _ rhs: PipelinePhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.arming, .arming), (.recording, .recording),
             (.transcribing, .transcribing), (.refining, .refining),
             (.success, .success), (.error, .error):
            return true
        default:
            return false
        }
    }

    static func isRetryableError(_ phase: PipelinePhase) -> Bool {
        if case .error(_, let retryable) = phase { return retryable }
        return false
    }
}
