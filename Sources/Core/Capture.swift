import Foundation

enum OBSyncState: String, Codable, Sendable {
    case queued, syncing, synced, failed
}

/// One voice capture. Persisted durably. Dictation captures keep their audio so
/// they can be retried; Thought captures are preserved as personal records.
///
/// Decoding is deliberately tolerant: every field added after v1 is decoded with
/// `decodeIfPresent` and a default, so an index written by an older build still
/// loads without losing history. The original audio and the verbatim `text` are
/// authoritative; `cleaned` and `title` are derived and never replace them.
struct Capture: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date

    var mode: CaptureMode
    var source: CaptureSource

    var audioFileName: String?
    var transferState: TransferState
    var watchTransferID: String?

    var duration: Double?
    var status: CaptureStatus

    var draft: String?
    var text: String?
    var cleaned: String?
    var title: String?
    var tags: [String]
    var isFavorite: Bool

    var errorMessage: String?
    var retryCount: Int

    var clipboardChangeCount: Int?
    var clipboardPublishedAt: Date?
    var clipboardWasFinal: Bool?

    var obSyncState: OBSyncState?
    var obThoughtID: String?

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         updatedAt: Date? = nil,
         mode: CaptureMode = .dictation,
         source: CaptureSource = .iPhoneApp,
         audioFileName: String? = nil,
         transferState: TransferState = .local,
         watchTransferID: String? = nil,
         duration: Double? = nil,
         status: CaptureStatus = .recording,
         draft: String? = nil,
         text: String? = nil,
         cleaned: String? = nil,
         title: String? = nil,
         tags: [String] = [],
         isFavorite: Bool = false,
         errorMessage: String? = nil,
         retryCount: Int = 0,
         clipboardChangeCount: Int? = nil,
         clipboardPublishedAt: Date? = nil,
         clipboardWasFinal: Bool? = nil,
         obSyncState: OBSyncState? = nil,
         obThoughtID: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.mode = mode
        self.source = source
        self.audioFileName = audioFileName
        self.transferState = transferState
        self.watchTransferID = watchTransferID
        self.duration = duration
        self.status = status
        self.draft = draft
        self.text = text
        self.cleaned = cleaned
        self.title = title
        self.tags = tags
        self.isFavorite = isFavorite
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.clipboardChangeCount = clipboardChangeCount
        self.clipboardPublishedAt = clipboardPublishedAt
        self.clipboardWasFinal = clipboardWasFinal
        self.obSyncState = obSyncState
        self.obThoughtID = obThoughtID
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, mode, source
        case audioFileName, transferState, watchTransferID
        case duration, status, draft, text, cleaned, title, tags, isFavorite
        case errorMessage, retryCount
        case clipboardChangeCount, clipboardPublishedAt, clipboardWasFinal
        case obSyncState, obThoughtID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        status = try c.decodeIfPresent(CaptureStatus.self, forKey: .status) ?? .success
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        draft = try c.decodeIfPresent(String.self, forKey: .draft)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        mode = try c.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .dictation
        source = try c.decodeIfPresent(CaptureSource.self, forKey: .source) ?? .macApp
        transferState = try c.decodeIfPresent(TransferState.self, forKey: .transferState) ?? .local
        watchTransferID = try c.decodeIfPresent(String.self, forKey: .watchTransferID)
        cleaned = try c.decodeIfPresent(String.self, forKey: .cleaned)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        clipboardChangeCount = try c.decodeIfPresent(Int.self, forKey: .clipboardChangeCount)
        clipboardPublishedAt = try c.decodeIfPresent(Date.self, forKey: .clipboardPublishedAt)
        clipboardWasFinal = try c.decodeIfPresent(Bool.self, forKey: .clipboardWasFinal)
        obSyncState = try c.decodeIfPresent(OBSyncState.self, forKey: .obSyncState)
        obThoughtID = try c.decodeIfPresent(String.self, forKey: .obThoughtID)
    }

    var displayText: String { text ?? draft ?? "" }
    var isFinal: Bool { text != nil }
    var hasAudio: Bool { audioFileName != nil }
    var isRetryable: Bool { status == .failed || status == .pending }

    var thoughtTitle: String {
        if let title, !title.isEmpty { return title }
        let body = (text ?? draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "Untitled thought" }
        let words = body.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        return words.count < body.count ? words + "…" : words
    }
}

