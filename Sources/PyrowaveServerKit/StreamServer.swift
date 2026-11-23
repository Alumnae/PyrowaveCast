import Foundation
import Network
#if os(macOS)
import SystemConfiguration
#endif
import CoreGraphics
import CoreVideo
import CoreMedia
import ScreenCaptureKit
import CPyrowaveMetal
import SPPWCommon

// MARK: - Capture + Encode pipeline

/// A snapshot of what the server is doing, for the user interface.
public struct StreamStatus: Sendable, Equatable {
    public var isRunning: Bool = false
    public var port: UInt16 = 0
    public var connectedClients: Int = 0
    public var framesSent: Int = 0
    public var bytesSent: Int = 0
    public var megabitsPerSecond: Double = 0
    public var width: Int = 0
    public var height: Int = 0
    public var fps: Int = 0
    public var mode: String = ""
    public var videoCurrentTimeSeconds: Double = 0
    public var videoDurationSeconds: Double = 0

    public init() {}
}

/// A log line emitted by the server.
public struct ServerLogEntry: Sendable, Identifiable, Equatable {
    public let id: Int
    public let timestamp: Date
    public let text: String
    public let isError: Bool

    public init(id: Int, timestamp: Date, text: String, isError: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isError = isError
    }
}

/// The server display as it is streamed in screen capture mode.
public enum ServerDisplay {
    /// For example `1920×1080`, or `—` when no display is available.
    public static var streamResolutionText: String {
        guard let size = ScreenCaptureEngine.primaryDisplayResolution() else { return "—" }
        return "\(size.width)×\(size.height)"
    }
}

/// Dedicated serial Metal encode + Reed-Solomon FEC worker running off the
/// Swift Concurrency cooperative thread pool and off the `StreamServer` actor.
///
/// `UpstreamMetalEncoder.encode` synchronously waits for the Metal GPU command
/// buffer (`waitUntilCompleted`). Executing it on a dedicated GCD serial queue
/// with latest-frame coalescing keeps `StreamServer` immediately responsive to
/// SPPW/1 handshakes, heartbeats, configuration updates, input events, status
/// polls, and shutdown requests even under 4K60 load.
private final class ServerEncodeWorker: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let streamID: UInt32
        let config: ClientConfiguration
        let effectiveFECPercent: Int
        let peers: [SPPWUDPPeerAddress]
        let socket: SPPWUDPServerSocket
    }

    private let queue = DispatchQueue(label: "it.screenspan.pyrowave.server.encode", qos: .userInteractive)
    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var pendingFrame: (frame: SendablePixelBuffer, generation: UInt64)?
    private var isScheduled = false
    private var frameCounter: UInt32 = 0
    /// Only accessed on `queue`.
    private var encoder: UpstreamMetalEncoder?
    private let mediaPacer: SPPWMediaPacer
    private let stats: StreamStats
    private let logHandler: @Sendable (String, Bool) -> Void
    private let previewHandler: (@Sendable (Data, Int, Int) -> Void)?

    /// The last frame sent, resent while the screen is still (`SPPWStillScreenPolicy`).
    /// Only accessed on `queue`.
    private struct SentFrame {
        let bitstream: Data
        let width: Int
        let height: Int
        let generation: UInt64
    }
    private var lastSentFrame: SentFrame?
    /// Under `lock`: when the last frame went out, and whether a resync asked for one now.
    private var lastSentNanos: UInt64 = 0
    private var refreshRequested = false
    private var refreshTimer: DispatchSourceTimer?

    init(
        mediaPacer: SPPWMediaPacer,
        stats: StreamStats,
        logHandler: @escaping @Sendable (String, Bool) -> Void,
        previewHandler: (@Sendable (Data, Int, Int) -> Void)?
    ) {
        self.mediaPacer = mediaPacer
        self.stats = stats
        self.logHandler = logHandler
        self.previewHandler = previewHandler
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.refreshIfStill()
        }
        timer.resume()
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.cancel()
    }

    /// Sends the last frame again as soon as possible (a receiver asked for a resync).
    func requestRefresh() {
        lock.lock()
        refreshRequested = true
        lock.unlock()
        queue.async { [weak self] in
            self?.refreshIfStill()
        }
    }

    /// Runs on `queue`. Resends the last frame, with a new frame ID and timestamp, when
    /// no new frame went out for `SPPWStillScreenPolicy.refreshIntervalNanoseconds`
    /// (ScreenCaptureKit sends nothing while the screen does not change) or on request.
    private func refreshIfStill() {
        let now = SPPWCaptureClock.nowNanoseconds()
        lock.lock()
        let currentSnapshot = snapshot
        let encodeQueued = pendingFrame != nil || isScheduled
        let forced = refreshRequested
        let due = SPPWStillScreenPolicy.shouldRefresh(nowNanoseconds: now, lastSentNanoseconds: lastSentNanos)
        if forced && !encodeQueued { refreshRequested = false }
        lock.unlock()

        guard !encodeQueued, forced || due,
              let currentSnapshot, !currentSnapshot.peers.isEmpty,
              let frame = lastSentFrame, frame.generation == currentSnapshot.generation else { return }
        _ = sendBitstream(
            frame.bitstream,
            width: frame.width,
            height: frame.height,
            timestampNanoseconds: now,
            snapshot: currentSnapshot
        )
    }

    func updateSnapshot(_ newSnapshot: Snapshot?) {
        lock.lock()
        snapshot = newSnapshot
        if newSnapshot == nil {
            pendingFrame = nil
        }
        lock.unlock()
    }

    func invalidate(resetFrameCounter: Bool) {
        lock.lock()
        snapshot = nil
        pendingFrame = nil
        if resetFrameCounter {
            frameCounter = 0
        }
        lock.unlock()
    }

    func resetFrameCounter() {
        lock.lock()
        frameCounter = 0
        lock.unlock()
    }

    func submit(_ frame: SendablePixelBuffer, generation: UInt64) {
        lock.lock()
        pendingFrame = (frame, generation)
        let shouldSchedule = !isScheduled
        if shouldSchedule {
            isScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pendingFrame else {
                isScheduled = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            let currentSnapshot = snapshot
            lock.unlock()

            guard let currentSnapshot,
                  currentSnapshot.generation == frame.generation,
                  !currentSnapshot.peers.isEmpty else {
                continue
            }

            encodeSingleFrame(
                frame.frame.buffer,
                captureTimestampNanoseconds: frame.frame.captureTimestampNanoseconds,
                snapshot: currentSnapshot
            )
        }
    }

    private func encodeSingleFrame(_ pixelBuffer: CVPixelBuffer, captureTimestampNanoseconds: UInt64, snapshot: Snapshot) {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else { return }

        do {
            if encoder == nil { encoder = try UpstreamMetalEncoder() }
            guard let encoder else { return }

            let config = snapshot.config
            let maximumBytes = Self.maximumBitstreamBytes(width: width, height: height, config: config)
            let payloadLimit = Self.payloadLimit(for: config)

            let result = try encoder.encode(
                pixelBuffer: pixelBuffer,
                maximumBitstreamBytes: maximumBytes,
                packetBoundary: payloadLimit
            )

            guard !result.bitstream.isEmpty else { return }
            // Capture instant, the clock audio packets are stamped with too (A/V sync).
            let frameTimestamp = captureTimestampNanoseconds != 0
                ? captureTimestampNanoseconds
                : SPPWCaptureClock.nowNanoseconds()
            guard sendBitstream(
                result.bitstream,
                width: width,
                height: height,
                timestampNanoseconds: frameTimestamp,
                snapshot: snapshot
            ) else { return }
            lastSentFrame = SentFrame(
                bitstream: result.bitstream,
                width: width,
                height: height,
                generation: snapshot.generation
            )
            previewHandler?(result.bitstream, width, height)
        } catch {
            logHandler("Encode error: \(error)", true)
        }
    }

    private static func payloadLimit(for config: ClientConfiguration) -> Int {
        let requestedMTU = config.mtu > 0 ? config.mtu : 1200
        let datagramLimit = min(requestedMTU, 1200)
        return max(256, datagramLimit - WireHeader.byteCount)
    }

    /// Runs on `queue`. Fragments and paces one encoded frame to every peer of the current
    /// snapshot; returns false when the snapshot changed (superseded generation, no peers).
    private func sendBitstream(
        _ bitstream: Data,
        width: Int,
        height: Int,
        timestampNanoseconds: UInt64,
        snapshot: Snapshot
    ) -> Bool {
        // Re-check the snapshot after the Metal encode so superseded generations are dropped.
        lock.lock()
        guard let latestSnapshot = self.snapshot,
              latestSnapshot.generation == snapshot.generation,
              !latestSnapshot.peers.isEmpty else {
            lock.unlock()
            return false
        }
        frameCounter &+= 1
        let frameID = frameCounter
        lastSentNanos = SPPWCaptureClock.nowNanoseconds()
        lock.unlock()

        let payloadLimit = Self.payloadLimit(for: latestSnapshot.config)
        let fragmentTotal = (bitstream.count + payloadLimit - 1) / payloadLimit
        guard fragmentTotal <= Int(UInt16.max) else {
            logHandler("Frame too large to fragment: \(bitstream.count) bytes", true)
            return false
        }

        let datagrams = buildPacedFrameDatagrams(
            streamID: latestSnapshot.streamID,
            frameID: frameID,
            width: UInt16(width),
            height: UInt16(height),
            timestampNanoseconds: timestampNanoseconds,
            bitstream: bitstream,
            payloadLimit: payloadLimit,
            fecPercent: latestSnapshot.effectiveFECPercent
        )

        let peers = latestSnapshot.peers
        let socket = latestSnapshot.socket
        mediaPacer.enqueueFrame(
            datagrams: datagrams,
            burstSize: 6,
            fps: latestSnapshot.config.fps
        ) { burst in
            socket.sendBatch(burst, to: peers)
        }

        stats.record(frameBytes: bitstream.count)
        return true
    }

    static func maximumBitstreamBytes(
        width: Int,
        height: Int,
        config: ClientConfiguration
    ) -> Int {
        let fps = max(config.fps, 1)
        let quality = min(max(config.quality, 0.01), 1.0)

        let bytes: Double
        if config.automaticBitrate {
            let autoBytes = Double(width * height) * 1.4 * quality / 8.0
            if config.maxBitrate > 0 {
                let capBytes = (Double(config.maxBitrate) / 8.0) / Double(fps)
                bytes = min(autoBytes, capBytes)
            } else {
                bytes = autoBytes
            }
        } else {
            let perFrame = (Double(config.maxBitrate) / 8.0) / Double(fps)
            bytes = perFrame * quality
        }

        return max(Int(bytes), 4096)
    }
}

public actor StreamServer {
    private var udpSocket: SPPWUDPServerSocket?
    private var bonjourAdvertiser: SPPWBonjourAdvertiser?
    private let mediaPacer = SPPWMediaPacer(label: "it.screenspan.pyrowave.server.pacer")
    private nonisolated let audioPacketizer = SPPWAudioPacketizer()
    /// Audio packets in capture order; `audioSendTask` is their only consumer.
    private nonisolated let audioSendQueue = SPPWOrderedPacketQueue<[SPPWAudioPacketizer.PacketTuple]>()
    private var audioSendTask: Task<Void, Never>?
    /// Held while the server runs: no App Nap / idle sleep; in screen capture mode also no
    /// display sleep (a sleeping or locked display stops ScreenCaptureKit).
    private nonisolated let streamingActivity = SPPWStreamingActivity(reason: "PyrowaveCast server streaming")
    /// Automatic restart of a capture source that stopped on its own while clients remain.
    private var sourceRestartTask: Task<Void, Never>?
    private var sourceRestartAttempts = 0
    private var sourceStartedAtNanos: UInt64 = 0
    private var lastStallRestartNanos: UInt64 = 0
    private var encodeWorker: ServerEncodeWorker?
    private var clients: [UInt32: ClientSession] = [:]
    private var nextStreamID: UInt32 = 1
    private var sessionReaperTask: Task<Void, Never>?
    private let clientSessionTimeoutNanos: UInt64 = 30_000_000_000
    private var captureEngine: ScreenCaptureEngine?
    /// `showsCursor` currently applied to the capture (`applyCursorVisibility`).
    private var captureShowsCursor = true
    private var testSource: TestContentSource?
    /// The task that pumps frames out of the shared source.
    private var sourceTask: Task<Void, Never>?
    /// The geometry the running source produces.
    private var sourceGeometry: (width: Int, height: Int)?
    private var isScreenCaptureMode: Bool { testContentMode == nil }
    private var agreedTimeoutSeconds: UInt16 { UInt16(clamping: clientSessionTimeoutNanos / 1_000_000_000) }
    /// One shared configuration and frame sequence feed the video stream.
    private var sharedStreamID: UInt32 = 0
    private var sharedGeneration: UInt64 = 0
    /// Generation currently awaiting `start()` on a capture engine or test
    /// source. Prevents actor reentrancy (e.g. clientHello followed immediately
    /// by a READY ping) from launching duplicate `SCStream` instances.
    private var startingGeneration: UInt64?
    private var sharedConfig: ClientConfiguration?
    private let testContentMode: TestContentMode?
    /// Capture the screen as full resolution chroma (ScreenCaptureKit 'xf44',
    /// 10-bit 4:4:4) and encode PyroWave 4:4:4. Test content stays 4:2:0.
    private let fullChroma444: Bool
    /// What the screen capture mode streams as audio.
    private let audioSource: SPPWAudioSourceOption.Kind
    private var pendingVideoSeekSeconds: Double?
    private let stats = StreamStats()
    private var runningPort: UInt16 = 0
    #if os(macOS)
    private final class RemoteInputState: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool
        private var displayID: CGDirectDisplayID = CGMainDisplayID()
        private var loggedMissingAccessibility = false

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func setEnabled(_ value: Bool) -> (wasEnabled: Bool, displayID: CGDirectDisplayID) {
            lock.lock()
            defer { lock.unlock() }
            let previous = enabled
            enabled = value
            if value {
                loggedMissingAccessibility = false
            }
            return (previous, displayID)
        }

        func snapshot() -> (enabled: Bool, displayID: CGDirectDisplayID) {
            lock.lock()
            defer { lock.unlock() }
            return (enabled, displayID)
        }

        func setDisplayID(_ id: CGDirectDisplayID) {
            lock.lock()
            displayID = id
            lock.unlock()
        }

        private var sequenceFilters: [UInt32: SPPWInputSequenceFilter] = [:]

        /// Drops the redundant copy of a `.sequenced` event from client `streamID`.
        func filter(_ event: SPPWInputEvent, streamID: UInt32) -> SPPWInputEvent? {
            lock.lock()
            defer { lock.unlock() }
            var filter = sequenceFilters[streamID] ?? SPPWInputSequenceFilter()
            let result = filter.filter(event)
            sequenceFilters[streamID] = filter
            return result
        }

        func forget(streamID: UInt32?) {
            lock.lock()
            if let streamID {
                sequenceFilters.removeValue(forKey: streamID)
            } else {
                sequenceFilters.removeAll()
            }
            lock.unlock()
        }

        func shouldLogMissingAccessibilityWarning() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !loggedMissingAccessibility else { return false }
            loggedMissingAccessibility = true
            return true
        }
    }

    private nonisolated let remoteInputState: RemoteInputState
    private nonisolated let inputController = SPPWMacInputController()
    /// Clients that asked (`.cursorVisibility(hidden: true)`) to keep the host cursor out of the
    /// video because they draw a local pointer. Honoured only while remote input is enabled.
    private var cursorHiddenClients: Set<UInt32> = []
    private nonisolated let clipboardSync = RemoteClipboardSync()
    #endif

    /// Receives every log line the server produces.
    private let logHandler: (@Sendable (ServerLogEntry) -> Void)?
    /// Receives the encoded frames so the user interface can show a preview of
    /// exactly what a client receives.
    private let previewHandler: (@Sendable (Data, Int, Int) -> Void)?

    /// `testContentMode` is nil for the normal screen capture mode. When it is
    /// set the server streams generated content instead and never touches
    /// ScreenCaptureKit, so no screen recording permission is involved.
    public init(
        testContentMode: TestContentMode? = nil,
        fullChroma444: Bool = false,
        audioSource: SPPWAudioSourceOption.Kind = .system,
        audioInputGain: Float = 1,
        remoteInputEnabled: Bool = false,
        logHandler: (@Sendable (ServerLogEntry) -> Void)? = nil,
        previewHandler: (@Sendable (Data, Int, Int) -> Void)? = nil
    ) {
        self.testContentMode = testContentMode
        self.fullChroma444 = fullChroma444
        self.audioSource = audioSource
        audioPacketizer.gain = audioInputGain
        #if os(macOS)
        self.remoteInputState = RemoteInputState(enabled: remoteInputEnabled)
        self.clipboardSync.setEnabled(remoteInputEnabled)
        #endif
        self.logHandler = logHandler
        self.previewHandler = previewHandler
    }

    private var logCounter = 0

    /// Emits a log line to the user interface and to the console.
    private func log(_ text: String, isError: Bool = false) {
        if isError {
            fputs(text + "\n", stderr)
        } else {
            print(text)
        }
        logCounter += 1
        let entry = ServerLogEntry(
            id: logCounter,
            timestamp: Date(),
            text: text,
            isError: isError
        )
        logHandler?(entry)
    }

    /// Input volume applied to the streamed audio (0 = silence, 1 = unchanged, 2 = +6 dB).
    /// Takes effect immediately, also while streaming.
    public nonisolated func setAudioInputGain(_ gain: Float) {
        audioPacketizer.gain = gain
    }

    /// Enables or disables remote mouse/keyboard input injection (screen capture mode only).
    /// Takes effect immediately while streaming; disabling releases any currently held keys/buttons.
    public nonisolated func setRemoteInputEnabled(_ enabled: Bool) {
        #if os(macOS)
        let (wasEnabled, displayID) = remoteInputState.setEnabled(enabled)
        if wasEnabled && !enabled {
            inputController.releaseAll(displayID: displayID)
        }
        clipboardSync.setEnabled(enabled)
        Task { await self.applyCursorVisibility() }
        #endif
    }

    #if os(macOS)
    /// Whether the captured video should include the host cursor right now.
    private var desiredCaptureShowsCursor: Bool {
        !(remoteInputState.snapshot().enabled && !cursorHiddenClients.isEmpty)
    }

    private func setCursorHidden(_ hidden: Bool, streamID: UInt32) {
        if hidden {
            cursorHiddenClients.insert(streamID)
        } else {
            cursorHiddenClients.remove(streamID)
        }
        applyCursorVisibility()
    }

    /// Updates the running capture's `showsCursor` when the desired value changed.
    private func applyCursorVisibility() {
        let shows = desiredCaptureShowsCursor
        guard shows != captureShowsCursor else { return }
        captureShowsCursor = shows
        log(shows ? "Cursore del Mac di nuovo visibile nel video" : "Cursore del Mac nascosto nel video (il client mostra il proprio puntatore)")
        guard let engine = captureEngine else { return }
        Task { await engine.setShowsCursor(shows) }
    }
    #endif

    /// Forgets per-client remote control state (input sequence filter, clipboard channel).
    /// `nil` forgets every client.
    private func forgetRemoteClient(_ streamID: UInt32?) {
        #if os(macOS)
        remoteInputState.forget(streamID: streamID)
        clipboardSync.remove(streamID: streamID)
        if let streamID {
            cursorHiddenClients.remove(streamID)
        } else {
            cursorHiddenClients.removeAll()
        }
        applyCursorVisibility()
        #endif
    }

    /// The current state of the server.
    public func status() -> StreamStatus {
        var status = StreamStatus()
        status.isRunning = udpSocket != nil
        status.port = runningPort
        status.connectedClients = clients.count
        status.framesSent = stats.frameCount
        status.bytesSent = stats.byteCount
        status.megabitsPerSecond = stats.megabitsPerSecond
        if let geometry = sourceGeometry {
            status.width = geometry.width
            status.height = geometry.height
        }
        if let client = clients.values.first {
            status.fps = client.config.fps
        }
        switch testContentMode {
        case .none:
            status.mode = "Screen capture"
        case .some(.card):
            status.mode = "Test card"
        case .some(.image):
            status.mode = "Image"
        case .some(.video):
            status.mode = "Video"
        }
        if let testSource {
            let pos = testSource.videoPlaybackPosition()
            status.videoCurrentTimeSeconds = pos.current
            status.videoDurationSeconds = pos.duration
        } else if let pendingSeek = pendingVideoSeekSeconds {
            status.videoCurrentTimeSeconds = pendingSeek
        }
        return status
    }

    /// Stores where the active video file has got to, so a source restart
    /// (resolution change, renegotiation, reconnect) resumes from that point
    /// instead of rewinding to the start or to the last slider position.
    private func rememberVideoPlaybackPosition() {
        guard let testSource else { return }
        let position = testSource.videoPlaybackPosition()
        guard position.duration > 0 || position.current > 0 else { return }
        pendingVideoSeekSeconds = position.current
    }

    /// Seeks the active video file source (or remembers the requested starting
    /// position if no client has triggered playback yet).
    public func seekVideo(to seconds: Double) {
        let clamped = max(0, seconds)
        pendingVideoSeekSeconds = clamped
        testSource?.seek(to: clamped)
    }

    private nonisolated static func localComputerDisplayName(fallback: String) -> String {
        #if os(macOS)
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        #endif
        let host = ProcessInfo.processInfo.hostName
        if host.hasSuffix(".local") {
            return String(host.dropLast(6))
        }
        return host.isEmpty ? fallback : host
    }

    private func syncEncodeWorkerSnapshot() {
        guard let worker = encodeWorker else { return }
        guard let socket = udpSocket,
              let config = sharedConfig,
              sharedStreamID != 0,
              !clients.isEmpty else {
            worker.updateSnapshot(nil)
            return
        }
        let peers = Array(clients.values.map(\.peer))
        let effectiveFECPercent = clients.values.map(\.config.fecPercent).max() ?? config.fecPercent
        worker.updateSnapshot(ServerEncodeWorker.Snapshot(
            generation: sharedGeneration,
            streamID: sharedStreamID,
            config: config,
            effectiveFECPercent: effectiveFECPercent,
            peers: peers,
            socket: socket
        ))
    }

    public func start(port: UInt16) async throws {
        guard port > 0, port < UInt16.max else {
            throw NSError(domain: "PyrowaveServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "UDP port must be between 1 and 65534"])
        }
        guard udpSocket == nil else {
            throw NSError(domain: "PyrowaveServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server is already running"])
        }

        streamingActivity.begin(keepDisplayAwake: isScreenCaptureMode)
        let audioPackets = audioSendQueue.makeStream()
        audioSendTask?.cancel()
        audioSendTask = Task { [weak self] in
            for await packets in audioPackets {
                guard let self else { return }
                await self.broadcastAudioPackets(packets)
            }
        }
        let socket = try SPPWUDPServerSocket(
            port: port,
            sendBufferBytes: SPPWSocketBufferTuning.defaultSendBufferBytes,
            receiveBufferBytes: SPPWSocketBufferTuning.defaultReceiveBufferBytes
        )
        let ipv4 = preferredLocalIPv4Address()
        let serviceName = SPPWNetworkInterface.localBonjourServiceName()
        let hostName = ipv4 ?? SPPWNetworkInterface.sanitizedMDNSHostname(serviceName: serviceName)
        var txtRecords: [String: String] = [
            "port": String(port),
            "host": hostName,
            "proto": "SPPW/1",
        ]
        if let ipv4, !ipv4.isEmpty {
            txtRecords["ip"] = ipv4
        }
        let advertiser = SPPWBonjourAdvertiser()
        advertiser.start(
            serviceName: serviceName,
            serviceType: "_pyrowavecast._udp",
            port: port,
            txtRecords: txtRecords
        )

        self.encodeWorker = ServerEncodeWorker(
            mediaPacer: mediaPacer,
            stats: stats,
            logHandler: { [weak self] message, isError in
                Task { await self?.log(message, isError: isError) }
            },
            previewHandler: previewHandler
        )
        self.udpSocket = socket
        self.bonjourAdvertiser = advertiser
        runningPort = port

        socket.start { [weak self] data, peer in
            guard let self else { return }
            Task { await self.processDatagram(data, from: peer) }
        }
        log("SPPW/1 server listening on UDP port \(port) (host=\(hostName), SO_SNDBUF=\(socket.tuning.actualSendBytes / 1024)KB, SO_RCVBUF=\(socket.tuning.actualReceiveBytes / 1024)KB, DSCP=CS4)")
    }

    private func ensureSessionReaperRunning() {
        guard sessionReaperTask == nil, !clients.isEmpty else { return }
        sessionReaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                await self.expireStaleClientSessions()
                if await self.hasNoActiveClients() {
                    await self.stopSessionReaper()
                    return
                }
            }
        }
    }

    private func hasNoActiveClients() -> Bool {
        clients.isEmpty
    }

    private func stopSessionReaper() {
        sessionReaperTask?.cancel()
        sessionReaperTask = nil
    }

    /// Stops the listener and the frame source.
    public func stop() async {
        #if os(macOS)
        inputController.releaseAll(displayID: remoteInputState.snapshot().displayID)
        #endif
        streamingActivity.end()
        sourceRestartTask?.cancel()
        sourceRestartTask = nil
        sourceRestartAttempts = 0
        audioSendTask?.cancel()
        audioSendTask = nil
        audioSendQueue.finish()
        sessionReaperTask?.cancel()
        sessionReaperTask = nil
        mediaPacer.cancelPending()
        sharedGeneration &+= 1
        startingGeneration = nil
        encodeWorker?.invalidate(resetFrameCounter: true)
        encodeWorker = nil
        sourceTask?.cancel()
        sourceTask = nil
        clients.removeAll()
        forgetRemoteClient(nil)
        bonjourAdvertiser?.stop()
        bonjourAdvertiser = nil
        udpSocket?.stop()
        udpSocket = nil
        await captureEngine?.stop()
        captureEngine = nil
        rememberVideoPlaybackPosition()
        await testSource?.stop()
        testSource = nil
        sourceGeometry = nil
        sharedConfig = nil
        sharedStreamID = 0
        runningPort = 0
        log("Server stopped")
    }

    private func processDatagram(_ data: Data, from peer: SPPWUDPPeerAddress) async {
        guard let header = parseWireHeader(data) else { return }

        let payload = data.count > WireHeader.byteCount
            ? data.subdata(in: WireHeader.byteCount..<data.count)
            : Data()
        let peerAddress = peer.hostKey

        if header.kind == .clientHello {
            let requested = parseClientConfig(payload)?.sanitised() ?? ClientConfiguration()
            let config = applyingServerResolution(to: requested)
            if config.width != requested.width || config.height != requested.height {
                log("Cattura schermo: risoluzione del server \(config.width)x\(config.height) (richiesta client \(requested.width)x\(requested.height))")
            }

            // A hello from the same LAN host replaces its old control session.
            // If a compatible shared stream is already running or starting (e.g.
            // clientHello retry while ScreenCaptureKit is warming up), keep it
            // alive instead of tearing down and restarting capture in a loop.
            let replacedIDs = clients.values
                .filter { $0.peerAddress == peerAddress }
                .map(\.streamID)
            for id in replacedIDs {
                clients.removeValue(forKey: id)
                forgetRemoteClient(id)
            }
            if !replacedIDs.isEmpty {
                #if os(macOS)
                inputController.releaseAll(displayID: remoteInputState.snapshot().displayID)
                #endif
                log("Replacing stale client session(s) \(replacedIDs) for \(peerAddress)")
                let compatibleRunningStream = (sourceTask != nil || startingGeneration != nil)
                    && sharedConfig != nil
                    && sharedConfig!.width == config.width
                    && sharedConfig!.height == config.height
                    && sharedConfig!.fps == config.fps
                if clients.isEmpty && !compatibleRunningStream {
                    await discardSharedStream(reason: "last client reconnected with new configuration")
                }
            }

            let streamID = allocateStreamID()
            clients[streamID] = ClientSession(
                streamID: streamID,
                peer: peer,
                peerAddress: peerAddress,
                config: config
            )
            ensureSessionReaperRunning()
            if sharedConfig == nil {
                sharedConfig = config
                sharedStreamID = streamID
                encodeWorker?.resetFrameCounter()
            } else if clients.count == 1 {
                // Keep live stream running while adopting updated quality/bitrate/FEC settings.
                sharedConfig = config
            }

            syncEncodeWorkerSnapshot()

            let effectiveConfig = sharedConfig ?? config
            log("Client connected from \(peer.displayAddress): controlID=\(streamID), shared stream=\(sharedStreamID), config: \(effectiveConfig.width)x\(effectiveConfig.height) @ \(effectiveConfig.fps)fps, quality=\(effectiveConfig.quality), fec=\(effectiveConfig.fecPercent)%, timeout=\(agreedTimeoutSeconds)s")
            sendServerHello(to: peer, controlStreamID: streamID, config: effectiveConfig)
            // Streaming starts right after the hello; no READY ping is needed.
            await startStreaming(streamID: streamID)
            return
        }

        // Ignore packets from endpoints that do not own this live session.
        // The timeout is refreshed by heartbeats, configuration, and input.
        guard var client = clients[header.streamID], client.peerAddress == peerAddress else { return }
        let peerChanged = client.peer != peer
        client.lastSeen = DispatchTime.now().uptimeNanoseconds
        client.peer = peer
        clients[header.streamID] = client
        if peerChanged {
            syncEncodeWorkerSnapshot()
        }

        switch header.kind {
        case .streamConfiguration:
            guard payload.count >= 22, let parsedConfig = parseClientConfig(payload) else { return }
            let updatedConfig = applyingServerResolution(to: parsedConfig.sanitised())
            let geometryOrRateChanged = client.config.width != updatedConfig.width
                || client.config.height != updatedConfig.height
                || client.config.fps != updatedConfig.fps
            client.config = updatedConfig

            let isResync = header.flags & 1 != 0
            var responseStreamID = header.streamID
            if isResync {
                clients.removeValue(forKey: header.streamID)
                forgetRemoteClient(header.streamID)
                responseStreamID = allocateStreamID()
                client = ClientSession(
                    streamID: responseStreamID,
                    peer: peer,
                    peerAddress: peerAddress,
                    config: updatedConfig
                )
                clients[responseStreamID] = client

                if clients.count == 1 {
                    sharedStreamID = responseStreamID
                    encodeWorker?.resetFrameCounter()
                }
                log("Client stream lost; created fresh session \(responseStreamID) for \(peerAddress)")
            } else {
                clients[responseStreamID] = client
            }

            sharedConfig = updatedConfig
            syncEncodeWorkerSnapshot()
            log("Shared config update: controlID=\(responseStreamID), \(updatedConfig.width)x\(updatedConfig.height) @ \(updatedConfig.fps)fps, quality=\(updatedConfig.quality), fec=\(updatedConfig.fecPercent)%")

            let sourceRunning = sourceTask != nil || startingGeneration != nil
            var resendAfterHello = false
            if geometryOrRateChanged {
                await restartSharedSource(streamID: responseStreamID)
            } else if isResync {
                let silence = captureEngine?.activity.silenceNanoseconds()
                if SPPWStillScreenPolicy.resyncNeedsSourceRestart(
                    geometryOrRateChanged: false,
                    sourceRunning: sourceRunning,
                    captureSilenceNanoseconds: silence
                ) {
                    await restartSharedSource(streamID: responseStreamID)
                } else {
                    // The capture is alive (or the screen is just still): restarting it is slow
                    // at high resolutions and blanks every receiver, so the last frame is
                    // resent right after the new hello below.
                    resendAfterHello = true
                    log("Resync for controlID=\(responseStreamID): capture running, resending the latest frame")
                }
            }

            if isResync {
                sendServerHello(to: peer, controlStreamID: responseStreamID, config: updatedConfig)
                if resendAfterHello {
                    // PyroWave frames are intra-only: the last one is a full picture.
                    encodeWorker?.requestRefresh()
                }
            } else {
                let flags: UInt16 = isScreenCaptureMode ? WireControlFlags.serverControlledResolution : 0
                let ack = makeWireDatagram(
                    kind: .streamConfiguration,
                    streamID: responseStreamID,
                    flags: flags,
                    width: UInt16(clamping: updatedConfig.width),
                    height: UInt16(clamping: updatedConfig.height)
                )
                udpSocket?.send(ack, to: peer)
            }

        case .ping:
            if payload == Data("READY".utf8) {
                await startStreaming(streamID: client.streamID)
            }
            let pong = makeWireDatagram(kind: .pong, streamID: client.streamID)
            udpSocket?.send(pong, to: peer)

        case .input:
            handleClientInputPayload(payload, streamID: client.streamID)

        case .clipboard:
            handleClientClipboardPayload(payload, client: client)

        case .clientHello, .pong, .serverHello, .frameFragment, .fecParity, .audioFrame:
            break
        }
    }

    /// Clipboard sync (`kind = 10`): only in screen capture mode with remote control enabled.
    private func handleClientClipboardPayload(_ payload: Data, client: ClientSession) {
        #if os(macOS)
        guard isScreenCaptureMode, let socket = udpSocket else { return }
        let streamID = client.streamID
        let peer = client.peer
        let result = clipboardSync.receive(
            payload,
            streamID: streamID,
            mtu: client.config.mtu
        ) { clipboardPayload in
            socket.send(
                makeWireDatagram(kind: .clipboard, streamID: streamID, payload: clipboardPayload),
                to: peer
            )
        }
        switch result {
        case let .subscription(enabled):
            log("Appunti condivisi \(enabled ? "attivi" : "disattivati") per il client \(streamID)")
        case let .content(content):
            log("Appunti ricevuti dal client \(streamID): \(content.format == .png ? "immagine" : "testo"), \(content.data.count) B")
        case .none:
            break
        }
        #endif
    }

    private func handleClientInputPayload(_ payload: Data, streamID: UInt32) {
        #if os(macOS)
        guard isScreenCaptureMode else { return }
        let state = remoteInputState.snapshot()
        guard state.enabled else { return }
        let decoded = SPPWInputEvent.decode(from: payload)
        if let decoded, case let .cursorVisibility(hidden) = decoded.unwrapped {
            // A capture setting, not an injected event: no Accessibility permission needed.
            if remoteInputState.filter(decoded, streamID: streamID) != nil {
                setCursorHidden(hidden, streamID: streamID)
            }
            return
        }
        guard SPPWMacInputInjector.isAccessibilityTrusted else {
            if remoteInputState.shouldLogMissingAccessibilityWarning() {
                log(SPPWLocalization.tr("server.log.accessibility_missing_warning"), isError: true)
            }
            return
        }
        if let event = decoded {
            if let accepted = remoteInputState.filter(event, streamID: streamID) {
                inputController.inject(accepted, displayID: state.displayID)
                if accepted.normallyChangesScreen {
                    noteScreenChangingInput()
                }
            }
            return
        }
        // Backwards compatibility with legacy 2 + N*16 touch format (`count: UInt16`, `(id, phase, x, y)`).
        if payload.count >= 18 {
            let count = Int(UInt16(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self) }))
            if count > 0, payload.count >= 2 + count * 16 {
                let phase = payload[2 + 4]
                let xBits = UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: UInt32.self) })
                let yBits = UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt32.self) })
                let x = Float(bitPattern: xBits)
                let y = Float(bitPattern: yBits)
                inputController.inject(
                    .touch([SPPWTouchPoint(id: 0, phase: phase, normalizedX: x, normalizedY: y)]),
                    displayID: state.displayID
                )
            }
        }
        #endif
    }

    /// Records a click/key/scroll and restarts a capture that has delivered nothing for a
    /// long time while the user keeps interacting (ScreenCaptureKit can stall silently;
    /// the still-screen refresh would otherwise keep resending the old picture forever).
    private func noteScreenChangingInput() {
        let now = SPPWCaptureClock.nowNanoseconds()
        guard isScreenCaptureMode, sourceTask != nil, startingGeneration == nil,
              let engine = captureEngine else { return }
        let silence = engine.activity.silenceNanoseconds(now: now)
        guard SPPWStillScreenPolicy.isStalledWhileInteracting(
            captureSilenceNanoseconds: silence,
            sinceLastInteractionNanoseconds: 0,
            sinceLastStallRestartNanoseconds: lastStallRestartNanos > 0 ? now &- lastStallRestartNanos : nil
        ) else { return }
        lastStallRestartNanos = now
        let streamID = sharedStreamID != 0 ? sharedStreamID : (clients.keys.first ?? 0)
        guard streamID != 0 else { return }
        log("Cattura schermo ferma da \(silence / 1_000_000_000) s mentre il client interagisce: riavvio della cattura", isError: true)
        Task { [weak self] in
            await self?.restartSharedSource(streamID: streamID)
        }
    }

    private func allocateStreamID() -> UInt32 {
        while true {
            let candidate = nextStreamID
            nextStreamID &+= 1
            if nextStreamID == 0 { nextStreamID = 1 }
            if candidate != 0, clients[candidate] == nil { return candidate }
        }
    }

    private func sendServerHello(
        to peer: SPPWUDPPeerAddress,
        controlStreamID: UInt32,
        config: ClientConfiguration
    ) {
        var details = Data()
        details.appendBE(sharedStreamID)
        details.appendBE(agreedTimeoutSeconds)
        details.appendBE(UInt16(clamping: config.fps))
        let flags: UInt16 = isScreenCaptureMode ? WireControlFlags.serverControlledResolution : 0
        let hello = makeWireDatagram(
            kind: .serverHello,
            streamID: controlStreamID,
            flags: flags,
            width: UInt16(clamping: config.width),
            height: UInt16(clamping: config.height),
            payload: details
        )
        udpSocket?.send(hello, to: peer)
    }

    /// In screen capture mode the server's own display decides the stream size,
    /// so the size requested by the client is replaced before it is stored.
    /// Resolves the client's requested size (`SPPWResolutionLadder` semantics: `0×0` native,
    /// `0×S` short side `S`, `W×H` fit inside) against the display in screen capture mode —
    /// ScreenCaptureKit scales the capture itself — or against 1920×1080 16:9 test content.
    /// Idempotent: resolving an already resolved size returns it unchanged.
    private func applyingServerResolution(to config: ClientConfiguration) -> ClientConfiguration {
        var resolved = config
        if isScreenCaptureMode {
            guard let native = ScreenCaptureEngine.primaryDisplayResolution() else { return config }
            let size = SPPWResolutionLadder.resolve(
                requestedWidth: config.width,
                requestedHeight: config.height,
                native: native
            )
            resolved.width = size.width
            resolved.height = size.height
        } else if config.width <= 0 && config.height > 0 {
            // Generated content is 16:9; native (0×0) keeps the 1920×1080 default downstream.
            let size = SPPWResolutionLadder.size(
                shortSide: config.height,
                native: (SPPWResolutionLadder.maximumWidth, SPPWResolutionLadder.maximumHeight)
            )
            resolved.width = size.width
            resolved.height = size.height
        }
        return resolved
    }

    private func expireStaleClientSessions() async {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let staleSessions = clients.values
            .filter { nowNanos &- $0.lastSeen > clientSessionTimeoutNanos }
        guard !staleSessions.isEmpty else { return }

        for session in staleSessions {
            clients.removeValue(forKey: session.streamID)
            forgetRemoteClient(session.streamID)
        }
        syncEncodeWorkerSnapshot()
        log("Expired \(staleSessions.count) inactive client session(s) after \(clientSessionTimeoutNanos / 1_000_000_000)s timeout: \(staleSessions.map(\.streamID))")
        if clients.isEmpty {
            await discardSharedStream(reason: "no active clients")
        }
    }

    private func discardSharedStream(reason: String) async {
        #if os(macOS)
        inputController.releaseAll(displayID: remoteInputState.snapshot().displayID)
        #endif
        stopSessionReaper()
        mediaPacer.cancelPending()
        sharedGeneration &+= 1
        startingGeneration = nil
        encodeWorker?.invalidate(resetFrameCounter: true)
        sourceTask?.cancel()
        sourceTask = nil
        await captureEngine?.stop()
        captureEngine = nil
        rememberVideoPlaybackPosition()
        await testSource?.stop()
        testSource = nil
        sourceGeometry = nil
        sharedConfig = nil
        sharedStreamID = 0
        log("Discarded shared stream session: \(reason)")
    }

    /// Starts the one shared capture/encode pipeline. Every connected receiver
    /// gets video via its own unicast UDP peer address; the first client's
    /// configuration is the initial shared profile.
    private func startStreaming(streamID: UInt32) async {
        // Already streaming or starting this generation: avoid spawning
        // duplicate SCStream / TestContentSource instances when clientHello
        // and READY ping arrive back-to-back while start() is suspended.
        if sourceTask != nil || startingGeneration == sharedGeneration { return }
        guard let storedConfig = sharedConfig ?? clients[streamID]?.config else {
            log("startStreaming: no config available for streamID=\(streamID)", isError: true)
            return
        }
        let config = applyingServerResolution(to: storedConfig)
        sharedConfig = config
        let captureWidth = config.width > 0 ? config.width : 1920
        let captureHeight = config.height > 0 ? config.height : 1080
        let fps = config.fps > 0 ? config.fps : 60
        let startGeneration = sharedGeneration

        startingGeneration = startGeneration
        defer {
            if startingGeneration == startGeneration {
                startingGeneration = nil
            }
        }

        let frameStream: AsyncStream<SendablePixelBuffer>
        let startedCaptureEngine: ScreenCaptureEngine?
        let startedTestSource: TestContentSource?

        if let testContentMode {
            let packetizer = audioPacketizer
            let source = TestContentSource(
                width: captureWidth,
                height: captureHeight,
                fps: fps,
                mode: testContentMode,
                stats: stats,
                initialVideoSeekSeconds: pendingVideoSeekSeconds ?? 0,
                audioHandler: { [weak self] buffer, capturedAt in
                    // Video file mode: stream the file's audio track, stamped on the
                    // same timeline as its frames.
                    let packets = packetizer.packetize(pcmBuffer: buffer, captureNanoseconds: capturedAt)
                    guard !packets.isEmpty, let self else { return }
                    self.audioSendQueue.yield(packets)
                }
            )
            log("Starting shared test source: \(captureWidth)x\(captureHeight) @ \(fps)fps")
            frameStream = await source.start()
            startedCaptureEngine = nil
            startedTestSource = source
        } else {
            let packetizer = audioPacketizer
            #if os(macOS)
            let inputState = remoteInputState
            let displayHandler: (@Sendable (CGDirectDisplayID) -> Void)? = { displayID in
                inputState.setDisplayID(displayID)
            }
            #else
            let displayHandler: (@Sendable (CGDirectDisplayID) -> Void)? = nil
            #endif
            let engine = ScreenCaptureEngine(
                width: captureWidth,
                height: captureHeight,
                fps: fps,
                fullChroma444: fullChroma444,
                showsCursor: captureShowsCursor,
                audioSource: audioSource,
                audioHandler: { [weak self] sampleBuffer in
                    let packets = packetizer.packetize(sampleBuffer: sampleBuffer)
                    guard !packets.isEmpty, let self else { return }
                    self.audioSendQueue.yield(packets)
                },
                displayHandler: displayHandler,
                logHandler: { [weak self] message, isError in
                    Task { await self?.log(message, isError: isError) }
                }
            )
            log("Starting shared ScreenCaptureKit source: \(captureWidth)x\(captureHeight) @ \(fps)fps, chroma \(fullChroma444 ? "4:4:4 (10-bit capture)" : "4:2:0")")
            frameStream = await engine.start()
            startedCaptureEngine = engine
            startedTestSource = nil
        }

        guard startGeneration == sharedGeneration, udpSocket != nil else {
            await startedCaptureEngine?.stop()
            await startedTestSource?.stop()
            return
        }

        captureEngine = startedCaptureEngine
        testSource = startedTestSource
        sourceGeometry = (captureWidth, captureHeight)
        syncEncodeWorkerSnapshot()

        let generation = startGeneration
        let worker = encodeWorker
        // Pump frames directly into the dedicated serial Metal encode worker
        // without re-entering the StreamServer actor on every frame.
        sourceStartedAtNanos = SPPWCaptureClock.nowNanoseconds()
        sourceTask = Task.detached(priority: .userInitiated) { [weak self, weak worker] in
            for await pixelBuffer in frameStream {
                guard !Task.isCancelled else { return }
                worker?.submit(pixelBuffer, generation: generation)
            }
            guard !Task.isCancelled, let self else { return }
            await self.handleSourceEnded(generation: generation)
        }
    }

    private func broadcastAudioPackets(_ packets: [(sequence: UInt32, timestampNanoseconds: UInt64, payload: Data)]) {
        guard let socket = udpSocket, sharedStreamID != 0 else { return }
        let peers = clients.values.map(\.peer)
        guard !peers.isEmpty else { return }
        let datagrams = packets.map { packet in
            makeWireAudioDatagram(
                streamID: sharedStreamID,
                sequence: packet.sequence,
                timestampNanoseconds: packet.timestampNanoseconds,
                audioPayload: packet.payload
            )
        }
        socket.sendBatch(datagrams, to: peers)
    }

    private func handleSourceEnded(generation: UInt64) {
        guard generation == sharedGeneration else { return }
        #if os(macOS)
        inputController.releaseAll(displayID: remoteInputState.snapshot().displayID)
        #endif
        sourceTask = nil
        captureEngine = nil
        testSource = nil
        sourceGeometry = nil
        let now = SPPWCaptureClock.nowNanoseconds()
        if now &- sourceStartedAtNanos >= SPPWSourceRestartPolicy.healthyRunNanoseconds {
            sourceRestartAttempts = 0
        }
        log("Sorgente video terminata", isError: true)
        scheduleSourceRestart()
    }

    /// Restarts a source that stopped on its own (ScreenCaptureKit stops when the display
    /// sleeps or locks, or when the system interrupts capture) as long as clients are still
    /// connected. Before this, the stream stayed dead until a client reconnected, because
    /// only a READY ping (sent once on connect) starts the source.
    private func scheduleSourceRestart() {
        guard sourceRestartTask == nil, udpSocket != nil, !clients.isEmpty else { return }
        let delay = SPPWSourceRestartPolicy.delayNanoseconds(attempt: sourceRestartAttempts)
        sourceRestartAttempts += 1
        log("Riavvio automatico della sorgente tra \(delay / 1_000_000_000) s")
        sourceRestartTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.performSourceRestart()
        }
    }

    private func performSourceRestart() async {
        sourceRestartTask = nil
        guard udpSocket != nil, sourceTask == nil,
              let streamID = sharedStreamID != 0 ? sharedStreamID : clients.values.first?.streamID else { return }
        guard !clients.isEmpty else {
            sourceRestartAttempts = 0
            return
        }
        await startStreaming(streamID: streamID)
    }

    private func restartSharedSource(streamID: UInt32) async {
        // Invalidate in-flight encodes before awaiting the source shutdown. Keep
        // frame IDs monotonic when other receivers share this stream session.
        mediaPacer.cancelPending()
        sharedGeneration &+= 1
        encodeWorker?.invalidate(resetFrameCounter: false)
        sourceTask?.cancel()
        sourceTask = nil
        await captureEngine?.stop()
        captureEngine = nil
        rememberVideoPlaybackPosition()
        await testSource?.stop()
        testSource = nil
        sourceGeometry = nil
        log("Resynchronizing shared stream for controlID=\(streamID)")
        await startStreaming(streamID: streamID)
    }
}

// MARK: - Screen capture

/// Wraps a CVPixelBuffer for cross-actor transfer. The buffer is retained
/// and not mutated after wrapping.
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Capture instant on `SPPWCaptureClock` (0 = unknown, stamped when encoded). Video frames
    /// and audio packets share this clock so receivers can lip-sync them.
    var captureTimestampNanoseconds: UInt64 = 0
}

/// Time of the last ScreenCaptureKit screen callback of any status (idle included), so
/// the server can tell a still screen from a capture that stopped delivering anything.
final class CaptureActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCallbackNanos = SPPWCaptureClock.nowNanoseconds()

    func noteCallback() {
        let now = SPPWCaptureClock.nowNanoseconds()
        lock.lock()
        lastCallbackNanos = now
        lock.unlock()
    }

    func silenceNanoseconds(now: UInt64 = SPPWCaptureClock.nowNanoseconds()) -> UInt64 {
        lock.lock()
        let last = lastCallbackNanos
        lock.unlock()
        return now > last ? now - last : 0
    }
}

actor ScreenCaptureEngine {
    nonisolated let activity = CaptureActivityMonitor()
    private let width: Int
    private let height: Int
    private let fps: Int
    private let fullChroma444: Bool
    /// Draw the host cursor into the video; changed live by `setShowsCursor`.
    private var showsCursor: Bool
    private var activeConfiguration: SCStreamConfiguration?
    private let audioSource: SPPWAudioSourceOption.Kind
    private let audioHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private let displayHandler: (@Sendable (CGDirectDisplayID) -> Void)?
    private let logHandler: @Sendable (String, Bool) -> Void
    private var stream: SCStream?
    private var outputDelegate: CaptureOutputDelegate?
    private var streamDelegate: CaptureStreamDelegate?
    private let outputQueue: DispatchQueue
    private let audioQueue: DispatchQueue
    private var frameContinuation: AsyncStream<SendablePixelBuffer>.Continuation?

    init(
        width: Int,
        height: Int,
        fps: Int,
        fullChroma444: Bool = false,
        showsCursor: Bool = true,
        audioSource: SPPWAudioSourceOption.Kind = .system,
        audioHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil,
        displayHandler: (@Sendable (CGDirectDisplayID) -> Void)? = nil,
        logHandler: @escaping @Sendable (String, Bool) -> Void = { _, _ in }
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.fullChroma444 = fullChroma444
        self.showsCursor = showsCursor
        self.audioSource = audioSource
        self.audioHandler = audioHandler
        self.displayHandler = displayHandler
        self.logHandler = logHandler
        outputQueue = DispatchQueue(label: "it.screenspan.pyrowave.server.capture", qos: .userInteractive)
        audioQueue = DispatchQueue(label: "it.screenspan.pyrowave.server.audio", qos: .userInteractive)
    }

    /// The primary display's native pixel resolution as a stream size.
    nonisolated static func primaryDisplayResolution() -> (width: Int, height: Int)? {
        let displayID = CGMainDisplayID()
        guard displayID != kCGNullDirectDisplay else { return nil }
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return clampedEvenStreamResolution(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        guard width > 0, height > 0 else { return nil }
        return clampedEvenStreamResolution(width: width, height: height)
    }

    nonisolated static func preferredDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let mainID = CGMainDisplayID()
        return displays.first { $0.displayID == mainID } ?? displays.first
    }

    func start() async -> AsyncStream<SendablePixelBuffer> {
        // ScreenCaptureKit can outpace encode/network. Keep one fresh frame and
        // replace it on every newer capture rather than buffering stale video.
        let (stream, continuation) = AsyncStream<SendablePixelBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        frameContinuation = continuation

        if !CGPreflightScreenCaptureAccess() {
            logHandler("Permesso Registrazione schermo non attivo. Abilita PyrowaveCast in Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e riavvia l'app.", true)
        }

        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let display = Self.preferredDisplay(from: availableContent.displays) else {
                logHandler("Nessun display disponibile per la cattura schermo.", true)
                continuation.finish()
                return stream
            }
            displayHandler?(display.displayID)

            let streamConfig = SCStreamConfiguration()
            streamConfig.width = width
            streamConfig.height = height
            streamConfig.scalesToFit = true
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
            // Depth 5 prevents SCStream sample-buffer pool starvation when 1
            // buffer is in flight in ScreenCaptureKit, 1 in AsyncStream, and 1
            // in UpstreamMetalEncoder.
            streamConfig.queueDepth = 5
            streamConfig.showsCursor = showsCursor
            // 'xf44' is ScreenCaptureKit's only 4:4:4 YCbCr output (10-bit samples in
            // 16-bit words). The vendored encoder reads it as RG16/R16 UNORM and
            // UpstreamMetalEncoder switches to a 4:4:4 encoder on the full
            // resolution chroma plane.
            streamConfig.pixelFormat = fullChroma444
                ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            streamConfig.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            var capturesMicrophone = false
            switch audioSource {
            case .none:
                streamConfig.capturesAudio = false
            case .system:
                streamConfig.capturesAudio = true
            case .input(let deviceID):
                streamConfig.capturesAudio = false
                if #available(macOS 15.0, *) {
                    streamConfig.captureMicrophone = true
                    streamConfig.microphoneCaptureDeviceID = deviceID
                    capturesMicrophone = true
                } else {
                    logHandler("La cattura del microfono richiede macOS 15; audio disattivato.", true)
                }
            }
            streamConfig.sampleRate = SPPWAudioPacketHeader.sampleRate
            streamConfig.channelCount = SPPWAudioPacketHeader.channelCount
            streamConfig.excludesCurrentProcessAudio = true

            let contentFilter = SCContentFilter(display: display, excludingWindows: [])
            let sDelegate = CaptureStreamDelegate { [logHandler] error in
                logHandler("Cattura schermo interrotta dal sistema: \(error.localizedDescription)", true)
                continuation.finish()
            }
            let scStream = SCStream(
                filter: contentFilter,
                configuration: streamConfig,
                delegate: sDelegate
            )

            let audioCallback = audioHandler
            let activityMonitor = activity
            let output = CaptureOutputDelegate(
                screenHandler: { sampleBuffer in
                    activityMonitor.noteCallback()
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                       let rawStatus = attachments.first?[.status] as? Int,
                       let status = SCFrameStatus(rawValue: rawStatus),
                       status != .complete && status != .started {
                        return
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    continuation.yield(SendablePixelBuffer(
                        buffer: pixelBuffer,
                        captureTimestampNanoseconds: SPPWCaptureClock.captureNanoseconds(of: sampleBuffer)
                    ))
                },
                audioHandler: { sampleBuffer in
                    audioCallback?(sampleBuffer)
                }
            )

            try scStream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
            if streamConfig.capturesAudio {
                try? scStream.addStreamOutput(
                    output,
                    type: .audio,
                    sampleHandlerQueue: audioQueue
                )
            }
            if capturesMicrophone, #available(macOS 15.0, *) {
                // Microphone buffers arrive in the device's native format; the packetizer
                // resamples them to 48 kHz stereo.
                try? scStream.addStreamOutput(
                    output,
                    type: .microphone,
                    sampleHandlerQueue: audioQueue
                )
            }

            // Retain both delegates strongly for the lifetime of the stream.
            self.streamDelegate = sDelegate
            self.outputDelegate = output
            self.stream = scStream
            self.activeConfiguration = streamConfig
            try await scStream.startCapture()
            logHandler("Cattura schermo avviata: \(width)x\(height) @ \(fps) fps", false)
        } catch {
            logHandler("Errore avvio cattura schermo: \(error.localizedDescription). Controlla Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo (e riavvia PyrowaveCast dopo aver attivato il permesso).", true)
            continuation.finish()
        }

        return stream
    }

    /// Shows or hides the host cursor in the running capture without restarting it.
    func setShowsCursor(_ shows: Bool) async {
        guard shows != showsCursor else { return }
        showsCursor = shows
        guard let stream, let configuration = activeConfiguration else { return }
        configuration.showsCursor = shows
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            logHandler("Impossibile aggiornare la visibilità del cursore: \(error.localizedDescription)", true)
        }
    }

    func stop() async {
        activeConfiguration = nil
        do {
            try await stream?.stopCapture()
        } catch {
            logHandler("Capture stop error: \(error.localizedDescription)", true)
        }
        stream = nil
        outputDelegate = nil
        streamDelegate = nil
        frameContinuation?.finish()
        frameContinuation = nil
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate

private final class CaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

final class CaptureOutputDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    private let screenHandler: @Sendable (CMSampleBuffer) -> Void
    private let audioHandler: (@Sendable (CMSampleBuffer) -> Void)?

    init(
        screenHandler: @escaping @Sendable (CMSampleBuffer) -> Void,
        audioHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil
    ) {
        self.screenHandler = screenHandler
        self.audioHandler = audioHandler
    }

    convenience init(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.init(screenHandler: handler, audioHandler: nil)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            screenHandler(sampleBuffer)
        case .audio:
            audioHandler?(sampleBuffer)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                audioHandler?(sampleBuffer)
            }
        }
    }
}

// MARK: - Test content source (no ScreenCaptureKit needed)

/// Produces the frames that the server streams in test mode: an animated test
/// card, a still image, or a looped video file. All of them give the client
/// something visible, so a successful decode is obvious on screen.
actor TestContentSource {
    private let width: Int
    private let height: Int
    private let fps: Int
    private let mode: TestContentMode
    private let videoSource: TestVideoSource?
    private let stats: StreamStats
    private var producerTask: Task<Void, Never>?
    private var continuation: AsyncStream<SendablePixelBuffer>.Continuation?

    init(
        width: Int,
        height: Int,
        fps: Int,
        mode: TestContentMode,
        stats: StreamStats,
        initialVideoSeekSeconds: Double = 0,
        audioHandler: TestVideoAudioHandler? = nil
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.mode = mode
        self.stats = stats

        if case .video(let url) = mode {
            self.videoSource = try? TestVideoSource(url: url, initialTimeSeconds: initialVideoSeekSeconds)
            self.videoSource?.audioHandler = audioHandler
        } else {
            self.videoSource = nil
        }
    }

    nonisolated func seek(to seconds: Double) {
        videoSource?.seek(to: seconds)
    }

    nonisolated func videoPlaybackPosition() -> (current: Double, duration: Double) {
        guard let videoSource else { return (0, 0) }
        return (videoSource.currentTimeSeconds, videoSource.durationSeconds)
    }

    func start() -> AsyncStream<SendablePixelBuffer> {
        let (stream, continuation) = AsyncStream<SendablePixelBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation

        videoSource?.play()

        let w = width
        let h = height
        let intervalNanos = UInt64(1_000_000_000 / max(fps, 1))
        var frameIdx = 0

        producerTask = Task {
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                var pixelBuffer: CVPixelBuffer?

                if let videoSource {
                    pixelBuffer = videoSource.nextFrame()
                }

                if pixelBuffer == nil {
                    let overlay = overlayLines(frameIndex: frameIdx)
                    pixelBuffer = TestContentRenderer.makePixelBuffer(
                        width: w,
                        height: h,
                        frameIndex: frameIdx,
                        mode: mode,
                        overlayLines: overlay
                    )
                }

                if let pixelBuffer {
                    // Stamped when sampled: video files are sampled at the host time the
                    // audio tap uses, so file audio and video stay in sync.
                    continuation.yield(SendablePixelBuffer(
                        buffer: pixelBuffer,
                        captureTimestampNanoseconds: SPPWCaptureClock.nowNanoseconds()
                    ))
                }

                frameIdx += 1
                nextDeadline &+= intervalNanos
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    do {
                        try await Task.sleep(nanoseconds: nextDeadline - now)
                    } catch {
                        break
                    }
                } else {
                    // Catch up without burst-flooding if rendering fell behind by more than 1 interval.
                    nextDeadline = now
                    await Task.yield()
                }
            }
            continuation.finish()
        }

        return stream
    }

    func stop() {
        producerTask?.cancel()
        producerTask = nil
        continuation?.finish()
        continuation = nil
        videoSource?.pause()
    }

    private func overlayLines(frameIndex: Int) -> [String] {
        [
            "PYROWAVE SPPW/1  ·  TEST SOURCE",
            "FRAME \(frameIndex)   \(width)×\(height) @ \(fps) fps   \(String(format: "%.1f", stats.megabitsPerSecond)) Mb/s",
            modeDescription
        ]
    }

    private var modeDescription: String {
        switch mode {
        case .card: "TEST CARD"
        case .image: "STILL IMAGE"
        case .video: "VIDEO FILE"
        }
    }
}

#if os(macOS)
/// Clipboard sync between the Mac pasteboard and subscribed receivers (`kind = 10`).
/// Thread-safe; lives outside the server actor so pasteboard polling never blocks streaming.
final class RemoteClipboardSync: @unchecked Sendable {
    private struct Peer {
        let channel: SPPWClipboardChannel
        var subscribed: Bool
    }

    private let lock = NSLock()
    private var enabled = false
    private var peers: [UInt32: Peer] = [:]
    private lazy var bridge = SPPWMacPasteboardBridge { [weak self] content in
        self?.localPasteboardChanged(content)
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value {
            peers.values.forEach { $0.channel.cancel() }
        }
        lock.unlock()
        updateBridge()
    }

    /// Handles a clipboard payload from `streamID`; `send` transmits a payload back to that client.
    func receive(
        _ payload: Data,
        streamID: UInt32,
        mtu: Int,
        send: @escaping @Sendable (Data) -> Void
    ) -> SPPWClipboardChannel.Incoming {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return .none
        }
        let channel: SPPWClipboardChannel
        if let existing = peers[streamID] {
            channel = existing.channel
        } else {
            channel = SPPWClipboardChannel(maxChunkBytes: SPPWClipboardChannel.chunkBytes(forMTU: mtu), send: send)
            peers[streamID] = Peer(channel: channel, subscribed: false)
        }
        lock.unlock()

        let incoming = channel.receive(payload)
        switch incoming {
        case let .subscription(isOn):
            lock.lock()
            peers[streamID]?.subscribed = isOn
            if !isOn { channel.cancel() }
            lock.unlock()
            if isOn, let current = SPPWMacPasteboardBridge.readCurrent() {
                // What is already on the Mac stays private until it changes.
                channel.noteLocalContent(current)
            }
            updateBridge()
        case let .content(content):
            bridge.write(content)
            lock.lock()
            let others = peers.filter { $0.key != streamID && $0.value.subscribed }.map(\.value.channel)
            lock.unlock()
            others.forEach { $0.offer(content) }
        case .none:
            break
        }
        return incoming
    }

    func remove(streamID: UInt32?) {
        lock.lock()
        if let streamID {
            peers.removeValue(forKey: streamID)?.channel.cancel()
        } else {
            peers.values.forEach { $0.channel.cancel() }
            peers.removeAll()
        }
        lock.unlock()
        updateBridge()
    }

    private func localPasteboardChanged(_ content: SPPWClipboardContent) {
        lock.lock()
        let targets = enabled ? peers.values.filter(\.subscribed).map(\.channel) : []
        lock.unlock()
        targets.forEach { $0.offer(content) }
    }

    private func updateBridge() {
        lock.lock()
        let active = enabled && peers.values.contains(where: \.subscribed)
        lock.unlock()
        if active {
            bridge.start()
        } else {
            bridge.stop()
        }
    }
}
#endif
