import AppKit
import Carbon
import Foundation

struct MediaPlayer: Hashable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
}

struct MediaPlayback: Equatable, Sendable {
    enum State { case playing, paused, stopped }
    let state: State
    let trackID: String
}

/// Tests inject this surface so they never send events to the user's players.
@MainActor protocol MediaPlayerControlling {
    func runningPlayers() async -> [MediaPlayer]
    func playback(of player: MediaPlayer) async -> MediaPlayback?
    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) async -> Bool
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) async -> Bool
}

/// The synchronous Apple Event implementation is confined to a worker queue.
protocol MediaPlayerEventHandling: Sendable {
    func runningPlayers() -> [MediaPlayer]
    func playback(of player: MediaPlayer) -> MediaPlayback?
    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool
}

@MainActor
struct SystemMediaPlayerController: MediaPlayerControlling {
    private let backend: any MediaPlayerEventHandling
    private let queue = DispatchQueue(label: "com.awah.captur.media-apple-events")
    init(backend: any MediaPlayerEventHandling = MediaPlayerAppleEvents()) { self.backend = backend }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (any MediaPlayerEventHandling) -> T) async -> T {
        let backend = backend
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation(backend)) }
        }
    }
    func runningPlayers() async -> [MediaPlayer] { await perform { $0.runningPlayers() } }
    func playback(of player: MediaPlayer) async -> MediaPlayback? { await perform { $0.playback(of: player) } }
    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) async -> Bool {
        await perform { $0.pause(player, permit: permit) }
    }
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) async -> Bool {
        await perform { $0.play(player, permit: permit) }
    }
}

/// Address existing processes; a player quitting cannot cause an app launch.
struct MediaPlayerAppleEvents: MediaPlayerEventHandling {
    private let supportedPlayers = ["com.apple.Music", "com.spotify.client"]

    func runningPlayers() -> [MediaPlayer] {
        supportedPlayers.flatMap { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
                .map { MediaPlayer(bundleIdentifier: bundleID, processIdentifier: $0.processIdentifier) }
        }
    }

    func playback(of player: MediaPlayer) -> MediaPlayback? {
        guard let stateValue = property("pPlS", of: player)?.typeCodeValue else { return nil }
        let state: MediaPlayback.State
        switch stateValue {
        case code("kPSP"): state = .playing
        case code("kPSp"): state = .paused
        case code("kPSS"): state = .stopped
        default: return nil
        }
        // Spotify's ID is text; Music's persistent ID is stable across queue changes.
        let trackProperty = player.bundleIdentifier == "com.apple.Music" ? "pPIS" : "ID  "
        guard let track = objectProperty("pTrk", container: NSAppleEventDescriptor.null()),
              let trackID = property(trackProperty, of: player, container: track)?.stringValue,
              !trackID.isEmpty else { return nil }
        return MediaPlayback(state: state, trackID: trackID)
    }

    func pause(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool { command("Paus", to: player, permit: permit) }
    func play(_ player: MediaPlayer, permit: MediaCommandPermit) -> Bool { command("Play", to: player, permit: permit) }

    private func command(_ command: String, to player: MediaPlayer, permit: MediaCommandPermit) -> Bool {
        let suite = player.bundleIdentifier == "com.apple.Music" ? "hook" : "spfy"
        return send(eventClass: code(suite), eventID: code(command), to: player, permit: permit) != nil
    }

    private func property(_ name: String, of player: MediaPlayer,
                          container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor? {
        guard let object = objectProperty(name, container: container) else { return nil }
        return send(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
             to: player, object: object)?
            .paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    }

    private func objectProperty(_ name: String, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    private func send(eventClass: AEEventClass, eventID: AEEventID, to player: MediaPlayer,
                      object: NSAppleEventDescriptor? = nil, permit: MediaCommandPermit? = nil) -> NSAppleEventDescriptor? {
        guard let app = NSRunningApplication(processIdentifier: player.processIdentifier),
              !app.isTerminated, app.bundleIdentifier == player.bundleIdentifier else { return nil }
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: eventClass, eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: player.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: AEKeyword(keyDirectObject)) }
        guard permit?.isValid != false else { return nil }
        // Keep an unresponsive player from delaying microphone startup indefinitely.
        guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.25),
              reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0 == 0 else { return nil }
        return reply
    }

    private func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}

/// Serializes capture edges while reading system-wide Now Playing asynchronously.
/// The app-specific controller is used only when the adapter is unavailable.
@MainActor
final class MediaController {
    private let players: any MediaPlayerControlling
    private let nowPlaying: (any NowPlayingControlling)?
    private let isEnabled: () -> Bool
    private var liveCaptures = 0
    private var pausedPlayers: [MediaPlayer: String] = [:]
    private var pausedSession: NowPlayingSnapshot?
    private var wasHoldingMicrophone = false
    private var generation = 0
    private var pending: Task<Void, Never>?
    private var commandPermit: MediaCommandPermit?

    private func newPermit() -> MediaCommandPermit {
        commandPermit?.invalidate()
        let permit = MediaCommandPermit()
        commandPermit = permit
        return permit
    }

    init(players: (any MediaPlayerControlling)? = nil,
         nowPlaying: (any NowPlayingControlling)? = nil,
         isEnabled: @escaping () -> Bool) {
        self.players = players ?? SystemMediaPlayerController()
        // Explicit player injection keeps existing tests away from real media.
        self.nowPlaying = nowPlaying ?? (players == nil ? SystemNowPlayingController() : nil)
        self.isEnabled = isEnabled
    }

    func captureDidBegin() {
        liveCaptures += 1
        guard liveCaptures == 1 else { return }
        commandPermit?.invalidate()
        generation += 1
        guard isEnabled() else { return }
        let captureGeneration = generation
        enqueue {
            guard self.liveCaptures > 0, self.generation == captureGeneration,
                  self.isEnabled(), self.pausedSession == nil, self.pausedPlayers.isEmpty else { return }
            let state = await self.nowPlaying?.read() ?? .unavailable
            // A delayed read must never pause playback after recording ended.
            guard self.liveCaptures > 0, self.generation == captureGeneration, self.isEnabled() else { return }
            switch state {
            case .playback(let snapshot):
                guard snapshot.playing, MediaPlaybackSafety.supports(snapshot.identity),
                      await self.nowPlaying?.pause(snapshot, permit: self.newPermit()) == true else { return }
                self.pausedSession = NowPlayingSnapshot(identity: snapshot.identity, playing: false)
            case .unavailable:
                await self.pauseApplications(generation: captureGeneration)
            case .empty:
                break
            }
        }
    }

    func captureDidEnd() {
        guard liveCaptures > 0 else { return }
        liveCaptures -= 1
        guard liveCaptures == 0 else { return }
        commandPermit?.invalidate()
        enqueue {
            // A new capture may have started while a pause command was in flight.
            guard self.liveCaptures == 0 else { return }
            if let paused = self.pausedSession {
                let state = await self.nowPlaying?.read() ?? .unavailable
                guard self.liveCaptures == 0 else { return }
                guard case .playback(let current) = state,
                      current.identity == paused.identity, !current.playing else {
                    self.pausedSession = nil
                    return
                }
                let permit = self.newPermit()
                let played = await self.nowPlaying?.play(current, permit: permit) == true
                // Keep ownership after revocation, even if the newer capture has
                // already ended: its queued end still needs to restore this pause.
                if played || permit.isValid { self.pausedSession = nil }
            } else if !self.pausedPlayers.isEmpty {
                let state = await self.nowPlaying?.read() ?? .unavailable
                guard self.liveCaptures == 0 else { return }
                switch state {
                case .playback(let current):
                    let player = MediaPlayer(bundleIdentifier: current.identity.bundleIdentifier,
                                             processIdentifier: current.identity.processIdentifier)
                    guard !current.playing, self.pausedPlayers[player] != nil else {
                        self.pausedPlayers.removeAll()
                        return
                    }
                case .empty:
                    self.pausedPlayers.removeAll()
                    return
                case .unavailable:
                    break // Native playback state is still independently verifiable.
                }
                await self.resumeApplications()
            }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await operation()
            self.commandPermit?.invalidate()
            self.commandPermit = nil
        }
    }

    /// Deterministic drain for tests; never invokes real players when fakes are injected.
    func waitForPendingOperations() async { await pending?.value }

    private func pauseApplications(generation captureGeneration: Int) async {
        let permit = newPermit()
        for player in await players.runningPlayers() {
            guard permit.isValid, liveCaptures > 0, generation == captureGeneration, isEnabled() else { return }
            guard let playback = await players.playback(of: player), playback.state == .playing,
                  permit.isValid, liveCaptures > 0, generation == captureGeneration,
                  await players.pause(player, permit: permit),
                  let after = await players.playback(of: player), after.state == .paused,
                  after.trackID == playback.trackID else { continue }
            pausedPlayers[player] = playback.trackID
        }
    }

    private func resumeApplications() async {
        let permit = newPermit()
        let running = Set(await players.runningPlayers())
        for (player, trackID) in pausedPlayers {
            guard permit.isValid, liveCaptures == 0 else { return }
            guard running.contains(player), let playback = await players.playback(of: player),
                  playback.state == .paused, playback.trackID == trackID else {
                pausedPlayers.removeValue(forKey: player)
                continue
            }
            guard permit.isValid, liveCaptures == 0 else { return }
            let played = await players.play(player, permit: permit)
            if played || permit.isValid { pausedPlayers.removeValue(forKey: player) }
        }
    }

    func captureDidCancel() { captureDidEnd() }

    func update(holdsMicrophone: Bool) {
        guard holdsMicrophone != wasHoldingMicrophone else { return }
        wasHoldingMicrophone = holdsMicrophone
        holdsMicrophone ? captureDidBegin() : captureDidEnd()
    }
}
