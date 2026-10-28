import AppKit
import Foundation

enum ClipboardContextUpdate {
    case unchanged
    case replace(String?)
}

/// Observes generations and times only. No clipboard contents are retained while idle.
@MainActor
final class RecentClipboard {
    private static var ownGenerations: [String: [Int]] = [:]
    static func noteOwnChange(_ pasteboard: NSPasteboard) {
        let key = pasteboard.name.rawValue
        ownGenerations[key] = Array(((ownGenerations[key] ?? []) + [pasteboard.changeCount]).suffix(16))
    }

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastCount: Int
    private var changedAt: Date?
    private var wasEnabled = false
    private let enabled: () -> Bool

    init(pasteboard: NSPasteboard = .general, enabled: @escaping () -> Bool) {
        self.pasteboard = pasteboard
        self.enabled = enabled
        self.lastCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.15
    }

    func poll(now: Date = Date()) {
        guard enabled() else { wasEnabled = false; changedAt = nil; return }
        let count = pasteboard.changeCount
        guard wasEnabled else { wasEnabled = true; lastCount = count; changedAt = nil; return }
        if count != lastCount {
            lastCount = count
            changedAt = Self.ownGenerations[pasteboard.name.rawValue]?.contains(count) == true ? nil : now
        }
    }

    func text(recentOnly: Bool, since: Date? = nil, now: Date = Date()) -> String? {
        poll(now: now)
        guard enabled(), !recentOnly || Self.isRecent(changedAt, since: since, now: now) else { return nil }
        let types = pasteboard.types ?? []
        guard !types.contains(ClipboardPublisher.markerType),
              !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              let data = pasteboard.data(forType: .string), data.count <= 32_768,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ContextSnapshot.bounded(text, limit: ContextSnapshot.clipboardLimit)
    }

    /// Pin a generation at the recording edge without reading its content. A late
    /// website decision may read it only while that exact generation still exists.
    func startReader(recentOnly: Bool, now: Date = Date()) -> () -> String? {
        poll(now: now)
        let generation = pasteboard.changeCount
        let eligible = !recentOnly || Self.isRecent(changedAt, since: nil, now: now)
        return { [weak self] in
            guard let self, eligible, self.pasteboard.changeCount == generation else { return nil }
            return self.text(recentOnly: false)
        }
    }

    func endReader(since startedAt: Date, now: Date = Date()) -> () -> ClipboardContextUpdate {
        poll(now: now)
        let generation = pasteboard.changeCount
        let eligible = Self.isRecent(changedAt, since: startedAt, now: now)
        return { [weak self] in
            guard let self, eligible else { return .unchanged }
            guard self.pasteboard.changeCount == generation else { return .replace(nil) }
            return .replace(self.text(recentOnly: false))
        }
    }

    func update(since startedAt: Date, now: Date = Date()) -> ClipboardContextUpdate {
        poll(now: now)
        guard Self.isRecent(changedAt, since: startedAt, now: now) else { return .unchanged }
        // A new empty/protected/non-text copy revokes the older snapshot as well.
        return .replace(text(recentOnly: true, since: startedAt, now: now))
    }

    nonisolated static func isRecent(_ changedAt: Date?, since: Date?, now: Date) -> Bool {
        guard let changedAt, changedAt <= now else { return false }
        return changedAt >= (since ?? now.addingTimeInterval(-3))
    }

    deinit { timer?.invalidate() }
}
