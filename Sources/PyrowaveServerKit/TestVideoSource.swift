import Foundation
import AVFoundation
import CoreVideo

/// Plays a video file and yields its frames as NV12 pixel buffers.
///
/// Used by the server's test mode so a real piece of footage can be streamed
/// to the client, which makes it easy to confirm that the picture arrives
/// intact rather than just that bytes are flowing.
final class TestVideoSource: NSObject, @unchecked Sendable {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let item: AVPlayerItem
    private let frameLock = NSLock()
    private var lastFrame: CVPixelBuffer?
    private var isLooping = true
    private var shouldBePlaying = false
    private var cachedDurationSeconds: Double = 0
    private var pendingSeekSeconds: Double?
    private var seekGeneration: UInt64 = 0

    init(url: URL, initialTimeSeconds: Double = 0) throws {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        self.item = item

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        // Attach the video output to the player item so frames can actually
        // be pulled via `hasNewPixelBuffer` / `copyPixelBuffer`.
        item.add(output)
        self.output = output
        self.player = AVPlayer(playerItem: item)

        super.init()

        player.actionAtItemEnd = .none
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        let assetURL = url
        Task.detached(priority: .utility) { [weak self] in
            let loaderAsset = AVURLAsset(url: assetURL)
            if let duration = try? await loaderAsset.load(.duration) {
                let secs = duration.seconds
                if secs.isFinite && secs > 0 {
                    self?.updateCachedDuration(secs)
                }
            }
        }

        if initialTimeSeconds > 0 {
            seek(to: initialTimeSeconds)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        item.remove(output)
    }

    private func updateCachedDuration(_ seconds: Double) {
        frameLock.lock()
        cachedDurationSeconds = seconds
        frameLock.unlock()
    }

    var durationSeconds: Double {
        let itemDur = item.duration.seconds
        if itemDur.isFinite && itemDur > 0 {
            return itemDur
        }
        frameLock.lock()
        let cached = cachedDurationSeconds
        frameLock.unlock()
        return cached
    }

    var currentTimeSeconds: Double {
        frameLock.lock()
        let pending = pendingSeekSeconds
        frameLock.unlock()
        if let pending {
            return pending
        }
        let secs = player.currentTime().seconds
        guard secs.isFinite && secs >= 0 else { return 0 }
        let dur = durationSeconds
        return dur > 0 ? min(secs, dur) : secs
    }

    func seek(to seconds: Double) {
        let dur = durationSeconds
        let clamped: Double
        if dur > 0 {
            clamped = min(max(0, seconds), dur)
        } else {
            clamped = max(0, seconds)
        }

        frameLock.lock()
        seekGeneration &+= 1
        let gen = seekGeneration
        pendingSeekSeconds = clamped
        frameLock.unlock()

        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.frameLock.lock()
            let isLatest = (self.seekGeneration == gen)
            if isLatest {
                self.pendingSeekSeconds = nil
                self.lastFrame = nil
            }
            let resume = self.shouldBePlaying
            self.frameLock.unlock()
            if isLatest && resume {
                self.player.play()
            }
        }
    }

    var failureDescription: String? {
        if item.status == .failed {
            return item.error?.localizedDescription ?? "AVPlayerItem failed to load"
        }
        return nil
    }

    @objc private func itemDidReachEnd() {
        guard isLooping else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.frameLock.lock()
            let resume = self.shouldBePlaying
            self.frameLock.unlock()
            if resume {
                self.player.play()
            }
        }
    }

    func play() {
        frameLock.lock()
        shouldBePlaying = true
        frameLock.unlock()
        player.play()
    }

    func pause() {
        frameLock.lock()
        shouldBePlaying = false
        frameLock.unlock()
        player.pause()
    }

    /// Returns the next decoded frame, or nil if none is available yet.
    func nextFrame() -> CVPixelBuffer? {
        frameLock.lock()
        let wantsPlay = shouldBePlaying
        let hadFrame = lastFrame != nil
        frameLock.unlock()

        if wantsPlay && player.rate == 0 && item.status != .failed {
            player.play()
        }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if itemTime.isValid && output.hasNewPixelBuffer(forItemTime: itemTime) {
            if let buffer = Self.copyPixelBuffer(from: output, at: itemTime) {
                frameLock.lock()
                lastFrame = buffer
                frameLock.unlock()
                return buffer
            }
        }

        // Before the first frame arrives (or right after a seek), also try querying
        // at the item's current time once readyToPlay so playback updates immediately.
        if !hadFrame && item.status == .readyToPlay {
            let currentTime = item.currentTime()
            if currentTime.isValid, let buffer = Self.copyPixelBuffer(from: output, at: currentTime) {
                frameLock.lock()
                lastFrame = buffer
                frameLock.unlock()
                return buffer
            }
        }

        // Nothing new yet: repeat the previous frame so the stream keeps its
        // cadence even when the file is buffering.
        frameLock.lock()
        defer { frameLock.unlock() }
        return lastFrame
    }

    /// The modern pixel buffer accessor needs macOS 26, but this package
    /// supports macOS 14, so the older entry point is used here.
    @available(macOS, deprecated: 27.0)
    private static func copyPixelBuffer(
        from output: AVPlayerItemVideoOutput,
        at itemTime: CMTime
    ) -> CVPixelBuffer? {
        output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    }
}
