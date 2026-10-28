import AppKit
import Foundation

// MARK: - Target

/// The three calls the pipeline makes into the HUD, and nothing else.
///
/// `CapsuleController` and `CapsulePresenter` both already have exactly these
/// signatures; this protocol only names them so the parade can be walked against the
/// presenter in a unit test and against the controller on screen, with the *same*
/// code driving both. It deliberately does not abstract the capsule's content: the
/// parade never decides what the capsule looks like, it only decides what to say to it.
@MainActor
protocol HUDParadeTarget: AnyObject {
    func update(phase: PipelinePhase)
    func present(notice: CapsuleNotice)
    func dismiss()
}

extension CapsuleController: HUDParadeTarget {}
extension CapsulePresenter: HUDParadeTarget {}

// MARK: - Parade

/// Drives the **real** capsule through every state in spec §9 so the whole set can be
/// screenshotted in one pass, light and dark.
///
/// It exists because most of the §9 table cannot be photographed by hand. `arming`
/// lasts 150 ms. `success` flashes for 1.2 s. `modeSwitched` and `refining` are
/// unreachable in this build at all — modes are not wired yet. `error` needs the
/// network deliberately broken. So the state table has never been *looked at*, and one
/// change in it has never been seen by anybody: the recording waveform used to be
/// tinted red along with the dot, which made the capsule read as an alert, and is now
/// monochrome per §9 (`CapsuleView.swift`, "Monochrome, not the state tint").
///
/// It is an instrument, not a preview: it constructs the shipping `CapsuleController`
/// and talks to it through `update(phase:)` / `present(notice:)` — the same two calls
/// `AppComposition` makes. Nothing here draws a capsule of its own. A parade that
/// rendered its own fake would answer a question about itself; this project has
/// already lost two bugs to stubs that lied.
///
/// The schedule and everything printed about it are pure values, deliberately not
/// isolated to any actor: they are arithmetic over the §9 table and are tested as such.
/// Only the parts that touch the capsule, AppKit or the run loop are `@MainActor`.
enum HUDParade {

    // MARK: Pacing

    /// The floor on how long a state stays up, in seconds. A screenshot needs a
    /// hand on a keyboard, so every state is held for at least this long **regardless
    /// of the duration §9 gives it** — see `Step.refreshInterval` for how that is done
    /// honestly rather than by disabling the spec's timers.
    static let minimumHold: TimeInterval = 2.5
    static let defaultHold: TimeInterval = 3.0

    /// How far ahead of its own expiry an auto-dismissing state is re-applied. The
    /// margin is what keeps the capsule from blinking between the two applications.
    static let refreshLead: TimeInterval = 0.4
    static let minimumRefresh: TimeInterval = 0.3

    // MARK: States

    /// One row of the §9 table, as an identity.
    ///
    /// Two rows are split finer than `PipelinePhase` is, because §9 gives them
    /// different *contents* and LV7 has to see both: `recording` shows elapsed only
    /// after 10 s, and `error` offers ⌘R only when the audio survived.
    enum StateID: String, CaseIterable {
        case hidden
        case arming
        case recording
        case recordingWithElapsed
        case modeSwitched
        case warning
        case transcribing
        case refining
        case success
        case errorRetryable
        case errorFinal

        /// `hidden` is the absence of a capsule. Everything else has to be in the set.
        static var photographable: [StateID] { allCases.filter { $0 != .hidden } }

        var label: String {
            switch self {
            case .hidden: return "hidden"
            case .arming: return "arming"
            case .recording: return "recording"
            case .recordingWithElapsed: return "recording + elapsed"
            case .modeSwitched: return "modeSwitched"
            case .warning: return "warning"
            case .transcribing: return "transcribing"
            case .refining: return "refining"
            case .success: return "success"
            case .errorRetryable: return "error (retryable)"
            case .errorFinal: return "error (final)"
            }
        }
    }

    /// Exhaustive **on purpose**: no `default`. `PipelinePhase` is not `CaseIterable`,
    /// so a hand-written list of states in the schedule could silently fall behind the
    /// enum. This switch is the drift guard — adding a case to `PipelinePhase` stops
    /// this file compiling until the parade has somewhere to put it, and the
    /// completeness test then requires it to be in the schedule.
    static func stateID(for phase: PipelinePhase) -> StateID {
        switch phase {
        case .idle:
            return .hidden
        case .arming:
            return .arming
        case .recording(let elapsed, _):
            return elapsed >= CapsuleState.elapsedAppearsAfter ? .recordingWithElapsed : .recording
        case .transcribing:
            return .transcribing
        case .refining:
            return .refining
        case .success:
            return .success
        case .error(_, let retryable):
            return retryable ? .errorRetryable : .errorFinal
        }
    }

    /// Same guard for the notices, which are a separate enum for a reason (§9's
    /// `modeSwitched` and `warning` are things said *about* a capture, not states of one).
    static func stateID(for notice: CapsuleNotice) -> StateID {
        switch notice {
        case .modeSwitched:
            return .modeSwitched
        case .warning:
            return .warning
        }
    }

    // MARK: Step

    struct Step: Equatable {

        /// What is handed to the HUD. There are exactly two doors — the phase and the
        /// notice — because the pipeline has exactly two.
        enum Subject: Equatable {
            case phase(PipelinePhase)
            case notice(CapsuleNotice)
        }

        let subject: Subject
        let dwell: TimeInterval

        var stateID: StateID {
            switch subject {
            case .phase(let phase): return HUDParade.stateID(for: phase)
            case .notice(let notice): return HUDParade.stateID(for: notice)
            }
        }

        var label: String { stateID.label }

        /// What the capsule will actually draw. Read from `CapsuleState` rather than
        /// restated here, so the printed line cannot describe something other than
        /// what is on screen.
        var content: CapsuleContent {
            switch subject {
            case .phase(let phase): return CapsuleState.content(for: phase)
            case .notice(let notice): return CapsuleState.content(for: notice)
            }
        }

        /// The line of text in the capsule, if any.
        var detail: String? { content.primaryText }

        /// `success` collapses after 1.2 s, `modeSwitched` after 1.4 s, `warning`
        /// after 2.5 s — their own §9 lifetimes, which the parade must not break.
        var autoDismissAfter: TimeInterval? { content.autoDismissAfter }

        /// How often the state is re-applied so it survives a dwell longer than its
        /// own lifetime. The spec's timer still runs and still fires on its own
        /// schedule; the parade simply says the same thing again before it does. That
        /// is a re-presentation, and it is disclosed on the printed line — a hold
        /// implemented by suppressing the duration would be a lie about the state.
        var refreshInterval: TimeInterval? {
            guard let lifetime = autoDismissAfter else { return nil }
            return max(HUDParade.minimumRefresh, lifetime - HUDParade.refreshLead)
        }
    }

    /// The offsets within one step's dwell at which the state is applied. A state with
    /// no lifetime of its own is applied once and stays up on its own.
    static func applications(for step: Step) -> [TimeInterval] {
        guard let interval = step.refreshInterval, interval > 0 else { return [0] }
        var offsets: [TimeInterval] = []
        var offset: TimeInterval = 0
        while offset < step.dwell {
            offsets.append(offset)
            offset += interval
        }
        return offsets.isEmpty ? [0] : offsets
    }

    // MARK: Schedule

    /// The §9 table, in the table's own order, as a value.
    ///
    /// The two notices sit between `recording + elapsed` and `transcribing` on
    /// purpose: a notice is layered *over* the current phase and falls back to it when
    /// it expires, so presenting them while the phase is still `.recording` is what
    /// production does. The elapsed value is 12:34 rather than a wait — §9 shows
    /// elapsed after 10 s, and the parade reaches that by saying so, not by standing
    /// there for ten seconds.
    static func schedule(hold: TimeInterval = defaultHold) -> [Step] {
        let dwell = max(minimumHold, hold)
        return [
            Step(subject: .phase(.arming), dwell: dwell),
            Step(subject: .phase(.recording(elapsed: 0, modeName: "Default")), dwell: dwell),
            Step(subject: .phase(.recording(elapsed: 754, modeName: "Default")), dwell: dwell),
            Step(subject: .notice(.modeSwitched(name: "Email")), dwell: dwell),
            Step(subject: .notice(.warning(text: "Microphone changed to MacBook Pro Microphone")),
                 dwell: dwell),
            Step(subject: .phase(.transcribing), dwell: dwell),
            Step(subject: .phase(.refining(modeName: "Email")), dwell: dwell),
            Step(subject: .phase(.success(words: 142, wpm: 118)), dwell: dwell),
            Step(subject: .phase(.error(message: "Groq timed out", retryable: true)), dwell: dwell),
            Step(subject: .phase(.error(message: "Microphone access denied", retryable: false)),
                 dwell: dwell),
        ]
    }

    // MARK: Options

    enum Appearance: String, Equatable {
        case system, light, dark

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    struct Options: Equatable {
        var hold: TimeInterval = defaultHold
        /// Wait for Return on stdin between steps instead of running on a clock.
        var waitsForReturn = false
        var appearance: Appearance = .system

        /// Anything the owner asked for that was not honoured verbatim. Printed in the
        /// header, because a hold that was quietly raised is a hold that was not the
        /// one they asked for.
        var notes: [String] = []

        static func parse(_ arguments: [String]) -> Options {
            var options = Options()

            if let index = arguments.firstIndex(of: "--hold"),
               index + 1 < arguments.count,
               let requested = Double(arguments[index + 1]) {
                options.hold = max(minimumHold, requested)
                if options.hold != requested {
                    options.notes.append(String(
                        format: "--hold %.1fs raised to the %.1fs screenshot floor.",
                        requested, minimumHold))
                }
            }

            options.waitsForReturn = arguments.contains("--step")

            if let index = arguments.firstIndex(of: "--appearance"),
               index + 1 < arguments.count,
               let requested = Appearance(rawValue: arguments[index + 1].lowercased()),
               requested != .system {
                options.appearance = requested
            }

            return options
        }
    }

    // MARK: Report

    /// LIGHT or DARK, from whatever the window server ends up resolving. A screenshot
    /// set that does not name its appearance cannot be told from the other pass later,
    /// which is the whole reason LV7 needs two passes.
    static func appearanceLabel(_ name: NSAppearance.Name) -> String {
        let darks: Set<NSAppearance.Name> = [
            .darkAqua, .vibrantDark,
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
        ]
        return darks.contains(name) ? "DARK" : "LIGHT"
    }

    @MainActor
    static func header(appearance name: NSAppearance.Name,
                       forced: Appearance,
                       steps: [Step],
                       options: Options) -> [String] {
        var lines = [
            "--- HUD parade ---",
            "  appearance:  \(appearanceLabel(name))  (\(name.rawValue))"
                + (forced == .system ? "" : "  [forced by --appearance \(forced.rawValue)]"),
            "  states:      \(steps.count)",
            "  pacing:      " + (options.waitsForReturn
                                 ? "press Return in this terminal to advance"
                                 : String(format: "%.1fs per state", options.hold)),
            "  capsule:     bottom-centre of the active screen, \(Int(CapsuleController.bottomInset)) pt up",
            "  screenshot:  ⌘⇧4 then Space, click the capsule",
        ]
        for note in options.notes {
            lines.append("  note:        \(note)")
        }
        lines.append("")
        lines.append("  Run again with --appearance " + (appearanceLabel(name) == "DARK" ? "light" : "dark")
                     + " for the other pass.")
        lines.append("")
        return lines
    }

    /// One line per state, so a screenshot can be matched back to what it is a picture
    /// of — and so a state being *held* is visible as a held state:
    ///
    ///     [ 5/10] warning — "Microphone changed…"  3.0s  (re-presented 2× at 2.1s to
    ///                                                     outlast its own 2.5s auto-dismiss)
    static func line(for step: Step, index: Int, of count: Int) -> String {
        let position = "[\(String(format: "%2d", index + 1))/\(count)]"
        var line = "\(position) \(step.label.padding(toLength: 20, withPad: " ", startingAt: 0))"
        line += step.detail.map { " — \"\($0)\"" } ?? ""
        line += String(format: "  %.1fs", step.dwell)

        // Disclosed only when it actually happens. A state whose own §9 lifetime is
        // already longer than the dwell — `error` at 4 s against a 3 s dwell — is on
        // screen for its real duration and is applied exactly once, so announcing a
        // re-presentation would be claiming a hold that was never performed.
        let applications = HUDParade.applications(for: step)
        if applications.count > 1, let lifetime = step.autoDismissAfter, let interval = step.refreshInterval {
            line += String(
                format: "  (re-presented %d× at %.1fs to outlast its own %.1fs auto-dismiss)",
                applications.count, interval, lifetime)
        }
        return line
    }

    // MARK: Driving

    @MainActor
    static func apply(_ step: Step, to target: any HUDParadeTarget) {
        switch step.subject {
        case .phase(let phase): target.update(phase: phase)
        case .notice(let notice): target.present(notice: notice)
        }
    }

    /// Back to `hidden`, by the route the pipeline itself uses, and then a hand
    /// dismissal to cancel anything still scheduled.
    ///
    /// This is the teardown that matters: `CapsuleController` registers ⌘R as a
    /// *system-wide* Carbon hotkey while a retryable error capsule is visible, and the
    /// parade ends two steps after one. `.idle` drops `offersRetry`, which is the
    /// signal the controller unregisters on; `dismiss()` then cancels the pending
    /// auto-dismiss so nothing is left suspended when the process goes away.
    @MainActor
    static func finish(_ target: any HUDParadeTarget) {
        target.update(phase: .idle)
        target.dismiss()
    }

    // MARK: Run

    @MainActor
    static func run(arguments: [String] = CommandLine.arguments) async {
        let options = Options.parse(arguments)
        if let appearance = options.appearance.nsAppearance {
            NSApp.appearance = appearance
        }

        let steps = schedule(hold: options.hold)
        let hotkeys = ParadeHotkeys()
        let controller = CapsuleController(hotkeys: hotkeys)

        for line in header(appearance: NSApp.effectiveAppearance.name,
                           forced: options.appearance,
                           steps: steps,
                           options: options) {
            print(line)
        }
        fflush(stdout)

        for (index, step) in steps.enumerated() {
            print(line(for: step, index: index, of: steps.count))
            fflush(stdout)
            apply(step, to: controller)
            let advancedByHand = options.waitsForReturn ? await holdUntilReturn(step, on: controller) : false
            if !advancedByHand {
                await holdForDwell(step, on: controller)
            }
        }

        finish(controller)
        print("")
        print("  done — capsule dismissed, ⌘R released"
              + (hotkeys.liveTransients.isEmpty ? "" : " (LEAKED: \(hotkeys.liveTransients))"))
        fflush(stdout)
    }

    /// Sleeps out the dwell, re-applying the state whenever its own lifetime is about
    /// to end. One-shot sleeps, not a timer — nothing here ticks between applications.
    @MainActor
    private static func holdForDwell(_ step: Step, on target: any HUDParadeTarget) async {
        var elapsed: TimeInterval = 0
        for offset in applications(for: step).dropFirst() {
            await sleep(offset - elapsed)
            elapsed = offset
            apply(step, to: target)
        }
        await sleep(step.dwell - elapsed)
    }

    /// Waits for Return, holding the state up in the meantime. Returns false if stdin
    /// is not a place a Return can come from, so the caller falls back to the clock
    /// rather than sprinting through the parade.
    @MainActor
    private static func holdUntilReturn(_ step: Step, on target: any HUDParadeTarget) async -> Bool {
        let holder = step.refreshInterval.map { interval in
            Task { @MainActor in
                while !Task.isCancelled {
                    await sleep(interval)
                    guard !Task.isCancelled else { return }
                    apply(step, to: target)
                }
            }
        }
        let advanced = await readReturn()
        holder?.cancel()
        return advanced
    }

    /// `readLine` off the main actor: the capsule needs the main run loop to draw and
    /// to animate, so blocking it to wait for a keystroke would freeze the thing being
    /// photographed.
    private static func readReturn() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: readLine(strippingNewline: true) != nil)
            }
        }
    }

    private static func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Hotkeys

/// A `HotkeyManaging` that registers nothing, ever.
///
/// `CapsuleController` needs one to hand ⌘R to while a retryable error capsule is up.
/// The real `HotkeyManager` would do exactly what it is built to do — take ⌘R away
/// from every other application via Carbon — and the parade shows a retryable error
/// for seconds at a time on a machine where the owner is dictating into the live
/// Captur. Stealing a system hotkey out of a screenshot tool is the collision this
/// project forbids, so the parade keeps that seam inert and records what *would* have
/// been registered, which is also what makes the leak check at the end mean something.
@MainActor
final class ParadeHotkeys: HotkeyManaging {

    var onAction: ((HotkeyAction) -> Void)?

    /// What the controller asked for and has not given back.
    private(set) var liveTransients: Set<HotkeyAction> = []

    func apply(_ bindings: HotkeyBindings) throws {}
    func setCaptureActive(_ active: Bool) {}
    func suspend() {}
    func resume() {}

    func registerTransient(_ combo: KeyCombo, action: HotkeyAction) throws {
        liveTransients.insert(action)
    }

    func unregisterTransient(_ action: HotkeyAction) {
        liveTransients.remove(action)
    }
}
