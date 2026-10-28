import AppKit
import Foundation

/// A QuickCapture transcript placed on the pasteboard, tagged so a late final can
/// recognize its own draft without mistaking unrelated clipboard text for one.
struct TranscriptMarker: Codable, Equatable, Sendable {
    var captureID: UUID
    var timestamp: Date
    var isFinal: Bool
    var expiresAt: Date
    var text: String

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

/// Owns the Dictation clipboard policy. A published transcript is one pasteboard
/// item containing both ordinary plain text and a private JSON marker.
@MainActor
final class ClipboardPublisher {
    static let markerType = NSPasteboard.PasteboardType("com.awah.quickcapture.transcript")
    static let plainTextType = NSPasteboard.PasteboardType.string

    struct Receipt: Equatable, Sendable {
        var captureID: UUID
        var changeCount: Int
    }

    private let pasteboard: NSPasteboard
    private let ttl: TimeInterval

    init(pasteboard: NSPasteboard = .general, ttl: TimeInterval = 3600) {
        self.pasteboard = pasteboard
        self.ttl = ttl
    }

    /// Writes a marked transcript and returns the pasteboard generation it owns.
    @discardableResult
    func publish(
        _ text: String,
        captureID: UUID,
        isFinal: Bool,
        now: Date = Date()
    ) -> Receipt {
        let marker = TranscriptMarker(
            captureID: captureID,
            timestamp: now,
            isFinal: isFinal,
            expiresAt: now.addingTimeInterval(ttl),
            text: text
        )
        let markerData = (try? JSONEncoder().encode(marker)) ?? Data()
        let item = NSPasteboardItem()
        item.setString(text, forType: Self.plainTextType)
        item.setData(markerData, forType: Self.markerType)

        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        RecentClipboard.noteOwnChange(pasteboard)
        return Receipt(captureID: captureID, changeCount: pasteboard.changeCount)
    }

    /// Replaces only the still-current, unexpired draft belonging to this receipt.
    @discardableResult
    func replaceDraftWithFinal(
        _ text: String,
        captureID: UUID,
        expecting receipt: Receipt,
        now: Date = Date()
    ) -> Receipt? {
        guard receipt.captureID == captureID,
              pasteboard.changeCount == receipt.changeCount,
              let marker = currentMarker(),
              marker.captureID == captureID,
              !marker.isFinal,
              !marker.isExpired(now: now) else {
            return nil
        }

        return publish(text, captureID: captureID, isFinal: true, now: now)
    }

    /// Returns the marker currently present, including an expired marker.
    func currentMarker() -> TranscriptMarker? {
        guard let data = pasteboard.data(forType: Self.markerType) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptMarker.self, from: data)
    }

    /// Returns only a current QuickCapture transcript that remains within its TTL.
    func readableTranscript(now: Date = Date()) -> TranscriptMarker? {
        guard let marker = currentMarker(), !marker.isExpired(now: now) else {
            return nil
        }
        return marker
    }
}
