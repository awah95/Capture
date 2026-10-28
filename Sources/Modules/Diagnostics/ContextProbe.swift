import AppKit
import ApplicationServices
import Foundation

/// Explicit diagnostic only: runs the production reader, reports counts/availability,
/// and discards every raw value. No clipboard read, microphone, provider, or History.
@MainActor
enum ContextProbe {
    static func snapshot() async -> ContextSnapshot {
        var mode = Mode.clean
        mode.contextOptions = ModeContextOptions(selectedText: true, editorText: true,
            website: true, applicationDetails: true)
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let request = ContextCaptureRequest(initialMode: mode, explicitModeID: mode.id,
            targetBundleID: bundle, appMap: [:], websiteMap: [:], defaultModeID: mode.id,
            availableModes: [mode])
        return await ContextCollector.value(of: ContextCollector.start(bundleID: bundle, request: request))
    }

    static func run(arguments: [String]) async {
        let snapshot: ContextSnapshot
        if let index = arguments.firstIndex(of: "--context-target"), index + 1 < arguments.count,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[index + 1]).first {
            let pid = app.processIdentifier
            snapshot = await Task.detached {
                ContextCollector.collect(pid: pid, options: ModeContextOptions(selectedText: true,
                    editorText: true, website: true, applicationDetails: true))
            }.value
        } else { snapshot = await self.snapshot() }
        let report: [String: Any] = [
            "accessibilityTrusted": AXIsProcessTrusted(),
            "protectedOrUnavailable": snapshot.protectedField,
            "status": snapshot.status,
            "captureMilliseconds": snapshot.captureMilliseconds,
            "selectedUTF16": snapshot.selectedText?.utf16.count ?? 0,
            "editorUTF16": snapshot.editorText?.utf16.count ?? 0,
            "websiteAvailable": snapshot.website != nil,
            "windowTitleAvailable": snapshot.windowTitle != nil,
            "inputLabelAvailable": snapshot.inputLabel != nil
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if let index = arguments.firstIndex(of: "--context-report"), index + 1 < arguments.count {
                try data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            }
        } catch { fputs("Context diagnostic report failed: \(error.localizedDescription)\n", stderr) }
    }
}
