import AVFoundation
import Foundation

/// The seam between History and AVFoundation.
///
/// It exists for one reason: a test must be able to exercise every playback path —
/// start, pause, resume, seek, switch rows, finish — without opening a file or
/// making a sound. A unit test that played one of the owner's dictations through
/// the speakers while nobody was at the machine would be a defect in the test
/// suite, not a feature of it.
///
/// Progress arrives through `onProgress` rather than being polled. See
/// `HistoryAudioPlayer` for why that distinction is load-bearing.
@MainActor
protocol HistoryAudioPlaying: AnyObject {
    /// `(position, duration)` in seconds, delivered on the main actor whenever the
    /// playback clock advances. `duration` is 0 until the asset reports one.
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? { get set }
    /// Playback reached the end of the file.
    var onFinish: (() -> Void)? { get set }

    /// Loads `url` and starts playing from the beginning.
    func play(_ url: URL)
    func pause()
    func resume()
    /// Tears the item down. Safe to call when nothing is loaded.
    func stop()
    func seek(to position: TimeInterval)
}

/// `AVPlayer` playback of a session file.
///
/// **Why `AVPlayer` and not `AVAudioPlayer`:** the scrubber needs a position, and
/// `AVAudioPlayer` only exposes `currentTime` as a property to be read — which
/// means a repeating `Timer`. Spec §15 budgets ~0% idle CPU and this project treats
/// a stray polling timer as a defect. `addPeriodicTimeObserver` is driven by the
/// player's own playback clock: it fires only while audio is actually moving, stops
/// dead when paused, and costs nothing when no row is expanded. The observer is
/// removed with the item, so a closed window leaves nothing running.
///
/// Session files are FLAC (`ActiveCapture.sessionURL`), which AVFoundation decodes
/// natively on macOS.
@MainActor
final class HistoryAudioPlayer: HistoryAudioPlaying {
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onFinish: (() -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    /// Roughly 20 Hz — fine enough that the scrubber does not visibly step, coarse
    /// enough to be free. Only fires while playing.
    private static let progressInterval = CMTime(value: 1, timescale: 20)

    init() {}

    deinit {
        // `stop()` is main-actor isolated and deinit is not, so unwind by hand.
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ url: URL) {
        stop()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: Self.progressInterval,
            queue: .main
        ) { [weak self] time in
            // The observer's queue is `.main`, but the closure is not statically
            // main-actor isolated, so hop explicitly.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onProgress?(time.seconds, self.currentDuration)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onFinish?()
            }
        }

        player.play()
    }

    func pause() { player?.pause() }

    func resume() { player?.play() }

    func stop() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }

    func seek(to position: TimeInterval) {
        // `.zero` tolerances: a scrubber that lands on the nearest keyframe instead
        // of where the user dropped it feels broken on speech.
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                     toleranceBefore: .zero,
                     toleranceAfter: .zero)
    }

    /// 0 while the asset is still loading, which the scrubber renders as disabled
    /// rather than as a zero-length clip.
    private var currentDuration: TimeInterval {
        guard let duration = player?.currentItem?.duration, duration.isNumeric else { return 0 }
        return duration.seconds
    }
}
