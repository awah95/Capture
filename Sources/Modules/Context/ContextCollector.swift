import AppKit
import ApplicationServices
import Foundation

/// One bounded AX probe, off the audio queue and main actor. Never reads full AXValue,
/// simulates Copy, crawls a document, invokes AppleScript, or requests a permission.
enum ContextCollector {
    /// AX references are immutable CF handles. The worker owns all later messaging.
    struct FocusToken: @unchecked Sendable {
        let focus: AXUIElement
        let window: AXUIElement?
    }

    static func address(_ value: CFTypeRef?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "org.mozilla.firefox"]

    static func collect(pid: pid_t, options: ModeContextOptions, request: ContextCaptureRequest? = nil, token: FocusToken? = nil) -> ContextSnapshot {
        var options = options
        let started = Date()
        var snapshot = ContextSnapshot()
        func finish(_ status: String) -> ContextSnapshot {
            snapshot.status = status
            snapshot.captureMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            return snapshot
        }
        guard AXIsProcessTrusted() else { snapshot.protectedField = true; return finish("Accessibility unavailable; context omitted") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        var lastError: AXError = .success
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            lastError = .cannotComplete
            guard !Task.isCancelled else { return nil }
            guard Date().timeIntervalSince(started) < 0.15 else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.025)
            var value: CFTypeRef?
            lastError = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            guard lastError == .success else { return nil }
            return value
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return value as! AXUIElement
        }
        // Resolve the target application's focus, never the new frontmost application's.
        guard let focus = token?.focus ?? element(attribute(app, kAXFocusedUIElementAttribute)) else {
            snapshot.protectedField = true
            return finish("Focused editor unavailable; context omitted")
        }
        let window = token?.window ?? element(attribute(app, kAXFocusedWindowAttribute))
        // Probe a bounded ancestor chain, never enumerate document children. Chrome
        // exposes AXURL on web areas; Safari also exposes AXDocument on the window.
        var ancestors = [focus]
        if options.website || options.selectedText {
            var node = focus
            for _ in 0..<32 {
                guard let parent = element(attribute(node, kAXParentAttribute)),
                      !ancestors.contains(where: { CFEqual($0, parent) }) else { break }
                ancestors.append(parent)
                node = parent
            }
        }
        var host: String?
        if options.website {
            for node in (window.map { [$0] } ?? []) + ancestors {
                for key in [kAXDocumentAttribute as String, "AXURL"] {
                    if let found = WebsiteContext.host(from: address(attribute(node, key))) {
                        host = found; break
                    }
                }
                if host != nil { break }
            }
        }
        if let request {
            let mode = request.resolve(host: host)
            snapshot.resolvedModeID = mode.id
            options = mode.usesModePrompt(in: request.cleanupRegistry) ? mode.contextOptions : ModeContextOptions()
        }
        if options.website { snapshot.website = host }
        let role = attribute(focus, kAXRoleAttribute) as? String
        let subrole = attribute(focus, kAXSubroleAttribute) as? String
        guard canReadText(role: role, subrole: subrole, subroleError: lastError) else {
            snapshot.protectedField = true
            snapshot.website = nil
            return finish("Protected or unknown field; context omitted")
        }
        if options.applicationDetails {
            if let window { snapshot.windowTitle = ContextSnapshot.bounded(attribute(window, kAXTitleAttribute) as? String, limit: 256) }
            snapshot.inputLabel = ContextSnapshot.bounded(attribute(focus, kAXTitleAttribute) as? String, limit: 128)
                ?? ContextSnapshot.bounded(attribute(focus, kAXDescriptionAttribute) as? String, limit: 128)
        }
        guard options.selectedText || options.editorText else { return finish("Target captured") }
        // Web selections use opaque text markers. Ask their length first so a large
        // selected page is never fetched wholesale. Unsupported markers fail closed.
        if options.selectedText {
            func parameter(_ node: AXUIElement, _ key: String, _ value: CFTypeRef) -> CFTypeRef? {
                guard !Task.isCancelled, Date().timeIntervalSince(started) < 0.15 else { return nil }
                var output: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(node, key as CFString, value, &output) == .success else { return nil }
                return output
            }
            for node in ancestors {
                guard let marker = attribute(node, "AXSelectedTextMarkerRange"),
                      let length = parameter(node, "AXLengthForTextMarkerRange", marker) as? NSNumber,
                      length.intValue > 0, length.intValue <= ContextSnapshot.selectedLimit,
                      let text = parameter(node, "AXStringForTextMarkerRange", marker) as? String,
                      text.utf16.count <= ContextSnapshot.selectedLimit else { continue }
                snapshot.selectedText = ContextSnapshot.bounded(text, limit: ContextSnapshot.selectedLimit)
                break
            }
        }
        // Only explicit text roles qualify. Unsupported/custom editors fail closed.
        guard [kAXTextFieldRole as String, kAXTextAreaRole as String, "AXComboBox"].contains(role!) else {
            return finish(snapshot.selectedText == nil ? "Editor does not expose bounded text" : "Recording-start web selection")
        }
        guard let rawRange = attribute(focus, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return finish(snapshot.selectedText == nil ? "Caret range unavailable" : "Recording-start web selection; caret unavailable") }
        let rangeValue = rawRange as! AXValue
        var selection = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0,
              selection.location < Int.max - max(selection.length, 2_000) else {
            return finish("Invalid caret range")
        }
        func read(_ range: CFRange) -> String? {
            guard !Task.isCancelled, range.length > 0, Date().timeIntervalSince(started) < 0.15,
                  let text = AXFocus.string(in: range, of: focus),
                  text.utf16.count <= range.length else { return nil }
            return text
        }
        if options.selectedText, selection.length > 0 {
            snapshot.selectionTruncated = selection.length > ContextSnapshot.selectedLimit
            snapshot.selectedText = ContextSnapshot.bounded(read(CFRange(
                location: selection.location, length: min(selection.length, ContextSnapshot.selectedLimit))),
                limit: ContextSnapshot.selectedLimit)
        }
        if options.editorText {
            let before = min(selection.location, 1_000)
            let prefix = read(CFRange(location: selection.location - before, length: before))
            // Read after the selection only when the app supplies a valid text length.
            var suffix: String?
            if let count = attribute(focus, kAXNumberOfCharactersAttribute) as? NSNumber {
                let end = selection.location + selection.length
                if count.intValue >= end {
                    suffix = read(CFRange(location: end, length: min(1_000, count.intValue - end)))
                }
            }
            snapshot.editorText = ContextSnapshot.bounded(
                [prefix, suffix].compactMap { $0 }.joined(separator: "\n[caret / selection]\n"),
                limit: ContextSnapshot.editorLimit)
        }
        return finish(snapshot.selectedText == nil && snapshot.editorText == nil
            ? "Editor text unavailable or empty" : "Recording-start editor snapshot")
    }

    static func canReadText(role: String?, subrole: String?, subroleError: AXError) -> Bool {
        guard role != nil, subrole != kAXSecureTextFieldSubrole as String else { return false }
        return [.success, .noValue, .attributeUnsupported].contains(subroleError)
    }

    static func value(of task: Task<ContextSnapshot, Never>) async -> ContextSnapshot {
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    @MainActor
    static func start(bundleID: String?, request: ContextCaptureRequest) -> Task<ContextSnapshot, Never> {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else {
            return Task { ContextSnapshot(protectedField: true, targetUnavailable: true, status: "Target changed; refresh unavailable") }
        }
        var options = request.initialMode.usesModePrompt(in: request.cleanupRegistry) ? request.initialMode.contextOptions : ModeContextOptions()
        options.website = browsers.contains(bundleID ?? "") &&
            (options.website || !request.websiteMap.isEmpty)
        let needsContext = options.selectedText || options.editorText || options.website || options.applicationDetails ||
            (request.initialMode.usesModePrompt(in: request.cleanupRegistry) &&
                (request.initialMode.includeAppNameContext || request.initialMode.includeClipboardContext)) || options.dateTime
        guard needsContext else { return Task { .empty } }
        guard AXIsProcessTrusted() else {
            return Task { ContextSnapshot(protectedField: true, status: "Accessibility unavailable; context omitted") }
        }
        // Pin focus at the capture edge with two short, bounded messages. All text
        // and website collection stays off the main actor. No idle AX observer.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.005)
        func pin(_ key: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, key as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return value as! AXUIElement
        }
        guard let focus = pin(kAXFocusedUIElementAttribute) else {
            return Task { ContextSnapshot(protectedField: true, status: "Focus unavailable; context omitted") }
        }
        let token = FocusToken(focus: focus, window: pin(kAXFocusedWindowAttribute))
        let pid = app.processIdentifier
        let capturedOptions = options
        // Pin the PID before leaving the hotkey edge. URL and text use the SAME
        // focused element in one probe; website lookup never causes a second probe.
        return Task.detached(priority: .userInitiated) {
            collect(pid: pid, options: capturedOptions, request: request, token: token)
        }
    }
}
