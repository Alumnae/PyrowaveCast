import CoreMedia
import CoreVideo
import Foundation
import ReplayKit
import os
#if canImport(SPPWCommon)
import SPPWCommon
#endif

/// Broadcast Upload Extension: system-wide screen casting that keeps running while
/// PyrowaveCast (or any other app) is in the background, on the Home Screen or locked.
///
/// iOS runs this extension in its own process for as long as the broadcast lasts, so the
/// whole `SPPW/1` server lives here: the same `IOSStreamServer` as the app (UDP, Bonjour,
/// FEC, pacing, Metal PyroWave encoder) fed by ReplayKit's screen and app-audio samples.
/// The user starts and stops it from Control Center or the picker in the app.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let lock = NSLock()
    private let converter = IOSNV12Converter()
    private let logger = Logger(subsystem: "com.pyrowavecast.ios.broadcast", category: "server")
    private var server: IOSStreamServer?
    private var frames: AsyncStream<IOSSendablePixelBuffer>.Continuation?
    private var isStarting = false
    private var isPaused = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        logger.log("Broadcast started; the server starts with the first screen frame")
    }

    override func broadcastPaused() {
        lock.withLock { isPaused = true }
        if let server = lock.withLock({ server }) {
            Task { await server.setVideoSuspended(true) }
        }
    }

    override func broadcastResumed() {
        lock.withLock { isPaused = false }
        if let server = lock.withLock({ server }) {
            Task { await server.setVideoSuspended(false) }
        }
    }

    override func broadcastFinished() {
        let (activeServer, continuation) = lock.withLock { () -> (IOSStreamServer?, AsyncStream<IOSSendablePixelBuffer>.Continuation?) in
            let current = (server, frames)
            server = nil
            frames = nil
            return current
        }
        continuation?.finish()
        guard let activeServer else { return }
        // Give the server a moment to close the socket and Bonjour before iOS ends the process.
        let done = DispatchSemaphore(value: 0)
        Task {
            await activeServer.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let width = CVPixelBufferGetWidth(source) & ~1
            let height = CVPixelBufferGetHeight(source) & ~1
            guard width >= 2, height >= 2 else { return }
            guard let continuation = continuationStartingServerIfNeeded(width: width, height: height) else { return }
            guard let normalized = converter.normalizeToNV12(source, targetWidth: width, targetHeight: height) else { return }
            continuation.yield(IOSSendablePixelBuffer(
                buffer: normalized,
                captureTimestampNanoseconds: SPPWCaptureClock.captureNanoseconds(of: sampleBuffer)
            ))
        case .audioApp:
            // Sound of every app on the device, stamped on the same clock as the frames.
            lock.withLock { server }?.ingestAudio(sampleBuffer)
        case .audioMic:
            break
        @unknown default:
            break
        }
    }

    /// Starts the server on the first frame, when the real capture size is known.
    private func continuationStartingServerIfNeeded(width: Int, height: Int) -> AsyncStream<IOSSendablePixelBuffer>.Continuation? {
        lock.lock()
        if let frames {
            lock.unlock()
            return frames
        }
        guard !isStarting else {
            lock.unlock()
            return nil
        }
        isStarting = true
        let paused = isPaused
        lock.unlock()

        let logger = self.logger
        let instance = IOSStreamServer(
            source: .screen,
            screenResolution: (width, height),
            previewEnabled: false,
            logHandler: { entry in
                if entry.isError {
                    logger.error("\(entry.text, privacy: .public)")
                } else {
                    logger.log("\(entry.text, privacy: .public)")
                }
            }
        )
        let (stream, continuation) = AsyncStream<IOSSendablePixelBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let port = IOSBroadcastSettings.port
        Task { [weak self] in
            do {
                try await instance.start(port: port)
                if paused { await instance.setVideoSuspended(true) }
                await instance.setScreenFrameStream(stream)
                self?.serverStarted(instance, continuation: continuation)
            } catch {
                logger.error("Broadcast server failed to start on UDP \(port): \(error.localizedDescription, privacy: .public)")
                self?.serverFailed(error, port: port)
            }
        }
        return nil
    }

    private func serverStarted(_ instance: IOSStreamServer, continuation: AsyncStream<IOSSendablePixelBuffer>.Continuation) {
        lock.withLock {
            server = instance
            frames = continuation
            isStarting = false
        }
    }

    private func serverFailed(_ error: Error, port: UInt16) {
        lock.withLock { isStarting = false }
        // Ends the broadcast with a message iOS shows to the user (port busy: the app's own
        // server is probably running on the same port).
        let failure = NSError(
            domain: "PyrowaveCastBroadcast",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: SPPWLocalization.tr("broadcast.error.start_fmt", Int(port), error.localizedDescription)]
        )
        finishBroadcastWithError(failure)
    }
}
