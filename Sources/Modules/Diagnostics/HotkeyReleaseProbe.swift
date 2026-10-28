import AppKit
import Carbon.HIToolbox

/// Measures whether Carbon will tell us when a chord hotkey is **released**.
///
/// It exists because push-to-talk on a chord (⌘⇧D) needs two edges and the app has only
/// ever asked Carbon for one. `HotkeyManager.installHandlerIfNeeded()` registers
/// `kEventHotKeyPressed` alone; the modifier-only push-to-talk keys get their up edge
/// from `NSEvent.flagsChanged`, which a chord cannot use.
///
/// Three questions decide the design, and all three have exactly one honest answer —
/// a measured one:
///
///   1. Does `kEventHotKeyReleased` arrive at all?
///   2. Does it still arrive when the MODIFIERS are released before the key? This is the
///      one that matters. If the answer is no, a naive implementation leaves a recording
///      running with the microphone open and nothing on screen — the worst failure this
///      app can have.
///   3. Does holding the chord produce repeat presses that a latch would have to filter?
///
/// Reading the documentation cannot answer 2. This project is four for four on real bugs
/// that survived careful code reading and died instantly to measurement, so the
/// instrument comes before the feature.
///
/// The probe registers its own hotkey directly against Carbon rather than going through
/// `HotkeyManager`, because the whole point is to find out what Carbon does before
/// deciding what `HotkeyManager` should ask it for.
@MainActor
enum HotkeyReleaseProbe {

    /// ⌘⇧D — the binding this was built to answer a question about.
    static let defaultKeyCode = UInt32(kVK_ANSI_D)
    static let defaultModifiers = UInt32(cmdKey) | UInt32(shiftKey)
    static let defaultSeconds: TimeInterval = 30

    /// One observed event, press or release or a modifier change, with the physical
    /// modifier state at that instant. The modifier column is the evidence for question
    /// 2: a release logged while ⌘ and ⇧ are already up is the good case, and no release
    /// line at all after the flags dropped is the bad one.
    struct Edge {
        enum Kind: String {
            case pressed = "HOTKEY PRESSED "
            case released = "HOTKEY RELEASED"
            case flags = "flags          "
        }
        let kind: Kind
        let at: TimeInterval
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
    }

    // MARK: State

    private static var edges: [Edge] = []
    private static var started: TimeInterval = 0
    private static var hotkeyRef: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var flagsMonitor: Any?

    // MARK: Run

    static func run(arguments: [String]) {
        let seconds = parseSeconds(arguments) ?? defaultSeconds
        started = ProcessInfo.processInfo.systemUptime

        print("--- hotkey release probe ---")
        print("  chord:    \(ShortcutNotation.glyphs(forCarbon: defaultModifiers))"
              + ShortcutNotation.keyLabel(forKeyCode: defaultKeyCode))
        print("  window:   \(Int(seconds))s")
        print("")

        guard install() else {
            print("✗ Carbon refused to register the chord. Something else owns it.")
            print("  (That is itself an answer: the binding is unavailable on this machine.)")
            NSApplication.shared.terminate(nil)
            return
        }

        print("Do these three things, in order, pausing about a second between each:")
        print("")
        print("  1. HOLD the chord for ~2 seconds, then release everything together.")
        print("  2. HOLD it again, then release the MODIFIERS FIRST, keeping D down")
        print("     for another second before letting go.  ← the one that matters")
        print("  3. TAP it quickly, once.")
        print("")
        print("Every edge is printed as it happens. Times are ms from the probe start.")
        print("")

        Task { @MainActor in
            if arguments.contains("--synthesize") {
                await synthesize()
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            teardown()
            report()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: Synthetic drive

    /// Runs the three sequences by injecting HID events instead of waiting for a hand.
    ///
    /// This is the CONTROLLED half of the experiment, and it is better than a human at
    /// exactly one thing: the ordering in step 2. A hand cannot reliably release ⌘ and ⇧
    /// a known number of milliseconds before D, and that interval is the variable under
    /// test. Injected events are posted to the HID tap, the lowest level available, so
    /// Carbon sees them the same way it sees a keyboard.
    ///
    /// It does NOT replace the hardware run. Injection and a real keyboard have differed
    /// before in this codebase's history of stubs that lied, so `--synthesize` answers the
    /// ordering question and a real hold confirms the answer transfers.
    private static func synthesize() async {
        guard CGEventSource(stateID: .hidSystemState) != nil else {
            print("✗ Could not create an event source — Accessibility is not granted.")
            return
        }

        print(">>> sequence 1: hold, then release everything together")
        modifiers(down: true)
        try? await Task.sleep(for: .milliseconds(60))
        key(down: true, flags: [.maskCommand, .maskShift])
        try? await Task.sleep(for: .milliseconds(800))
        key(down: false, flags: [.maskCommand, .maskShift])
        modifiers(down: false)
        try? await Task.sleep(for: .milliseconds(600))

        print("")
        print(">>> sequence 2: hold, release the MODIFIERS FIRST, D up 500ms later")
        modifiers(down: true)
        try? await Task.sleep(for: .milliseconds(60))
        key(down: true, flags: [.maskCommand, .maskShift])
        try? await Task.sleep(for: .milliseconds(500))
        modifiers(down: false)                 // ⌘ and ⇧ go up while D is still down
        try? await Task.sleep(for: .milliseconds(500))
        key(down: false, flags: [])            // …and D comes up carrying NO modifiers
        try? await Task.sleep(for: .milliseconds(600))

        print("")
        print(">>> sequence 3: quick tap")
        modifiers(down: true)
        try? await Task.sleep(for: .milliseconds(60))
        key(down: true, flags: [.maskCommand, .maskShift])
        try? await Task.sleep(for: .milliseconds(80))
        key(down: false, flags: [.maskCommand, .maskShift])
        modifiers(down: false)
        try? await Task.sleep(for: .milliseconds(600))
    }

    private static func key(down: Bool, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(defaultKeyCode),
                                  keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Posts the modifier keys as real key events rather than only setting flags, so the
    /// system's own notion of what is physically held moves with them — which is what
    /// `NSEvent.modifierFlags` in the release log reads.
    private static func modifiers(down: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let commandKey = CGKeyCode(kVK_Command)
        let shiftKeyCode = CGKeyCode(kVK_Shift)
        let commandOnly: CGEventFlags = CGEventFlags.maskCommand
        let both: CGEventFlags = [CGEventFlags.maskCommand, CGEventFlags.maskShift]
        let none: CGEventFlags = []

        // Down: ⌘ then ⇧, accumulating. Up: the reverse, shedding.
        var steps: [(CGKeyCode, CGEventFlags)] = []
        if down {
            steps.append((commandKey, commandOnly))
            steps.append((shiftKeyCode, both))
        } else {
            steps.append((shiftKeyCode, commandOnly))
            steps.append((commandKey, none))
        }

        for (code, flags) in steps {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: code,
                                      keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    private static func parseSeconds(_ arguments: [String]) -> TimeInterval? {
        guard let index = arguments.firstIndex(of: "--probe-hotkey-release"),
              index + 1 < arguments.count,
              let value = Double(arguments[index + 1])
        else { return nil }
        return value
    }

    // MARK: Carbon

    private static func install() -> Bool {
        // BOTH event kinds. Asking for the release edge is the entire experiment.
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetEventDispatcherTarget(),
                            probeEventCallback,
                            2,
                            &specs,
                            nil,
                            &handler)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(defaultKeyCode,
                                        defaultModifiers,
                                        EventHotKeyID(signature: 0x50524F42, id: 1), // 'PROB'
                                        GetEventDispatcherTarget(),
                                        0,
                                        &ref)
        guard status == noErr, let ref else { return false }
        hotkeyRef = ref

        // Logged alongside the hotkey edges so the ORDER of the modifier drop versus the
        // release is visible. Without this column question 2 cannot be answered: a
        // missing release and a release that arrived before the modifiers came up look
        // the same in a list of hotkey events alone.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                record(.flags, keyCode: event.keyCode, modifiers: event.modifierFlags)
            }
        }
        if flagsMonitor == nil {
            print("⚠︎  No global flagsChanged monitor — Input Monitoring is not granted to")
            print("   the responsible process, so the modifier column will be empty.")
            print("")
        }
        return true
    }

    private static func teardown() {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let handler { RemoveEventHandler(handler) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        hotkeyRef = nil
        handler = nil
        flagsMonitor = nil
    }

    // MARK: Recording

    fileprivate static func record(_ kind: Edge.Kind,
                                   keyCode: UInt16,
                                   modifiers: NSEvent.ModifierFlags) {
        let at = ProcessInfo.processInfo.systemUptime - started
        edges.append(Edge(kind: kind, at: at, modifiers: modifiers, keyCode: keyCode))

        let ms = String(format: "%6.0f", at * 1000)
        let glyphs = ShortcutNotation.glyphs(
            forCarbon: ShortcutNotation.carbonModifiers(from: modifiers))
        // A modifier line is indented so the hotkey edges stay readable at a glance.
        let indent: String = (kind == .flags) ? "    " : "  "
        let held: String = glyphs.isEmpty ? "—" : glyphs
        let line: String = indent + ms + " ms  " + kind.rawValue + "  held: " + held
        print(line)
    }

    fileprivate static func recordHotkey(released: Bool) {
        record(released ? .released : .pressed,
               keyCode: UInt16(defaultKeyCode),
               modifiers: NSEvent.modifierFlags)
    }

    // MARK: Verdict

    /// Says what was observed and, deliberately, what was NOT — an absent release edge is
    /// the finding, and a report that only lists what happened would print nothing at all
    /// in exactly the case the probe was built to catch.
    private static func report() {
        let presses = edges.filter { $0.kind == .pressed }
        let releases = edges.filter { $0.kind == .released }

        print("")
        print("--- what was observed ---")
        print("  presses:  \(presses.count)")
        print("  releases: \(releases.count)")
        print("")

        guard !presses.isEmpty else {
            print("VERDICT: INCONCLUSIVE — the chord was never pressed.")
            print("  Nothing was measured. If you did press it, Carbon registered the")
            print("  hotkey but the event never arrived, which is itself worth knowing.")
            return
        }

        if releases.isEmpty {
            print("VERDICT: NO RELEASE EDGE. kEventHotKeyReleased never fired.")
            print("  Chord push-to-talk cannot rely on Carbon for the up edge. The")
            print("  fallback is a flagsChanged watcher that synthesizes the release when")
            print("  the chord's modifiers drop, plus a maximum-hold cap.")
            return
        }

        // The pairing question: every press should have a release. A shortfall is the
        // stuck-microphone bug, so it is named as one rather than left as arithmetic.
        if releases.count < presses.count {
            print("VERDICT: RELEASE EDGE IS UNRELIABLE — \(presses.count) presses,"
                  + " \(releases.count) releases.")
            print("  At least one hold ended with no release event. That is the stuck-")
            print("  microphone case: a safety net is mandatory, not optional.")
        } else {
            print("VERDICT: RELEASE EDGE FIRES, paired with every press.")
        }

        // Did any release arrive while the modifiers were ALREADY up? That is the
        // modifiers-first case surviving, which is what step 2 was for.
        let modifiersFirst = releases.filter {
            !$0.modifiers.contains(.command) || !$0.modifiers.contains(.shift)
        }
        print("")
        print("  releases seen with ⌘⇧ no longer held: \(modifiersFirst.count)")
        if modifiersFirst.isEmpty {
            print("  → the modifiers-first case was either not exercised or did not")
            print("    deliver a release. Re-run and do step 2 deliberately.")
        } else {
            print("  → the modifiers-first release survives; ordering is not a trap.")
        }

        // Repeats while held would have to be filtered. PushToTalkLatch already ignores a
        // second down while `.held`, so this is a confirmation, not a discovery.
        let repeats = presses.count - releases.count
        print("")
        print("  press/release delta: \(repeats)"
              + (repeats > 0 ? "  (extra presses — auto-repeat is real, filter it)"
                             : "  (no auto-repeat while held)"))
    }
}

// MARK: - Carbon C callback

/// Free function so it converts cleanly to an `EventHandlerUPP`. Carbon dispatches hotkey
/// events on the main thread, so the hop is a safe `assumeIsolated` — the same reasoning
/// as `HotkeyManager`'s callback.
private func probeEventCallback(_ callRef: EventHandlerCallRef?,
                                _ eventRef: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let eventRef else { return noErr }
    let released = GetEventKind(eventRef) == UInt32(kEventHotKeyReleased)
    MainActor.assumeIsolated {
        HotkeyReleaseProbe.recordHotkey(released: released)
    }
    return noErr
}
