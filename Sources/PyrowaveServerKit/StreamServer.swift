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

            encodeSingleFrame(frame.frame.buffer, snapshot: currentSnapshot)
        }
    }

    private func encodeSingleFrame(_ pixelBuffer: CVPixelBuffer, snapshot: Snapshot) {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else { return }

        do {
            if encoder == nil { encoder = try UpstreamMetalEncoder() }
            guard let encoder else { return }

            let config = snapshot.config
            let maximumBytes = Self.maximumBitstreamBytes(width: width, height: height, config: config)
            let requestedMTU = config.mtu > 0 ? config.mtu : 1200
            let datagramLimit = min(requestedMTU, 1200)
            let payloadLimit = max(256, datagramLimit - WireHeader.byteCount)

            let result = try encoder.encode(
                pixelBuffer: pixelBuffer,
                maximumBitstreamBytes: maximumBytes,
                packetBoundary: payloadLimit
            )

            // Re-check snapshot after Metal encode so we drop frames from superseded generations.
            lock.lock()
            let latestSnapshot = self.snapshot
            guard let latestSnapshot,
                  latestSnapshot.generation == snapshot.generation,
                  !latestSnapshot.peers.isEmpty else {
                lock.unlock()
                return
            }
            frameCounter &+= 1
            let frameID = frameCounter
            lock.unlock()

            guard !result.bitstream.isEmpty else { return }
            let fragmentTotal = (result.bitstream.count + payloadLimit - 1) / payloadLimit
            guard fragmentTotal <= Int(UInt16.max) else {
                logHandler("Frame too large to fragment: \(result.bitstream.count) bytes", true)
                return
            }

            let frameTimestamp = DispatchTime.now().uptimeNanoseconds
            let datagrams = buildPacedFrameDatagrams(
                streamID: latestSnapshot.streamID,
                frameID: frameID,
                width: UInt16(width),
                height: UInt16(height),
                timestampNanoseconds: frameTimestamp,
                bitstream: result.bitstream,
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

            stats.record(frameBytes: result.bitstream.count)
            previewHandler?(result.bitstream, width, height)
        } catch {
            logHandler("Encode error: \(error)", true)
        }
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
    private let audioPacketizer = SPPWAudioPacketizer()
    private var encodeWorker: ServerEncodeWorker?
    private var clients: [UInt32: ClientSession] = [:]
    private var nextStreamID: UInt32 = 1
    private var sessionReaperTask: Task<Void, Never>?
    private let clientSessionTimeoutNanos: UInt64 = 30_000_000_000
    private var captureEngine: ScreenCaptureEngine?
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
    private var pendingVideoSeekSeconds: Double?
    private let stats = StreamStats()
    private var runningPort: UInt16 = 0

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
        logHandler: (@Sendable (ServerLogEntry) -> Void)? = nil,
        previewHandler: (@Sendable (Data, Int, Int) -> Void)? = nil
    ) {
        self.testContentMode = testContentMode
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
            }
            if !replacedIDs.isEmpty {
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

            if isResync || geometryOrRateChanged {
                await restartSharedSource(streamID: responseStreamID)
            }

            if isResync {
                sendServerHello(to: peer, controlStreamID: responseStreamID, config: updatedConfig)
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
            handleClientInputPayload(payload)

        case .clientHello, .pong, .serverHello, .frameFragment, .fecParity, .audioFrame:
            break
        }
    }

    private func handleClientInputPayload(_ payload: Data) {
        #if os(macOS)
        if let event = SPPWInputEvent.decode(from: payload) {
            SPPWMacInputInjector.inject(event)
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
                SPPWMacInputInjector.inject(.touch([SPPWTouchPoint(id: 0, phase: phase, normalizedX: x, normalizedY: y)]))
            }
        }
        #endif
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
    private func applyingServerResolution(to config: ClientConfiguration) -> ClientConfiguration {
        guard isScreenCaptureMode,
              let size = ScreenCaptureEngine.primaryDisplayResolution() else { return config }
        var resolved = config
        resolved.width = size.width
        resolved.height = size.height
        return resolved
    }

    private func expireStaleClientSessions() async {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let staleSessions = clients.values
            .filter { nowNanos &- $0.lastSeen > clientSessionTimeoutNanos }
        guard !staleSessions.isEmpty else { return }

        for session in staleSessions {
            clients.removeValue(forKey: session.streamID)
        }
        syncEncodeWorkerSnapshot()
        log("Expired \(staleSessions.count) inactive client session(s) after \(clientSessionTimeoutNanos / 1_000_000_000)s timeout: \(staleSessions.map(\.streamID))")
        if clients.isEmpty {
            await discardSharedStream(reason: "no active clients")
        }
    }

    private func discardSharedStream(reason: String) async {
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
            let source = TestContentSource(
                width: captureWidth,
                height: captureHeight,
                fps: fps,
                mode: testContentMode,
                stats: stats,
                initialVideoSeekSeconds: pendingVideoSeekSeconds ?? 0
            )
            log("Starting shared test source: \(captureWidth)x\(captureHeight) @ \(fps)fps")
            frameStream = await source.start()
            startedCaptureEngine = nil
            startedTestSource = source
        } else {
            let packetizer = audioPacketizer
            let engine = ScreenCaptureEngine(
                width: captureWidth,
                height: captureHeight,
                fps: fps,
                audioHandler: { [weak self] sampleBuffer in
                    let packets = packetizer.packetize(sampleBuffer: sampleBuffer)
                    guard !packets.isEmpty, let self else { return }
                    Task { await self.broadcastAudioPackets(packets) }
                },
                logHandler: { [weak self] message, isError in
                    Task { await self?.log(message, isError: isError) }
                }
            )
            log("Starting shared ScreenCaptureKit source: \(captureWidth)x\(captureHeight) @ \(fps)fps")
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
        sourceTask = nil
        captureEngine = nil
        testSource = nil
        sourceGeometry = nil
        log("Sorgente video terminata; in attesa di nuova connessione/riconnessione", isError: true)
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
}

actor ScreenCaptureEngine {
    private let width: Int
    private let height: Int
    private let fps: Int
    private let audioHandler: (@Sendable (CMSampleBuffer) -> Void)?
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
        audioHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil,
        logHandler: @escaping @Sendable (String, Bool) -> Void = { _, _ in }
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.audioHandler = audioHandler
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

            let streamConfig = SCStreamConfiguration()
            streamConfig.width = width
            streamConfig.height = height
            streamConfig.scalesToFit = true
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
            // Depth 5 prevents SCStream sample-buffer pool starvation when 1
            // buffer is in flight in ScreenCaptureKit, 1 in AsyncStream, and 1
            // in UpstreamMetalEncoder.
            streamConfig.queueDepth = 5
            streamConfig.showsCursor = true
            streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            streamConfig.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            streamConfig.capturesAudio = true
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
            let output = CaptureOutputDelegate(
                screenHandler: { sampleBuffer in
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                       let rawStatus = attachments.first?[.status] as? Int,
                       let status = SCFrameStatus(rawValue: rawStatus),
                       status != .complete && status != .started {
                        return
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    continuation.yield(SendablePixelBuffer(buffer: pixelBuffer))
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
            try? scStream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: audioQueue
            )

            // Retain both delegates strongly for the lifetime of the stream.
            self.streamDelegate = sDelegate
            self.outputDelegate = output
            self.stream = scStream
            try await scStream.startCapture()
            logHandler("Cattura schermo avviata: \(width)x\(height) @ \(fps) fps", false)
        } catch {
            logHandler("Errore avvio cattura schermo: \(error.localizedDescription). Controlla Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo (e riavvia PyrowaveCast dopo aver attivato il permesso).", true)
            continuation.finish()
        }

        return stream
    }

    func stop() async {
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
        @unknown default:
            break
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
        initialVideoSeekSeconds: Double = 0
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.mode = mode
        self.stats = stats

        if case .video(let url) = mode {
            self.videoSource = try? TestVideoSource(url: url, initialTimeSeconds: initialVideoSeekSeconds)
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
                    continuation.yield(SendablePixelBuffer(buffer: pixelBuffer))
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
