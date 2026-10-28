import XCTest
import AppKit
@testable import Captur

/// The parade is a measuring instrument for spec §9, so what has to be tested is not
/// that it runs but that it *misses nothing* and *lies about nothing*.
///
/// Two things are deliberately out of scope, and the report says so rather than these
/// tests pretending otherwise. Nothing here builds a `CapsuleController`: constructing
/// one puts a real `.statusBar`-level panel on the real screen the moment a state goes
/// visible, and these tests run on the machine the owner is dictating on. So the walk
/// below drives a real `CapsulePresenter` — the same state machine, through the same
/// `update(phase:)` / `present(notice:)` calls the controller forwards verbatim — with
/// the window layer left to the orchestrator's GUI run.
@MainActor
final class HUDParadeTests: XCTestCase {

    // MARK: - Test doubles

    /// A one-shot scheduler with a hand-cranked clock. The presenter polls nothing, so
    /// a fake that fires only what was explicitly scheduled is a complete substitute
    /// for `DispatchQueue.main.asyncAfter` — and no test here sleeps.
    @MainActor
    final class ParadeClock: CapsuleScheduling {

        @MainActor
        final class Token: CapsuleScheduledWork {
            var isCancelled = false
            func cancel() { isCancelled = true }
        }

        private struct Pending {
            let fireAt: TimeInterval
            let token: Token
            let work: () -> Void
        }

        private(set) var now: TimeInterval = 0
        private var pending: [Pending] = []

        /// Work that is still going to happen. Zero at the end of the parade is the
        /// "nothing left suspended" assertion.
        var pendingCount: Int { pending.filter { !$0.token.isCancelled }.count }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> any CapsuleScheduledWork {
            let token = Token()
            pending.append(Pending(fireAt: now + delay, token: token, work: work))
            return token
        }

        func advance(_ interval: TimeInterval) {
            now += interval
            while true {
                pending.removeAll { $0.token.isCancelled }
                guard let index = pending
                    .enumerated()
                    .filter({ $0.element.fireAt <= now })
                    .min(by: { $0.element.fireAt < $1.element.fireAt })?
                    .offset
                else { return }
                let due = pending.remove(at: index)
                due.work()
            }
        }
    }

    // MARK: - Completeness

    /// The hole this catches is the whole reason LV7 has never been run: a state that
    /// is not in the schedule is a state nobody photographs, and nothing else in the
    /// build would notice. `StateID` is `CaseIterable` and every `PipelinePhase` /
    /// `CapsuleNotice` case is mapped into it by an exhaustive switch with no
    /// `default`, so a case added to either enum breaks the build before it can go
    /// missing from here.
    func testScheduleCoversEveryPhotographableState() {
        let covered = Set(HUDParade.schedule().map(\.stateID))
        XCTAssertEqual(covered, Set(HUDParade.StateID.photographable))
    }

    func testScheduleShowsEachStateExactlyOnce() {
        let ids = HUDParade.schedule().map(\.stateID)
        XCTAssertEqual(ids.count, Set(ids).count, "a duplicated state wastes the owner's pass")
        XCTAssertEqual(ids.count, HUDParade.StateID.photographable.count)
    }

    /// Every mapped state is reachable, and `hidden` is not in the set because there is
    /// nothing on screen to photograph.
    func testHiddenIsNotPhotographed() {
        XCTAssertEqual(HUDParade.stateID(for: .idle), .hidden)
        XCTAssertFalse(HUDParade.StateID.photographable.contains(.hidden))
        XCTAssertFalse(HUDParade.schedule().map(\.stateID).contains(.hidden))
    }

    /// §9 orders the table hidden → arming → recording → modeSwitched → warning →
    /// transcribing → refining → success → error, and the notices are presented while
    /// the phase underneath is still `.recording` because that is where they occur.
    func testScheduleFollowsTheSpecTableOrder() {
        XCTAssertEqual(HUDParade.schedule().map(\.stateID), [
            .arming,
            .recording,
            .recordingWithElapsed,
            .modeSwitched,
            .warning,
            .transcribing,
            .refining,
            .success,
            .errorRetryable,
            .errorFinal,
        ])
    }

    // MARK: - The states that are hard to reach by hand

    /// §9: elapsed appears after 10 s. The parade reaches the with-elapsed capsule by
    /// passing a large elapsed value, not by standing in front of the screen for ten
    /// seconds — and both halves have to be in the set.
    func testRecordingIsShownWithAndWithoutElapsed() throws {
        let steps = HUDParade.schedule()
        let bare = try XCTUnwrap(steps.first { $0.stateID == .recording })
        let timed = try XCTUnwrap(steps.first { $0.stateID == .recordingWithElapsed })

        XCTAssertEqual(bare.detail, "Listening")
        XCTAssertEqual(timed.detail, "Listening · 12:34")
        XCTAssertTrue(bare.content.showsWaveform)
        XCTAssertTrue(bare.content.waveformIsLive)
        XCTAssertTrue(bare.content.showsPulsingDot)
    }

    /// Both error rows. `retryable` is the pipeline's word for "the audio is still on
    /// disk", and it changes the glyph, the reassurance and the ⌘R offer — three
    /// visible differences, so it is two screenshots and not one.
    func testBothErrorsAreShown() throws {
        let steps = HUDParade.schedule()
        let retryable = try XCTUnwrap(steps.first { $0.stateID == .errorRetryable })
        let final = try XCTUnwrap(steps.first { $0.stateID == .errorFinal })

        let retryableText = try XCTUnwrap(retryable.detail)
        XCTAssertTrue(retryableText.contains(CapsuleState.retryHint))
        XCTAssertTrue(retryableText.contains(CapsuleState.audioSavedHint))

        let finalText = try XCTUnwrap(final.detail)
        XCTAssertFalse(finalText.contains(CapsuleState.retryHint))
        XCTAssertFalse(finalText.contains(CapsuleState.audioSavedHint))
        XCTAssertNotEqual(retryable.content.symbolName, final.content.symbolName)
    }

    /// `modeSwitched` and `refining` are unreachable in this build — modes are Task 16
    /// — so the parade has to reach them through the values, and the values have to be
    /// the ones production would produce.
    func testTheUnreachableModeStatesAreInTheSet() throws {
        let steps = HUDParade.schedule()
        let switched = try XCTUnwrap(steps.first { $0.stateID == .modeSwitched })
        let refining = try XCTUnwrap(steps.first { $0.stateID == .refining })

        XCTAssertEqual(switched.detail, "Email")
        XCTAssertEqual(refining.detail, "Email")
        XCTAssertEqual(refining.content.showsShimmer, true)
    }

    /// The parade injects the `modeSwitched` notice through `present(notice:)`. That is
    /// not a shortcut around production: production reaches the same state by handing
    /// the presenter a `.recording` phase with a new mode name, and the presenter then
    /// calls `present(notice: .modeSwitched(name:))` itself. This pins the two together
    /// so the injected value cannot drift from the derived one.
    func testTheModeSwitchedNoticeIsTheValueThePipelineWouldDerive() throws {
        let derived = try XCTUnwrap(CapsulePresenter.modeSwitchName(
            from: .recording(elapsed: 754, modeName: "Default"),
            to: .recording(elapsed: 754, modeName: "Email")))

        let step = try XCTUnwrap(HUDParade.schedule().first { $0.stateID == .modeSwitched })
        XCTAssertEqual(step.content, CapsuleState.content(for: .modeSwitched(name: derived)))
    }

    // MARK: - Pacing

    func testEveryDwellClearsTheScreenshotFloor() {
        XCTAssertFalse(HUDParade.schedule().isEmpty)
        for step in HUDParade.schedule() {
            XCTAssertGreaterThanOrEqual(step.dwell, HUDParade.minimumHold, step.label)
        }
    }

    func testHoldOverrideIsHonoured() {
        XCTAssertEqual(HUDParade.Options.parse(["--hud-parade", "--hold", "6.5"]).hold, 6.5)
        XCTAssertFalse(HUDParade.schedule(hold: 6.5).isEmpty)
        for step in HUDParade.schedule(hold: 6.5) {
            XCTAssertEqual(step.dwell, 6.5)
        }
    }

    /// A hold under the floor is raised, and the header says it was. Honouring it
    /// verbatim would hand back a state nobody can photograph; raising it silently
    /// would hand back a pace the owner did not ask for and cannot see.
    func testHoldBelowTheFloorIsRaisedAndDisclosed() {
        let options = HUDParade.Options.parse(["--hud-parade", "--hold", "1"])
        XCTAssertEqual(options.hold, HUDParade.minimumHold)
        XCTAssertEqual(options.notes.count, 1)
        XCTAssertTrue(options.notes[0].contains("2.5"), options.notes[0])

        let disclosed = HUDParade.header(appearance: .aqua,
                                         forced: .system,
                                         steps: HUDParade.schedule(hold: options.hold),
                                         options: options).joined(separator: "\n")
        XCTAssertTrue(disclosed.contains(options.notes[0]), disclosed)
    }

    func testHoldAboveTheFloorIsNotDisclosedAsAChange() {
        XCTAssertTrue(HUDParade.Options.parse(["--hold", "9"]).notes.isEmpty)
    }

    func testStepModeIsOptIn() {
        XCTAssertFalse(HUDParade.Options.parse(["--hud-parade"]).waitsForReturn)
        XCTAssertTrue(HUDParade.Options.parse(["--hud-parade", "--step"]).waitsForReturn)
    }

    func testAppearanceOverrideIsOptIn() {
        XCTAssertEqual(HUDParade.Options.parse(["--hud-parade"]).appearance, .system)
        XCTAssertEqual(HUDParade.Options.parse(["--hud-parade", "--appearance", "dark"]).appearance, .dark)
        XCTAssertEqual(HUDParade.Options.parse(["--hud-parade", "--appearance", "LIGHT"]).appearance, .light)
        XCTAssertEqual(HUDParade.Options.parse(["--hud-parade", "--appearance", "sepia"]).appearance, .system)
        XCTAssertNil(HUDParade.Appearance.system.nsAppearance)
        XCTAssertNotNil(HUDParade.Appearance.dark.nsAppearance)
    }

    // MARK: - Holding a state that dismisses itself

    /// `success` (1.2 s), `modeSwitched` (1.4 s) and `warning` (2.5 s) collapse on
    /// their own §9 schedule, which is shorter than the time a person needs to take a
    /// screenshot. The parade re-applies them instead of suppressing the timer, and the
    /// arithmetic here is the proof that the last application outlives the dwell.
    func testAutoDismissingStatesAreHeldPastTheirOwnLifetime() throws {
        let steps = HUDParade.schedule()
        let dismissing = steps.filter { $0.autoDismissAfter != nil }
        XCTAssertEqual(Set(dismissing.map(\.stateID)),
                       [.modeSwitched, .warning, .success, .errorRetryable, .errorFinal])

        for step in dismissing {
            let lifetime = try XCTUnwrap(step.autoDismissAfter)
            let last = try XCTUnwrap(HUDParade.applications(for: step).last)
            XCTAssertGreaterThan(last + lifetime, step.dwell,
                                 "\(step.label) collapses \(step.dwell - (last + lifetime))s before its dwell ends")
        }
    }

    /// Holding still works when the owner asks for a much longer dwell — the case
    /// where `error`'s own 4 s stops being enough.
    func testHoldingSurvivesALongHold() throws {
        XCTAssertEqual(HUDParade.schedule(hold: 30).filter { $0.autoDismissAfter != nil }.count, 5)
        for step in HUDParade.schedule(hold: 30) where step.autoDismissAfter != nil {
            let lifetime = try XCTUnwrap(step.autoDismissAfter)
            let last = try XCTUnwrap(HUDParade.applications(for: step).last)
            XCTAssertGreaterThan(last + lifetime, step.dwell, step.label)
        }
    }

    /// The states with no lifetime of their own stay up by themselves, so re-applying
    /// them would be churn.
    func testOpenEndedStatesAreAppliedOnce() {
        let openEnded = HUDParade.schedule().filter { $0.autoDismissAfter == nil }
        XCTAssertEqual(Set(openEnded.map(\.stateID)),
                       [.arming, .recording, .recordingWithElapsed, .transcribing, .refining])
        for step in HUDParade.schedule() where step.autoDismissAfter == nil {
            XCTAssertNil(step.refreshInterval, step.label)
            XCTAssertEqual(HUDParade.applications(for: step), [0], step.label)
        }
    }

    // MARK: - What the owner reads

    /// The printed line is how a screenshot is matched to a state afterwards. If it
    /// does not name the state, the set is a folder of unlabelled capsules.
    func testEveryLineNamesItsStateAndPosition() {
        let steps = HUDParade.schedule()
        XCTAssertFalse(steps.isEmpty)
        for (index, step) in steps.enumerated() {
            let line = HUDParade.line(for: step, index: index, of: steps.count)
            XCTAssertTrue(line.contains(step.label), line)
            XCTAssertTrue(line.contains("\(index + 1)/\(steps.count)"), line)
            XCTAssertTrue(line.contains("3.0s"), line)
            if let detail = step.detail {
                XCTAssertTrue(line.contains(detail), line)
            }
        }
    }

    /// A re-presented state is a state whose §9 duration the owner is not seeing. That
    /// has to be on the line, or the parade is quietly contradicting the spec it exists
    /// to verify.
    func testRePresentationIsDisclosedOnTheLine() throws {
        let steps = HUDParade.schedule()
        XCTAssertFalse(steps.isEmpty)
        for (index, step) in steps.enumerated() {
            let line = HUDParade.line(for: step, index: index, of: steps.count)
            if HUDParade.applications(for: step).count > 1 {
                let lifetime = try XCTUnwrap(step.autoDismissAfter)
                XCTAssertTrue(line.contains("re-presented"), line)
                XCTAssertTrue(line.contains(String(format: "%.1fs", lifetime)), line)
            } else {
                // The other half of the same rule: a state that is applied once must
                // not advertise a hold. `error` lasts 4 s on its own, longer than the
                // default dwell, so nothing is being held for it.
                XCTAssertFalse(line.contains("re-presented"), "claims a hold it never performs: \(line)")
            }
        }
        // Both branches have to be exercised or this test proves only one of them.
        let held = steps.filter { HUDParade.applications(for: $0).count > 1 }
        XCTAssertEqual(Set(held.map(\.stateID)), [.modeSwitched, .warning, .success])
    }

    /// Two passes of the same ten capsules are indistinguishable a day later unless
    /// each pass says which appearance it was.
    func testHeaderNamesTheEffectiveAppearance() {
        let options = HUDParade.Options.parse(["--hud-parade"])
        let steps = HUDParade.schedule()

        let dark = HUDParade.header(appearance: .darkAqua, forced: .system, steps: steps, options: options)
            .joined(separator: "\n")
        XCTAssertTrue(dark.contains("DARK"), dark)
        XCTAssertTrue(dark.contains(NSAppearance.Name.darkAqua.rawValue), dark)

        let light = HUDParade.header(appearance: .aqua, forced: .system, steps: steps, options: options)
            .joined(separator: "\n")
        XCTAssertTrue(light.contains("LIGHT"), light)
        XCTAssertFalse(light.contains("DARK"), light)
    }

    func testAppearanceLabelReadsBothVibrantAndHighContrastVariants() {
        XCTAssertEqual(HUDParade.appearanceLabel(.darkAqua), "DARK")
        XCTAssertEqual(HUDParade.appearanceLabel(.vibrantDark), "DARK")
        XCTAssertEqual(HUDParade.appearanceLabel(.accessibilityHighContrastDarkAqua), "DARK")
        XCTAssertEqual(HUDParade.appearanceLabel(.aqua), "LIGHT")
        XCTAssertEqual(HUDParade.appearanceLabel(.vibrantLight), "LIGHT")
    }

    /// A forced appearance is labelled as forced, so a screenshot taken under
    /// `--appearance dark` on a light system cannot later be read as the system's own.
    func testForcedAppearanceIsLabelledAsForced() {
        let header = HUDParade.header(appearance: .darkAqua,
                                      forced: .dark,
                                      steps: HUDParade.schedule(),
                                      options: HUDParade.Options.parse(["--appearance", "dark"]))
            .joined(separator: "\n")
        XCTAssertTrue(header.contains("--appearance dark"), header)
    }

    func testHeaderCountsTheStates() {
        let steps = HUDParade.schedule()
        let header = HUDParade.header(appearance: .aqua,
                                      forced: .system,
                                      steps: steps,
                                      options: HUDParade.Options.parse([]))
            .joined(separator: "\n")
        XCTAssertTrue(header.contains("\(steps.count)"), header)
    }

    // MARK: - Walking the real state machine

    /// The measurement that matters: walking the schedule through the real presenter
    /// puts the real §9 content on the capsule for every state, and every state is
    /// still up when the dwell ends.
    ///
    /// This is what separates the parade from a preview. The expected content is read
    /// from `CapsuleState` — the same table the shipping HUD renders from — so a step
    /// that reached a different state than it claimed would fail here.
    func testWalkingTheScheduleDrivesThePresenterToEverySpecContent() throws {
        let clock = ParadeClock()
        let presenter = CapsulePresenter(scheduler: clock)
        let steps = HUDParade.schedule()
        XCTAssertEqual(steps.count, HUDParade.StateID.photographable.count,
                       "an empty or short schedule must not walk vacuously")

        var seen: [CapsuleContent] = []
        for step in steps {
            let offsets = HUDParade.applications(for: step)
            var elapsed: TimeInterval = 0
            for offset in offsets {
                clock.advance(offset - elapsed)
                elapsed = offset
                HUDParade.apply(step, to: presenter)
            }
            // A hair short of the dwell: the instant the owner is still able to shoot.
            clock.advance(step.dwell - elapsed - 0.01)

            XCTAssertTrue(presenter.isVisible, "\(step.label) left the screen before its dwell ended")
            XCTAssertEqual(presenter.content, step.content, step.label)
            seen.append(presenter.content)
        }

        XCTAssertEqual(seen.count, steps.count)
        // Ten steps that rendered nine distinct capsules would mean one state was
        // never actually seen, however faithfully it was applied.
        for (left, right) in indexPairs(of: seen.count) {
            XCTAssertNotEqual(seen[left], seen[right],
                              "\(steps[left].label) and \(steps[right].label) render identically")
        }
    }

    private func indexPairs(of count: Int) -> [(Int, Int)] {
        (0..<count).flatMap { left in ((left + 1)..<count).map { (left, $0) } }
    }

    /// The recording capsule is the one state with an unverified change in it: the
    /// waveform used to be tinted with the state colour and is now monochrome. The
    /// parade cannot assert a colour — that is what LV7's eyes are for — but it can
    /// assert it drives the capsule into the state where the change is visible, with
    /// the dot still carrying red.
    func testTheRecordingStatesReachTheCapsuleThatHoldsTheUnverifiedChange() throws {
        let clock = ParadeClock()
        let presenter = CapsulePresenter(scheduler: clock)

        let recordings = HUDParade.schedule().filter {
            $0.stateID == .recording || $0.stateID == .recordingWithElapsed
        }
        XCTAssertEqual(recordings.count, 2)
        for step in recordings {
            HUDParade.apply(step, to: presenter)
            XCTAssertTrue(presenter.content.showsWaveform, step.label)
            XCTAssertTrue(presenter.content.waveformIsLive, step.label)
            XCTAssertEqual(presenter.content.tint, .danger, step.label)
        }
    }

    // MARK: - Teardown

    /// ⌘R is registered **system-wide** while a retryable error capsule is visible, and
    /// the parade shows one. `offersRetry` is the exact signal `CapsuleController`
    /// registers and unregisters on, so it is the flag that has to be false when the
    /// parade ends.
    func testTheRetryableErrorOffersRetryAndFinishRevokesIt() throws {
        let clock = ParadeClock()
        let presenter = CapsulePresenter(scheduler: clock)
        let steps = HUDParade.schedule()

        HUDParade.apply(try XCTUnwrap(steps.first { $0.stateID == .errorRetryable }), to: presenter)
        XCTAssertTrue(presenter.offersRetry, "the retryable error must arm ⌘R, or the state is not faithful")

        HUDParade.finish(presenter)
        XCTAssertFalse(presenter.offersRetry)
    }

    /// Nothing on screen, nothing armed, nothing still scheduled — the three ways an
    /// instrument can outlive itself.
    func testFinishLeavesNothingBehindAfterAFullWalk() {
        let clock = ParadeClock()
        let presenter = CapsulePresenter(scheduler: clock)
        XCTAssertFalse(HUDParade.schedule().isEmpty)

        for step in HUDParade.schedule() {
            for offset in HUDParade.applications(for: step) {
                _ = offset
                HUDParade.apply(step, to: presenter)
            }
        }
        HUDParade.finish(presenter)

        XCTAssertFalse(presenter.isVisible)
        XCTAssertFalse(presenter.offersRetry)
        XCTAssertEqual(clock.pendingCount, 0, "a scheduled dismissal outlived the parade")
        XCTAssertNil(presenter.notice)
        XCTAssertEqual(presenter.phase, .idle)
    }

    /// `update(phase: .idle)` alone is not a teardown, which is why `finish` also
    /// dismisses. The presenter only clears a pending notice when the phase *kind*
    /// changes, so a notice presented while the phase is already idle keeps its own
    /// scheduled expiry — work that would outlive the parade if the dismissal were
    /// dropped. (Found by mutation: deleting `dismiss()` from `finish` passed every
    /// other test here.)
    func testFinishCancelsANoticeLeftOverAnIdlePhase() {
        let clock = ParadeClock()
        let presenter = CapsulePresenter(scheduler: clock)

        presenter.present(notice: .warning(text: "Microphone changed"))
        XCTAssertEqual(clock.pendingCount, 1, "the notice's own expiry should be scheduled")

        HUDParade.finish(presenter)

        XCTAssertEqual(clock.pendingCount, 0, "a notice expiry outlived the parade")
        XCTAssertNil(presenter.notice)
        XCTAssertFalse(presenter.isVisible)
    }

    /// The hotkey seam the parade hands to `CapsuleController` registers nothing. The
    /// real `HotkeyManager` would take ⌘R from every other app via Carbon while the
    /// error capsule is up, on a machine where the owner is dictating into the live
    /// Captur — so the parade keeps the seam inert and countable.
    func testTheParadeHotkeySeamIsInertAndBalanced() throws {
        let hotkeys = ParadeHotkeys()
        XCTAssertTrue(hotkeys.liveTransients.isEmpty)

        try hotkeys.registerTransient(CapsuleState.retryCombo, action: .retryLast)
        XCTAssertEqual(hotkeys.liveTransients, [.retryLast])

        hotkeys.unregisterTransient(.retryLast)
        XCTAssertTrue(hotkeys.liveTransients.isEmpty)

        // Nothing else it is asked for during a parade may reach the system either.
        try hotkeys.apply(.default)
        hotkeys.setCaptureActive(true)
        hotkeys.suspend()
        hotkeys.resume()
        XCTAssertTrue(hotkeys.liveTransients.isEmpty)
    }
}
