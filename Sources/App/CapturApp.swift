import AppKit
import Darwin
import SwiftUI

@main
struct CapturApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var composition: AppComposition?

    /// What this launch decided to do. Read by `AppLaunchModeTests` so the test-host
    /// guard is verified in the process it protects, not asserted about in the abstract.
    ///
    /// It is `static` because under `@NSApplicationDelegateAdaptor` the object at
    /// `NSApplication.shared.delegate` is SwiftUI's own forwarding delegate, not this
    /// one — measured, not assumed — so a test cannot reach the instance.
    @MainActor private(set) static var launchDecision: LaunchDecision = .notLaunchedYet

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted BY this app, so a test run launches it. Building the
        // composition root here would register the global hotkeys, install a status item
        // and bind an audio engine from a test process — a second Captur competing with
        // the real one for ⌥Space and the default input device. Nothing under test needs
        // it: every test constructs the units it exercises.
        if AppLaunchMode.isRunningTests() {
            Self.launchDecision = .suppressedForTests
            return
        }

        if CommandLine.arguments.contains("--probe-phonon") {
            Self.launchDecision = .ranInstrument("--probe-phonon")
            Task {
                let succeeded = await PhononProbe.run(arguments: CommandLine.arguments)
                diagnosticExitStatus = succeeded ? EXIT_SUCCESS : EXIT_FAILURE
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if CommandLine.arguments.contains("--preview-codex") {
            Self.launchDecision = .ranInstrument("--preview-codex")
            CodexPreview.show()
            return
        }

        if CommandLine.arguments.contains("--probe-codex") {
            Self.launchDecision = .ranInstrument("--probe-codex")
            Task {
                let succeeded = await CodexProbe.run(arguments: CommandLine.arguments)
                diagnosticExitStatus = succeeded ? EXIT_SUCCESS : EXIT_FAILURE
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if CommandLine.arguments.contains("--probe-cleanup") || CommandLine.arguments.contains("--probe-gemma") {
            Self.launchDecision = .ranInstrument("--probe-cleanup")
            let arguments = CommandLine.arguments.contains("--probe-cleanup") ? CommandLine.arguments :
                CommandLine.arguments + ["--probe-cleanup", ModeCleanupChoice.localGemma.rawValue]
            Task {
                let succeeded = await CleanupProbe.run(arguments: arguments)
                diagnosticExitStatus = succeeded ? EXIT_SUCCESS : EXIT_FAILURE
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if CommandLine.arguments.contains("--compare-clean") {
            Self.launchDecision = .ranInstrument("--compare-clean")
            Task {
                let succeeded = await CleanComparisonProbe.run(arguments: CommandLine.arguments)
                diagnosticExitStatus = succeeded ? EXIT_SUCCESS : EXIT_FAILURE
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if CommandLine.arguments.contains("--probe-context") {
            Self.launchDecision = .ranInstrument("--probe-context")
            Task {
                await ContextProbe.run(arguments: CommandLine.arguments)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Runs before any store is constructed so the migrated data is what they read.
        // A failure is logged and retried next launch; it never blocks startup.
        let result = Migration.runIfNeeded()
        if case .failed(let reason) = result {
            NSLog("[Captur] migration deferred: \(reason)")
        }

        // `Captur --diagnose [seconds] [--no-aec]` runs one capture, prints the report
        // to stdout, and exits. It exists so a dead microphone can be read from a
        // terminal instead of relayed by hand through a GUI — the failure this app
        // shipped with last time was invisible precisely because nothing printed.
        if CommandLine.arguments.contains("--diagnose") {
            Self.launchDecision = .ranInstrument("--diagnose")
            runHeadlessDiagnostics()
            return
        }

        // `Captur --probe-vad <file.flac>` replays a saved recording through the real
        // voice-activity detector and prints what it decides. It exists because a
        // recording holding obvious speech was reported as "No speech was heard", and
        // "the audio never arrived" and "the detector called speech silence" read
        // identically in source.
        if let index = CommandLine.arguments.firstIndex(of: "--probe-vad"),
           index + 1 < CommandLine.arguments.count {
            let sensitivity = CommandLine.arguments
                .compactMap(VADSensitivity.init(rawValue:)).first ?? .normal
            Self.launchDecision = .ranInstrument("--probe-vad")
            VADProbe.run(path: CommandLine.arguments[index + 1], sensitivity: sensitivity)
            NSApplication.shared.terminate(nil)
            return
        }

        // `Captur --probe-latency [runs] [file]` re-sends a recording the app already
        // saved and reports the Groq round trip as a distribution. It exists because
        // LV5's 800 ms budget was standing on two samples that disagreed by 10x.
        if CommandLine.arguments.contains("--probe-latency") {
            Self.launchDecision = .ranInstrument("--probe-latency")
            let runs = CommandLine.arguments.compactMap(Int.init).first ?? 10
            // Every extension the uploader can label, not `.flac` alone. Filtering on one
            // format meant an argument in any other silently vanished and the probe
            // measured the newest saved capture instead — while printing that file's name
            // as if it had been asked for. An instrument that answers a question about a
            // different file than the one you named is worse than no instrument.
            let file = CommandLine.arguments.first { argument in
                GroqClient.supportedAudioExtensions.contains {
                    argument.lowercased().hasSuffix(".\($0)")
                }
            }
            // A path-shaped argument that is NOT a usable audio file is a mistake, and it
            // fails loudly rather than being quietly replaced by a fallback.
            if file == nil,
               let stray = CommandLine.arguments.dropFirst().first(where: {
                   $0.contains("/") && !$0.hasPrefix("--")
               }) {
                print("✗ \(stray) is not an audio format this uploader can label.")
                print("  Supported: \(GroqClient.supportedAudioExtensions.sorted().joined(separator: ", "))")
                NSApplication.shared.terminate(nil)
                return
            }
            Task { @MainActor in
                await LatencyProbe.run(runs: runs, path: file)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // `Captur --probe-chat [modeID]` sends one messy sentence through a real mode
        // against the real API. GroqChatClient shipped with 18 tests and zero live
        // requests; a stub cannot tell you Groq renamed a field.
        if CommandLine.arguments.contains("--probe-chat") {
            Self.launchDecision = .ranInstrument("--probe-chat")
            let index = CommandLine.arguments.firstIndex(of: "--probe-chat")!
            let modeID = index + 1 < CommandLine.arguments.count
                && !CommandLine.arguments[index + 1].hasPrefix("--")
                ? CommandLine.arguments[index + 1] : nil
            Task { @MainActor in
                await ChatProbe.run(modeID: modeID)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // `Captur --permissions` prints what macOS actually thinks this build is
        // allowed to do, from inside the app — the only place the answer is true. TCC is
        // per-app, so a helper script asking the same question answers it about the
        // script. Add `--request` to also ask for anything missing.
        if CommandLine.arguments.contains("--permissions") {
            Self.launchDecision = .ranInstrument("--permissions")
            runPermissionsReport(requesting: CommandLine.arguments.contains("--request"))
            return
        }

        // `Captur --probe-vp [seconds]` dumps every channel of the voice-processing tap
        // separately. It is a measuring instrument, not a feature: AEC silence has two
        // explanations that read identically in source, and only this run tells them apart.
        if CommandLine.arguments.contains("--probe-vp") {
            Self.launchDecision = .ranInstrument("--probe-vp")
            let seconds = CommandLine.arguments.compactMap(Double.init).first ?? 4
            Task { @MainActor in
                await VoiceProcessingProbe.run(seconds: seconds)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // `Captur --hud-parade [--hold <seconds>] [--step] [--appearance light|dark]`
        // walks the real capsule through every state in spec §9 and exits. It exists
        // because most of that table cannot be photographed by hand — `arming` lasts
        // 150 ms, `success` flashes for 1.2 s, `modeSwitched` and `refining` are
        // unreachable until modes are wired, `error` needs the network broken on
        // purpose — so the states were never *looked at*, and one change inside them
        // has never been seen at all: the recording waveform is now monochrome rather
        // than tinted red with the dot.
        if CommandLine.arguments.contains("--hud-parade") {
            Self.launchDecision = .ranInstrument("--hud-parade")
            Task { @MainActor in
                await HUDParade.run(arguments: CommandLine.arguments)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // `Captur --probe-hotkeys` prints the push-to-talk binding the app actually loaded
        // and which of the two mechanisms it selects. It exists because "the chord was never
        // registered" and "the chord was registered but the keystroke never arrived" look
        // identical from outside: nothing happens.
        if CommandLine.arguments.contains("--probe-hotkeys") {
            Self.launchDecision = .ranInstrument("--probe-hotkeys")
            HotkeyBindingProbe.run()
            return
        }

        // `Captur --probe-hotkey-release [seconds]` registers ⌘⇧D and prints every press
        // AND release edge Carbon delivers. It exists because chord push-to-talk needs an
        // up edge that this app has never asked for, and the failure mode of guessing —
        // releasing the modifiers before the key and never getting the release — is a
        // recording left running with the microphone open.
        if CommandLine.arguments.contains("--probe-hotkey-release") {
            Self.launchDecision = .ranInstrument("--probe-hotkey-release")
            HotkeyReleaseProbe.run(arguments: CommandLine.arguments)
            return
        }

        let composition = AppComposition()
        composition.start()
        self.composition = composition
        Self.launchDecision = .ranComposition
    }

    private var terminationTask: Task<Void, Never>?
    private var diagnosticExitStatus: Int32 = EXIT_SUCCESS

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // willTerminate cannot await native cleanup. Defer the actual exit until
        // inference finishes and the shared model has released its Metal buffers.
        if terminationTask == nil {
            terminationTask = Task.detached {
                await LocalCleanupCoordinator.shared.shutdown()
                // AppKit may enter a nested termination loop while an async probe
                // still occupies the main executor. Reply through the run loop.
                RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                    MainActor.assumeIsolated {
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
        }
        return .terminateLater
    }

    /// Closes this run's health record and removes the marker whose survival is what
    /// tells the next launch the app crashed.
    ///
    /// Synchronous on purpose. An `async` hop here is not guaranteed to run before the
    /// process goes away, and a clean quit that failed to clear its own marker would be
    /// reported to the user as a crash — a health feature manufacturing the exact problem
    /// it exists to detect.
    func applicationWillTerminate(_ notification: Notification) {
        composition?.recordingVolume.restore()
        composition?.health.endSessionSynchronously()
        // Failure status is published only after asynchronous native teardown
        // and normal application termination have completed their work.
        if diagnosticExitStatus != EXIT_SUCCESS { Darwin.exit(diagnosticExitStatus) }
    }

    /// Reopening the app from Finder or its temporary Dock tile reveals the workspace.
    /// The ordinary menu-bar launch stays quiet and retains lazy window construction.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { composition?.openMainWindow(.home) }
        return true
    }

    /// Prints every prerequisite's live state, plus the code-signing identity TCC uses
    /// to remember its answers — because an unsigned or re-signed build is a *different
    /// app* to TCC, which is the usual reason a permission that was granted is denied
    /// again, or an app never appears in a Privacy list at all.
    private func runPermissionsReport(requesting: Bool) {
        Task { @MainActor in
            let keyStore = KeychainGroqKeyStore()
            let openRouterKeyStore = KeychainOpenRouterKeyStore()
            let microphone = SystemMicrophonePermission()
            let inputMonitoring = SystemInputMonitoringPermission()
            let inserter = Inserter()

            let controller = FirstRunController(
                keyStore: keyStore,
                openRouterKeyStore: openRouterKeyStore,
                microphone: microphone,
                accessibility: inserter,
                inputMonitoring: inputMonitoring)

            if requesting {
                for kind in Prerequisite.Kind.allCases
                    where kind != .groqKey && kind != .openRouterKey {
                    controller.request(kind)
                    await controller.inFlightRequest?.value
                }
                controller.refresh()
            }

            print("--- bundle ---")
            print("  path:      \(Bundle.main.bundleURL.path)")
            print("  bundle id: \(Bundle.main.bundleIdentifier ?? "(none)")")
            print("  signature: \(Self.codeSignatureSummary())")
            print("")
            // The instrument was caught lying, so it now says when it might be.
            //
            // Running this binary from a terminal makes TCC attribute an Accessibility
            // or Input-Monitoring check to the RESPONSIBLE process — the terminal —
            // which already has both. Measured: straight after installing to
            // /Applications this printed "granted" for both while the app's own
            // first-run checklist, launched normally, correctly showed them missing.
            //
            // That is the same class of mistake this tool was built to avoid (a helper
            // script answering the question about itself), one level up.
            //
            // The signal is the PARENT process, not a TTY: an app launched normally is
            // re-parented to launchd (pid 1), while anything started from a shell keeps
            // that shell as its parent. `isatty` was tried first and is wrong — piping
            // the output through `grep` makes it report a clean launch.
            if getppid() != 1 {
                print("--- ⚠︎ read this first ---")
                print("  Run from a terminal, so macOS may attribute Accessibility and")
                print("  Input Monitoring to your terminal app rather than to Captur.")
                print("  Both can read GRANTED here and be missing in the real app.")
                print("  The authoritative answer is the app's own first-run checklist,")
                print("  launched normally: open \(Bundle.main.bundleURL.path)")
                print("")
            }
            print("--- permissions ---")
            for prerequisite in controller.prerequisites {
                let name = FirstRunView.title(for: prerequisite.id).padding(toLength: 18, withPad: " ", startingAt: 0)
                let detail: String
                switch prerequisite.id {
                // The key itself is never printed — only whether there is one.
                case .groqKey: detail = keyStore.groqKey() == nil ? "no key stored" : "a key is stored"
                case .openRouterKey:
                    detail = openRouterKeyStore.openRouterKey() == nil
                        ? "no key stored"
                        : "a key is stored"
                case .microphone: detail = microphone.status().rawValue
                case .accessibility: detail = inserter.hasAccessibilityPermission() ? "granted" : "not trusted"
                case .inputMonitoring: detail = inputMonitoring.status().rawValue
                }
                print("  \(prerequisite.isSatisfied ? "OK  " : "MISS") \(name) \(detail)")
            }
            print("")
            print(controller.needsSetup
                  ? "needsSetup = true — the checklist opens at launch."
                  : "needsSetup = false — Captur is ready.")
            NSApplication.shared.terminate(nil)
        }
    }

    /// `codesign -dv` in three lines. Ad-hoc ("-") and unsigned bundles are the ones
    /// TCC struggles to keep a stable entry for.
    private static func codeSignatureSummary() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code
        else { return "unreadable" }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let info = information as? [String: Any]
        else { return "unsigned" }

        if let authorities = info["certificates"] as? [Any], !authorities.isEmpty {
            return "signed with a certificate (\(authorities.count) in chain)"
        }
        if info["identifier"] != nil {
            return "ad-hoc signed (identifier: \(info["identifier"] as? String ?? "?"))"
        }
        return "unsigned"
    }

    private func runHeadlessDiagnostics() {
        let arguments = CommandLine.arguments
        let seconds = arguments.compactMap(Double.init).first ?? 3
        let voiceProcessing = !arguments.contains("--no-aec")

        Task { @MainActor in
            let runner = DiagnosticsRunner(engine: AudioEngine())
            let devices = runner.availableDevices()

            print("--- input devices ---")
            if devices.isEmpty {
                print("  (none enumerated)")
            }
            for device in devices {
                print("  \(device.name) [\(device.transport.rawValue)]"
                      + (device.isContinuityDevice ? " (Continuity)" : "")
                      + "  uid=\(device.id)")
            }
            print("")
            print("recording \(seconds)s, echo cancellation \(voiceProcessing ? "ON" : "OFF")…")
            print("")

            var deviceUID: String?
            if let index = arguments.firstIndex(of: "--device"), index + 1 < arguments.count {
                let needle = arguments[index + 1].lowercased()
                deviceUID = devices.first { $0.name.lowercased().contains(needle) }?.id
                print("pinning to: \(devices.first { $0.id == deviceUID }?.name ?? "NOT FOUND")")
                print("")
            }

            let report = await runner.recordSample(seconds: seconds,
                                                   deviceUID: deviceUID,
                                                   voiceProcessing: voiceProcessing)
            print(report.formatted())
            if let url = runner.lastAudioURL {
                print("")
                print("audio: \(url.path)")
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
