import Foundation

/// Match process, media identifiers and metadata. Browsers do not consistently expose
/// a tab ID; indistinguishable sessions remain an inherent Now Playing limitation.
enum NowPlayingItemID: Codable, Equatable {
    case string(String)
    case number(Int64)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int64.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        }
    }
}

/// Only known playback clients receive commands. Recording apps and unknown clients
/// are intentionally excluded even if they publish something in Now Playing.
enum MediaPlaybackSafety {
    static let supportedBundles: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.google.Chrome", "com.apple.Safari",
        "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"
    ]

    static func supports(_ identity: NowPlayingIdentity) -> Bool {
        supportedBundles.contains(identity.bundleIdentifier) ||
            identity.parentApplicationBundleIdentifier.map { supportedBundles.contains($0) } == true
    }
}

struct NowPlayingIdentity: Codable, Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let uniqueIdentifier: NowPlayingItemID?
    let contentItemIdentifier: NowPlayingItemID?
    var parentApplicationBundleIdentifier: String? = nil
}

struct NowPlayingSnapshot: Decodable, Equatable {
    let identity: NowPlayingIdentity
    let playing: Bool

    init(identity: NowPlayingIdentity, playing: Bool) {
        self.identity = identity
        self.playing = playing
    }

    init(from decoder: Decoder) throws {
        identity = try NowPlayingIdentity(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playing = try container.decode(Bool.self, forKey: .playing)
        guard identity.processIdentifier > 0, !identity.bundleIdentifier.isEmpty,
              !identity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .playing, in: container,
                                                   debugDescription: "Incomplete playback identity")
        }
    }
    private enum CodingKeys: String, CodingKey { case playing }
}

enum NowPlayingRead: Equatable {
    case playback(NowPlayingSnapshot)
    case empty
    case unavailable
}

/// A revocable, one-command permit. The helper checks its file immediately before
/// dispatch; invalidation never interrupts confirmation of a command already sent.
final class MediaCommandPermit: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    private var valid: Bool

    init() {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("captur-media-" + UUID().uuidString)
        valid = FileManager.default.createFile(atPath: fileURL.path, contents: Data(),
                                              attributes: [.posixPermissions: 0o600])
    }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
        try? FileManager.default.removeItem(at: fileURL)
    }
    deinit { invalidate() }
}

@MainActor protocol NowPlayingControlling {
    func read() async -> NowPlayingRead
    /// Returns true only if the helper observed the requested state on the same media.
    func pause(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool
    func play(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool
}

extension NowPlayingControlling {
    func pause(_ snapshot: NowPlayingSnapshot) async -> Bool {
        let permit = MediaCommandPermit(); defer { permit.invalidate() }
        return await pause(snapshot, permit: permit)
    }
    func play(_ snapshot: NowPlayingSnapshot) async -> Bool {
        let permit = MediaCommandPermit(); defer { permit.invalidate() }
        return await play(snapshot, permit: permit)
    }
}

struct MediaHelperResult {
    let status: Int32
    let output: Data
}

protocol MediaHelperRunning {
    func run(command: String, identity: Data?, permit: MediaCommandPermit?) async -> MediaHelperResult?
}

/// Run bounded one-shot helpers away from the main thread. No persistent listener,
/// fake media test client, shell interpolation, or global play/pause fallback.
struct BundledMediaHelper: MediaHelperRunning {
    private let bundle: Bundle
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func run(command: String, identity: Data?, permit: MediaCommandPermit?) async -> MediaHelperResult? {
        guard let script = bundle.url(forResource: "captur-mediaremote", withExtension: "pl"),
              let frameworks = bundle.privateFrameworksURL else { return nil }
        let framework = frameworks.appendingPathComponent("CapturMediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.execute(script: script, framework: framework,
                                                            command: command, identity: identity, permit: permit))
            }
        }
    }

    private static func execute(script: URL, framework: URL, command: String,
                                identity: Data?, permit: MediaCommandPermit?) -> MediaHelperResult? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let output = try? FileHandle(forUpdating: file) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, command]
        // Pass identity as data, never interpolate titles or URLs into shell commands.
        var environment = ProcessInfo.processInfo.environment
        environment["CAPTUR_MEDIA_PERMIT"] = permit?.fileURL.path
        environment["CAPTUR_MEDIA_IDENTITY"] = identity.flatMap { String(data: $0, encoding: .utf8) }
        if let allowed = try? JSONEncoder().encode(MediaPlaybackSafety.supportedBundles.sorted()) {
            environment["CAPTUR_MEDIA_ALLOWED_BUNDLES"] = String(data: allowed, encoding: .utf8)
        }
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard permit?.isValid != false else { return nil }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + (command == "get" ? 3 : 8)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.2)
            }
            return nil
        }
        guard (try? output.seek(toOffset: 0)) != nil,
              let data = try? output.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return MediaHelperResult(status: process.terminationStatus, output: data)
    }
}

@MainActor
struct SystemNowPlayingController: NowPlayingControlling {
    private let helper: any MediaHelperRunning
    init(helper: any MediaHelperRunning = BundledMediaHelper()) { self.helper = helper }

    func read() async -> NowPlayingRead {
        guard let result = await helper.run(command: "get", identity: nil, permit: nil), result.status == 0 else {
            return .unavailable
        }
        // null/malformed/incomplete metadata provides no safe playback identity.
        guard let snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: result.output) else {
            return .empty
        }
        return .playback(snapshot)
    }

    func pause(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool {
        guard permit.isValid, snapshot.playing, MediaPlaybackSafety.supports(snapshot.identity) else { return false }
        return await command("pause", snapshot: snapshot, playing: false, permit: permit)
    }

    func play(_ snapshot: NowPlayingSnapshot, permit: MediaCommandPermit) async -> Bool {
        guard permit.isValid, !snapshot.playing, MediaPlaybackSafety.supports(snapshot.identity) else { return false }
        return await command("play", snapshot: snapshot, playing: true, permit: permit)
    }

    private func command(_ command: String, snapshot: NowPlayingSnapshot, playing: Bool, permit: MediaCommandPermit) async -> Bool {
        guard let identity = try? JSONEncoder().encode(snapshot.identity),
              let result = await helper.run(command: command, identity: identity, permit: permit), result.status == 0,
              let after = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: result.output) else { return false }
        return after.identity == snapshot.identity && after.playing == playing
    }
}
