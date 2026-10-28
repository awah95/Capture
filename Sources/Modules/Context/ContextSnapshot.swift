import Foundation

/// Opt-in, independently persisted per mode. Old modes decode to no new collection.
struct ModeContextOptions: Codable, Equatable, Sendable {
    var selectedText = false
    var editSelectedText = false
    var editorText = false
    var website = false
    var dateTime = false
    var applicationDetails = false
    var refreshEditorBeforeRefinement = false

    init(selectedText: Bool = false, editSelectedText: Bool = false, editorText: Bool = false, website: Bool = false, dateTime: Bool = false, applicationDetails: Bool = false, refreshEditorBeforeRefinement: Bool = false) {
        self.selectedText = selectedText
        self.editSelectedText = editSelectedText
        self.editorText = editorText
        self.website = website
        self.dateTime = dateTime
        self.applicationDetails = applicationDetails
        self.refreshEditorBeforeRefinement = refreshEditorBeforeRefinement
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedText = try values.decodeIfPresent(Bool.self, forKey: .selectedText) ?? false
        editSelectedText = try values.decodeIfPresent(Bool.self, forKey: .editSelectedText) ?? false
        editorText = try values.decodeIfPresent(Bool.self, forKey: .editorText) ?? false
        website = try values.decodeIfPresent(Bool.self, forKey: .website) ?? false
        dateTime = try values.decodeIfPresent(Bool.self, forKey: .dateTime) ?? false
        applicationDetails = try values.decodeIfPresent(Bool.self, forKey: .applicationDetails) ?? false
        refreshEditorBeforeRefinement = try values.decodeIfPresent(Bool.self, forKey: .refreshEditorBeforeRefinement) ?? false
    }
}

/// Ephemeral reference data. Deliberately not Codable: raw context never enters History.
struct ContextSnapshot: Equatable, Sendable {
    var resolvedModeID: String?
    var protectedField = false
    var targetUnavailable = false
    var selectedText: String?
    var selectionTruncated = false
    var editorText: String?
    var website: String?
    var dateTime: String?
    var clipboard: String?
    var windowTitle: String?
    var inputLabel: String?
    var status = "No editor context requested"
    var captureMilliseconds = 0

    static let empty = ContextSnapshot()
    static let selectedLimit = 1_000
    static let editorLimit = 2_000
    static let clipboardLimit = 2_000

    /// Both scalars and bytes are bounded, including pathological combining sequences.
    static func bounded(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let value = String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func filtered(for mode: Mode, enabled: Bool, registry: LocalCleanupRegistry = .builtIn) -> ContextSnapshot {
        guard enabled, mode.usesModePrompt(in: registry) else { return .empty }
        var copy = self
        if protectedField {
            copy.selectedText = nil; copy.editorText = nil; copy.website = nil
            copy.dateTime = nil; copy.clipboard = nil; copy.windowTitle = nil; copy.inputLabel = nil
            return copy
        }
        if !mode.contextOptions.selectedText { copy.selectedText = nil }
        if !mode.contextOptions.editorText { copy.editorText = nil }
        if !mode.contextOptions.website { copy.website = nil }
        if !mode.contextOptions.dateTime { copy.dateTime = nil }
        if !mode.includeClipboardContext { copy.clipboard = nil }
        if !mode.contextOptions.applicationDetails { copy.windowTitle = nil; copy.inputLabel = nil }
        return copy
    }

    var summary: String {
        let counts = [("selection", selectedText), ("editor", editorText),
                      ("clipboard", clipboard), ("website", website), ("date", dateTime),
                      ("window", windowTitle), ("input", inputLabel)]
            .compactMap { name, value in value.map { "\(name): \($0.utf16.count) UTF-16 units" } }
        return ([status, "\(captureMilliseconds) ms"] + counts).joined(separator: " · ")
    }
}

/// Domain-only routing: never persist a path, query, fragment, credentials or page title.
enum WebsiteContext {
    static func host(from address: String?) -> String? {
        guard let address, address.utf8.count <= 4_096,
              let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."),
              host.utf8.count <= 253 else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    static func normalizedRule(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.contains("/"), !value.contains(":"), !value.contains("@"),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
              !value.contains(".."), !value.hasPrefix("."), !value.hasSuffix(".") else { return nil }
        return host(from: "https://" + value)
    }
}

struct ContextCaptureRequest: Sendable {
    var initialMode: Mode
    var explicitModeID: String?
    var targetBundleID: String?
    var appMap: [String: String]
    var websiteMap: [String: String]
    var defaultModeID: String
    var availableModes: [Mode]
    var cleanupRegistry: LocalCleanupRegistry = .builtIn

    func resolve(host: String?) -> Mode {
        ModeResolver.resolve(explicitModeID: explicitModeID, frontmostBundleID: targetBundleID,
            perAppMap: appMap, defaultModeID: defaultModeID, available: availableModes,
            websiteHost: host, perWebsiteMap: websiteMap)
    }
}
