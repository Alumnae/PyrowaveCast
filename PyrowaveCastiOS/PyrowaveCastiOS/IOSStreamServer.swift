import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Network
#if canImport(SPPWCommon)
import SPPWCommon
#endif

struct IOSSendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Capture instant on `SPPWCaptureClock` (0 = unknown, stamped when encoded). Audio packets
    /// use the same clock so receivers can lip-sync them with the video.
    var captureTimestampNanoseconds: UInt64 = 0
}

enum IOSServerSource: Equatable, Sendable {
    case card
    case screen
    case image(URL)
    case video(URL)

    var title: String {
        switch self {
        case .card: "Test card"
        case .screen: "Screen capture"
        case .image: "Image"
        case .video: "Video"
        }
    }
}

actor IOSStreamServer {
    private let source: IOSServerSource
    private let logHandler: (@Sendable (ServerLogEntry) -> Void)?
    private let previewHandler: (@Sendable (Data, Int, Int) -> Void)?
    private var previewEnabled: Bool
    private var lastIdlePreviewEncodeNanos: UInt64 = 0
    private let idlePreviewIntervalNanos: UInt64 = 100_000_000
    private var serverScreenResolution: (width: Int, height: Int)

    private var udpSocket: SPPWUDPServerSocket?
    private var bonjourAdvertiser: SPPWBonjourAdvertiser?
    private let mediaPacer = SPPWMediaPacer(label: "it.screenspan.pyrowave.ios.server.pacer")
    private var runningPort: UInt16 = 0
    private var clients: [UInt32: IOSClientSession] = [:]
    private var nextStreamID: UInt32 = 1
    private var sessionReaperTask: Task<Void, Never>?
    private let sessionTimeoutNanos: UInt64 = 30_000_000_000

    private var encoder: UpstreamMetalEncoder?
    /// GPU downscaling of captured frames to the client-chosen level.
    private let frameScaler = IOSFrameScaler()
    /// Turns captured app/system audio into 5 ms SPPW/1 `.audioFrame` packets. Runs on the
    /// capture queue (it is lock protected), only the send hops onto the actor.
    private nonisolated let audioPacketizer = SPPWAudioPacketizer()
    /// Audio packets in capture order; `audioSendTask` is their only consumer.
    private nonisolated let audioSendQueue = SPPWOrderedPacketQueue<[SPPWAudioPacketizer.PacketTuple]>()
    private var audioSendTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var testProducerTask: Task<Void, Never>?
    private var activeVideoSource: TestVideoSource?
    private var pendingVideoSeekSeconds: Double?
    private var screenFrameStream: AsyncStream<IOSSendablePixelBuffer>?
    /// True while the app is in the background without GPU access: iOS rejects Metal work,
    /// so frames are dropped instead of failing in the encoder. Audio and heartbeats go on.
    private var videoSuspended = false
    private var sharedConfig: ClientConfiguration?
    private var sharedStreamID: UInt32 = 0
    private var frameID: UInt32 = 0
    private var generation: UInt64 = 0
    /// The last frame sent, resent while the screen is still (`SPPWStillScreenPolicy`):
    /// ReplayKit / ScreenCaptureKit deliver nothing while nothing changes on screen.
    private var lastSentFrame: (bitstream: Data, width: Int, height: Int, generation: UInt64)?
    private var lastFrameSentNanos: UInt64 = 0
    private var stillRefreshTask: Task<Void, Never>?
    private var geometry: (width: Int, height: Int)?
    private var fps = 0
    private var frameCount = 0
    private var byteCount = 0
    private let stats = StreamStats()
    private var logID = 0

    init(
        source: IOSServerSource,
        screenResolution: (width: Int, height: Int) = (1920, 1080),
        previewEnabled: Bool = true,
        audioInputGain: Float = 1,
        logHandler: (@Sendable (ServerLogEntry) -> Void)? = nil,
        previewHandler: (@Sendable (Data, Int, Int) -> Void)? = nil
    ) {
        self.source = source
        self.previewEnabled = previewEnabled
        audioPacketizer.gain = audioInputGain
        self.serverScreenResolution = Self.clampedEvenResolution(
            width: screenResolution.width,
            height: screenResolution.height
        )
        self.logHandler = logHandler
        self.previewHandler = previewHandler
    }

    func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled = enabled
    }

    nonisolated static func clampedEvenResolution(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = max(width, 320)
        var h = max(height, 240)
        if w > 3840 || h > 2160 {
            let scale = min(3840.0 / Double(w), 2160.0 / Double(h))
            w = max(320, Int((Double(w) * scale).rounded(.down)))
            h = max(240, Int((Double(h) * scale).rounded(.down)))
        }
        w &= ~1
        h &= ~1
        return (max(w, 320), max(h, 240))
    }

    private var isScreenCaptureMode: Bool {
        source == .screen
    }

    /// Resolves the client's requested size (`SPPWResolutionLadder`: `0×0` native, `0×S`
    /// short side, `W×H` fit inside) against the device screen in screen capture mode, or
    /// against 16:9 for generated test content. Frames are scaled to it in `encodeAndSend`.
    private func resolvedConfiguration(for requested: ClientConfiguration) -> ClientConfiguration {
        var config = requested.sanitised()
        if isScreenCaptureMode {
            let size = SPPWResolutionLadder.resolve(
                requestedWidth: config.width,
                requestedHeight: config.height,
                native: serverScreenResolution
            )
            config.width = size.width
            config.height = size.height
        } else if config.width <= 0 && config.height > 0 {
            let size = SPPWResolutionLadder.size(
                shortSide: config.height,
                native: (SPPWResolutionLadder.maximumWidth, SPPWResolutionLadder.maximumHeight)
            )
            config.width = size.width
            config.height = size.height
        }
        return config
    }

    func setScreenFrameStream(_ stream: AsyncStream<IOSSendablePixelBuffer>) async {
        if captureTask != nil {
            // Replacing a capture that stopped (or is being restarted): the old stream is
            // single-consumer and finished, so drop its pump and start one on the new stream.
            generation &+= 1
            captureTask?.cancel()
            captureTask = nil
        }
        screenFrameStream = stream
        // In screen capture mode, start the capture consumer loop immediately so:
        // 1) local server preview renders captured frames right away, and
        // 2) any client that connected while the user was approving the system
        //    screen capture prompt immediately receives video frames.
        if sharedConfig == nil {
            var defaultConfig = ClientConfiguration()
            defaultConfig.width = serverScreenResolution.width
            defaultConfig.height = serverScreenResolution.height
            sharedConfig = defaultConfig
        }
        if sharedStreamID == 0 {
            sharedStreamID = clients.keys.first ?? 1
        }
        await startStreamIfNeeded(controlID: sharedStreamID)
    }

    func start(port: UInt16) async throws {
        let audioPackets = audioSendQueue.makeStream()
        audioSendTask?.cancel()
        audioSendTask = Task { [weak self] in
            for await packets in audioPackets {
                guard let self else { return }
                await self.broadcastAudioPackets(packets)
            }
        }
        guard port > 0, port < UInt16.max else {
            throw NSError(domain: "PyroWaveServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "UDP port must be between 1 and 65534"])
        }
        guard udpSocket == nil else {
            throw NSError(domain: "PyroWaveServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server is already running"])
        }

        let socket = try SPPWUDPServerSocket(
            port: port,
            sendBufferBytes: SPPWSocketBufferTuning.defaultSendBufferBytes,
            receiveBufferBytes: SPPWSocketBufferTuning.defaultReceiveBufferBytes
        )
        let ipv4 = Self.preferredLocalIPv4Address()
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
        udpSocket = socket
        bonjourAdvertiser = advertiser
        runningPort = port

        socket.start { [weak self] data, peer in
            guard let self else { return }
            Task { await self.process(data, from: peer) }
        }

        log("SPPW/1 iOS server listening on UDP \(port) (host=\(hostName), SO_SNDBUF=\(socket.tuning.actualSendBytes / 1024)KB, SO_RCVBUF=\(socket.tuning.actualReceiveBytes / 1024)KB, DSCP=CS4)")
    }

    private func ensureSessionReaperRunning() {
        guard sessionReaperTask == nil, !clients.isEmpty else { return }
        sessionReaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) }
                catch { return }
                guard let self else { return }
                await self.expireInactiveClients()
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

    func stop() async {
        audioSendTask?.cancel()
        audioSendTask = nil
        audioSendQueue.finish()
        sessionReaperTask?.cancel()
        sessionReaperTask = nil
        stillRefreshTask?.cancel()
        stillRefreshTask = nil
        lastSentFrame = nil
        mediaPacer.cancelPending()
        generation &+= 1
        captureTask?.cancel()
        captureTask = nil
        testProducerTask?.cancel()
        testProducerTask = nil
        rememberVideoPlaybackPosition()
        activeVideoSource?.pause()
        activeVideoSource = nil
        bonjourAdvertiser?.stop()
        bonjourAdvertiser = nil
        udpSocket?.stop()
        udpSocket = nil
        clients.removeAll()
        sharedConfig = nil
        sharedStreamID = 0
        frameID = 0
        geometry = nil
        fps = 0
        screenFrameStream = nil
        runningPort = 0
        log("iOS server stopped")
    }

    func status() -> StreamStatus {
        var value = StreamStatus()
        value.isRunning = udpSocket != nil
        value.port = runningPort
        value.connectedClients = clients.count
        value.framesSent = frameCount
        value.bytesSent = byteCount
        value.megabitsPerSecond = stats.megabitsPerSecond
        value.width = geometry?.width ?? 0
        value.height = geometry?.height ?? 0
        value.fps = fps
        value.mode = source.title
        if let activeVideoSource {
            value.videoCurrentTimeSeconds = activeVideoSource.currentTimeSeconds
            value.videoDurationSeconds = activeVideoSource.durationSeconds
        } else if let pendingSeek = pendingVideoSeekSeconds {
            value.videoCurrentTimeSeconds = pendingSeek
        }
        return value
    }

    private func rememberVideoPlaybackPosition() {
        guard let activeVideoSource else { return }
        let duration = activeVideoSource.durationSeconds
        let current = activeVideoSource.currentTimeSeconds
        guard duration > 0 || current > 0 else { return }
        pendingVideoSeekSeconds = current
    }

    func seekVideo(to seconds: Double) {
        let clamped = max(0, seconds)
        pendingVideoSeekSeconds = clamped
        activeVideoSource?.seek(to: clamped)
    }

    private nonisolated static func preferredLocalIPv4Address() -> String? {
        SPPWNetworkInterface.preferredLocalIPv4Address()
    }

    private func process(_ data: Data, from peer: SPPWUDPPeerAddress) async {
        guard let header = parseWireHeader(data) else { return }
        let payload = data.count > WireHeader.byteCount
            ? data.subdata(in: WireHeader.byteCount..<data.count)
            : Data()
        let peerAddress = peer.hostKey

        if header.kind == .clientHello {
            let previousIDs = clients.values.filter { $0.peerAddress == peerAddress }.map(\.streamID)
            for id in previousIDs { clients.removeValue(forKey: id) }
            if !previousIDs.isEmpty {
                log("Replacing previous client session(s) \(previousIDs) for \(peerAddress)")
                if clients.isEmpty { await discardStream(reason: "client reconnected") }
            }

            let requested = (payload.count >= 22 ? parseClientConfig(payload) : nil) ?? ClientConfiguration()
            let config = resolvedConfiguration(for: requested)
            let id = allocateID()
            clients[id] = IOSClientSession(
                streamID: id,
                peer: peer,
                peerAddress: peerAddress,
                config: config
            )
            ensureSessionReaperRunning()
            if sharedConfig == nil || clients.count == 1 {
                sharedConfig = config
                if sharedStreamID == 0 {
                    sharedStreamID = id
                    frameID = 0
                }
            }
            if isScreenCaptureMode {
                log("Client session \(id) connected from \(peerAddress); screen capture at \(config.width)x\(config.height) (client asked \(requested.width)x\(requested.height), native \(serverScreenResolution.width)x\(serverScreenResolution.height))")
            } else {
                log("Client session \(id) connected from \(peerAddress); shared stream \(sharedStreamID)")
            }
            sendServerHello(to: peer, controlID: id)
            // Start streaming immediately after hello — no READY ping needed.
            await startStreamIfNeeded(controlID: id)
            return
        }

        guard var client = clients[header.streamID], client.peerAddress == peerAddress else { return }
        client.peer = peer
        client.lastSeen = DispatchTime.now().uptimeNanoseconds
        clients[header.streamID] = client

        switch header.kind {
        case .streamConfiguration:
            guard payload.count >= 22, let decoded = parseClientConfig(payload) else { return }
            let config = resolvedConfiguration(for: decoded)
            let changed = client.config.width != config.width
                || client.config.height != config.height
                || client.config.fps != config.fps
            let isResync = header.flags & 1 != 0
            var responseID = header.streamID

            if isResync {
                clients.removeValue(forKey: header.streamID)
                responseID = allocateID()
                client = IOSClientSession(
                    streamID: responseID,
                    peer: peer,
                    peerAddress: peerAddress,
                    config: config
                )
                clients[responseID] = client
                if clients.count == 1 {
                    sharedStreamID = responseID
                    frameID = 0
                }
                log("Stream lost; replaced control session with \(responseID)")
            } else {
                client.config = config
                clients[responseID] = client
            }

            sharedConfig = config
            if !isScreenCaptureMode && (isResync || changed) {
                await restartStream(controlID: responseID)
            } else if isScreenCaptureMode {
                await startStreamIfNeeded(controlID: responseID)
            }
            if isResync {
                sendServerHello(to: peer, controlID: responseID)
                // Frames are intra-only: the last one is a full picture for the new session.
                resendLastFrameIfStill(force: true)
            } else {
                let ackFlags: UInt16 = isScreenCaptureMode ? WireControlFlags.serverControlledResolution : 0
                udpSocket?.send(
                    makeWireDatagram(
                        kind: .streamConfiguration,
                        streamID: responseID,
                        flags: ackFlags,
                        width: UInt16(clamping: config.width),
                        height: UInt16(clamping: config.height)
                    ),
                    to: peer
                )
            }

        case .ping:
            if payload == Data("READY".utf8) {
                await startStreamIfNeeded(controlID: client.streamID)
            }
            udpSocket?.send(
                makeWireDatagram(kind: .pong, streamID: client.streamID),
                to: peer
            )

        case .input, .clipboard, .clientHello, .pong, .serverHello, .frameFragment, .fecParity, .audioFrame:
            break
        }
    }

    private func allocateID() -> UInt32 {
        while true {
            let candidate = nextStreamID
            nextStreamID &+= 1
            if nextStreamID == 0 { nextStreamID = 1 }
            if candidate != 0, clients[candidate] == nil { return candidate }
        }
    }

    private func sendServerHello(to peer: SPPWUDPPeerAddress, controlID: UInt32) {
        let activeConfig = sharedConfig ?? clients[controlID]?.config
        // The resolved stream size (client-chosen level, never above native).
        let resolvedWidth = activeConfig?.width ?? (isScreenCaptureMode ? serverScreenResolution.width : 0)
        let resolvedHeight = activeConfig?.height ?? (isScreenCaptureMode ? serverScreenResolution.height : 0)
        let flags: UInt16 = isScreenCaptureMode ? WireControlFlags.serverControlledResolution : 0
        let timeoutSeconds = UInt16(clamping: max(1, sessionTimeoutNanos / 1_000_000_000))
        let activeFPS = UInt16(clamping: activeConfig?.fps ?? 60)

        var details = Data()
        details.appendBE(sharedStreamID)
        details.appendBE(timeoutSeconds)
        details.appendBE(activeFPS)
        udpSocket?.send(
            makeWireDatagram(
                kind: .serverHello,
                streamID: controlID,
                flags: flags,
                width: UInt16(clamping: resolvedWidth),
                height: UInt16(clamping: resolvedHeight),
                payload: details
            ),
            to: peer
        )
    }

    private func expireInactiveClients() async {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let expired = clients.values
            .filter { nowNanos &- $0.lastSeen > sessionTimeoutNanos }
            .map(\.streamID)
        guard !expired.isEmpty else { return }
        for id in expired {
            clients.removeValue(forKey: id)
        }
        log("Expired \(expired.count) inactive client session(s) after \(sessionTimeoutNanos / 1_000_000_000)s timeout: \(expired)")
        if clients.isEmpty { await discardStream(reason: "no live clients") }
    }

    private func discardStream(reason: String) async {
        stopSessionReaper()
        mediaPacer.cancelPending()
        // Note: in `.screen` mode, `screenFrameStream` is a single-consumer
        // AsyncStream owned by IOSScreenCaptureCoordinator. Never cancel
        // `captureTask` while the server is still running in `.screen` mode,
        // or the AsyncStream terminates permanently and subsequent clients get
        // zero frames.
        if !isScreenCaptureMode {
            generation &+= 1
            captureTask?.cancel()
            captureTask = nil
            testProducerTask?.cancel()
            testProducerTask = nil
            geometry = nil
            fps = 0
            sharedConfig = nil
            sharedStreamID = 0
            frameID = 0
        }
        log("Discarded shared stream session: \(reason)")
    }

    private func startStreamIfNeeded(controlID: UInt32) async {
        guard captureTask == nil else { return }
        let fallbackConfig: ClientConfiguration = {
            var cfg = ClientConfiguration()
            cfg.width = serverScreenResolution.width
            cfg.height = serverScreenResolution.height
            return cfg
        }()
        let config = sharedConfig ?? clients[controlID]?.config ?? fallbackConfig
        sharedConfig = config
        if sharedStreamID == 0 {
            sharedStreamID = controlID != 0 ? controlID : 1
        }
        let width = config.width > 0 ? config.width : serverScreenResolution.width
        let height = config.height > 0 ? config.height : serverScreenResolution.height
        let requestedFPS = max(config.fps, 1)

        let frames: AsyncStream<IOSSendablePixelBuffer>
        switch source {
        case .screen:
            guard let screenFrameStream else {
                log("Screen capture is not authorized/ready; waiting for system capture picker", isError: true)
                return
            }
            frames = screenFrameStream
        case .card, .image, .video:
            frames = makeTestFrameStream(width: width, height: height, fps: requestedFPS)
        }

        geometry = (width, height)
        fps = requestedFPS
        let currentGeneration = generation
        captureTask = Task { [weak self] in
            for await frame in frames {
                guard !Task.isCancelled, let self else { return }
                await self.encodeAndSend(
                    frame.buffer,
                    captureTimestampNanoseconds: frame.captureTimestampNanoseconds,
                    generation: currentGeneration
                )
            }
            guard let self else { return }
            await self.sourceEnded(generation: currentGeneration)
        }
        log("Streaming \(source.title): \(width)x\(height) @ \(requestedFPS) fps")
        startStillRefreshIfNeeded()
    }

    private func startStillRefreshIfNeeded() {
        guard stillRefreshTask == nil else { return }
        stillRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                await self?.resendLastFrameIfStill(force: false)
            }
        }
    }

    /// Resends the last encoded frame (new frame ID and timestamp) when no frame went out
    /// for `SPPWStillScreenPolicy.refreshIntervalNanoseconds`, or right away on a resync.
    /// Keeps receivers' fresh-frame watchdogs quiet on a still screen and repairs a last
    /// frame lost on the network, without any GPU work.
    private func resendLastFrameIfStill(force: Bool) {
        let now = SPPWCaptureClock.nowNanoseconds()
        guard force || SPPWStillScreenPolicy.shouldRefresh(nowNanoseconds: now, lastSentNanoseconds: lastFrameSentNanos),
              !videoSuspended,
              captureTask != nil,
              let frame = lastSentFrame, frame.generation == generation,
              let config = sharedConfig,
              let socket = udpSocket else { return }
        let peers = clients.values.map(\.peer)
        guard !peers.isEmpty else { return }
        let totalDatagramLimit = min(max(config.mtu, 512), 1200)
        let payloadLimit = max(256, totalDatagramLimit - WireHeader.byteCount)
        let effectiveFECPercent = clients.values.map(\.config.fecPercent).max() ?? config.fecPercent
        frameID &+= 1
        let datagrams = buildPacedFrameDatagrams(
            streamID: sharedStreamID,
            frameID: frameID,
            width: UInt16(frame.width),
            height: UInt16(frame.height),
            timestampNanoseconds: now,
            bitstream: frame.bitstream,
            payloadLimit: payloadLimit,
            fecPercent: effectiveFECPercent
        )
        mediaPacer.enqueueFrame(datagrams: datagrams, burstSize: 6, fps: config.fps) { burst in
            socket.sendBatch(burst, to: peers)
        }
        lastFrameSentNanos = now
        frameCount += 1
        byteCount += frame.bitstream.count
        stats.record(frameBytes: frame.bitstream.count)
    }

    private func makeTestFrameStream(width: Int, height: Int, fps: Int) -> AsyncStream<IOSSendablePixelBuffer> {
        let (stream, continuation) = AsyncStream<IOSSendablePixelBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let frameIntervalNanos = UInt64(1_000_000_000 / Int64(max(fps, 1)))
        let testMode: TestContentMode
        let testLabel: String
        switch source {
        case .card, .screen:
            testMode = .card
            testLabel = "TEST CARD"
        case .image(let url):
            testMode = .image(url)
            testLabel = "STILL IMAGE"
        case .video(let url):
            testMode = .video(url)
            testLabel = "VIDEO FILE"
        }
        // Resume from where the previous video source had got to (resolution
        // change / renegotiation) instead of rewinding to the start.
        rememberVideoPlaybackPosition()
        let videoSource: TestVideoSource?
        if case .video(let url) = source {
            do {
                videoSource = try TestVideoSource(url: url, initialTimeSeconds: pendingVideoSeekSeconds ?? 0)
            } catch {
                log("Failed to open video source \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
                videoSource = nil
            }
        } else {
            videoSource = nil
        }
        activeVideoSource?.pause()
        activeVideoSource = videoSource
        // Stream the file's audio track too (silenced on the server itself).
        videoSource?.audioHandler = { [weak self] buffer, capturedAt in
            self?.ingestAudio(pcmBuffer: buffer, captureNanoseconds: capturedAt)
        }

        testProducerTask?.cancel()
        testProducerTask = Task { [weak self, stats] in
            videoSource?.play()
            var index = 0
            var loggedVideoError = false
            let videoWarmupDeadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                let videoFrame = videoSource?.nextFrame()
                if videoFrame == nil, let videoSource {
                    if let failure = videoSource.failureDescription {
                        if !loggedVideoError {
                            loggedVideoError = true
                            await self?.log("Video playback failed: \(failure) — falling back to test card", isError: true)
                        }
                    } else if DispatchTime.now().uptimeNanoseconds < videoWarmupDeadline {
                        do { try await Task.sleep(nanoseconds: frameIntervalNanos) }
                        catch { break }
                        nextDeadline = DispatchTime.now().uptimeNanoseconds
                        continue
                    }
                }
                let pixelBuffer = videoFrame ?? TestContentRenderer.makePixelBuffer(
                    width: width,
                    height: height,
                    frameIndex: index,
                    mode: testMode,
                    overlayLines: [
                        "PYROWAVE SPPW/1 · iOS SERVER",
                        "FRAME \(index) · \(width)x\(height) @ \(fps) FPS · \(String(format: "%.1f", stats.megabitsPerSecond)) Mb/s",
                        testLabel
                    ]
                )
                if let pixelBuffer {
                    // Stamped when sampled, the timeline the file's audio tap uses (A/V sync).
                    continuation.yield(IOSSendablePixelBuffer(
                        buffer: pixelBuffer,
                        captureTimestampNanoseconds: SPPWCaptureClock.nowNanoseconds()
                    ))
                }
                index &+= 1
                nextDeadline &+= frameIntervalNanos
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    do { try await Task.sleep(nanoseconds: nextDeadline - now) }
                    catch { break }
                } else {
                    nextDeadline = now
                    await Task.yield()
                }
            }
            videoSource?.pause()
            continuation.finish()
        }
        return stream
    }

    private func sourceEnded(generation sourceGeneration: UInt64) {
        guard sourceGeneration == generation else { return }
        captureTask = nil
        testProducerTask?.cancel()
        testProducerTask = nil
        log("Frame source ended; waiting for a fresh client handshake", isError: true)
    }

    private func restartStream(controlID: UInt32) async {
        guard !isScreenCaptureMode else {
            await startStreamIfNeeded(controlID: controlID)
            return
        }
        mediaPacer.cancelPending()
        generation &+= 1
        captureTask?.cancel()
        captureTask = nil
        testProducerTask?.cancel()
        testProducerTask = nil
        geometry = nil
        fps = 0
        log("Restarting shared stream for control session \(controlID)")
        await startStreamIfNeeded(controlID: controlID)
    }

    /// Entry point for captured audio (screen capture mode). Called on the capture queue.
    nonisolated func ingestAudio(_ sampleBuffer: CMSampleBuffer) {
        let packets = audioPacketizer.packetize(sampleBuffer: sampleBuffer)
        guard !packets.isEmpty else { return }
        audioSendQueue.yield(packets)
    }

    /// Entry point for microphone / media-file audio (`AVAudioPCMBuffer` + capture instant).
    nonisolated func ingestAudio(pcmBuffer: AVAudioPCMBuffer, captureNanoseconds: UInt64) {
        let packets = audioPacketizer.packetize(pcmBuffer: pcmBuffer, captureNanoseconds: captureNanoseconds)
        guard !packets.isEmpty else { return }
        audioSendQueue.yield(packets)
    }

    /// Input volume (0 = silence, 1 = unchanged, 2 = +6 dB); applies immediately.
    nonisolated func setAudioInputGain(_ gain: Float) {
        audioPacketizer.gain = gain
    }

    private func broadcastAudioPackets(_ packets: [SPPWAudioPacketizer.PacketTuple]) {
        guard let socket = udpSocket, sharedStreamID != 0, captureTask != nil else { return }
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

    /// Pauses or resumes video encoding (background without GPU access). PyroWave frames
    /// are intra-only, so the first frame after resuming decodes on its own.
    func setVideoSuspended(_ suspended: Bool) {
        guard suspended != videoSuspended else { return }
        videoSuspended = suspended
        log(suspended ? "Video paused (app in background without GPU access)" : "Video resumed")
    }

    private func encodeAndSend(
        _ pixelBuffer: CVPixelBuffer,
        captureTimestampNanoseconds: UInt64 = 0,
        generation frameGeneration: UInt64
    ) async {
        guard !videoSuspended,
              frameGeneration == generation,
              let config = sharedConfig,
              let socket = udpSocket else { return }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        var pixelBuffer = pixelBuffer
        if isScreenCaptureMode {
            // Captured frames are native; the client may have chosen a lower level.
            serverScreenResolution = (sourceWidth, sourceHeight)
            let target = SPPWResolutionLadder.resolve(
                requestedWidth: config.width,
                requestedHeight: config.height,
                native: (sourceWidth, sourceHeight)
            )
            if target.width != sourceWidth || target.height != sourceHeight {
                guard let scaled = frameScaler.scale(pixelBuffer, to: target) else { return }
                pixelBuffer = scaled
            }
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else { return }
        if geometry?.width != width || geometry?.height != height {
            geometry = (width, height)
        }

        let peers = clients.values.map(\.peer)
        let needsLocalPreview = previewEnabled && previewHandler != nil
        guard !peers.isEmpty || needsLocalPreview else { return }

        // With 0 connected clients, avoid running 60 FPS GPU wavelet encoding
        // when only the 10 Hz local preview needs frames.
        if peers.isEmpty {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now &- lastIdlePreviewEncodeNanos >= idlePreviewIntervalNanos else { return }
            lastIdlePreviewEncodeNanos = now
        }

        do {
            if encoder == nil { encoder = try UpstreamMetalEncoder() }
            guard let encoder else { return }
            let maxBytes = maximumBitstreamBytes(width: width, height: height, config: config)
            let totalDatagramLimit = min(max(config.mtu, 512), 1200)
            let payloadLimit = max(256, totalDatagramLimit - WireHeader.byteCount)
            let output = try encoder.encode(
                pixelBuffer: pixelBuffer,
                maximumBitstreamBytes: maxBytes,
                packetBoundary: payloadLimit
            )
            guard !output.bitstream.isEmpty, frameGeneration == generation else { return }
            let count = (output.bitstream.count + payloadLimit - 1) / payloadLimit
            guard count <= 16_384 else {
                log("Frame too large for SPPW/1: \(output.bitstream.count) bytes", isError: true)
                return
            }

            if previewEnabled {
                previewHandler?(output.bitstream, width, height)
            }
            guard !peers.isEmpty else { return }

            let effectiveFECPercent = clients.values.map(\.config.fecPercent).max() ?? config.fecPercent

            frameID &+= 1
            let currentFrameID = frameID
            // Capture instant, shared with the audio packets (A/V sync on the receiver).
            let frameTimestamp = captureTimestampNanoseconds != 0
                ? captureTimestampNanoseconds
                : SPPWCaptureClock.nowNanoseconds()

            let datagrams = buildPacedFrameDatagrams(
                streamID: sharedStreamID,
                frameID: currentFrameID,
                width: UInt16(width),
                height: UInt16(height),
                timestampNanoseconds: frameTimestamp,
                bitstream: output.bitstream,
                payloadLimit: payloadLimit,
                fecPercent: effectiveFECPercent
            )

            mediaPacer.enqueueFrame(
                datagrams: datagrams,
                burstSize: 6,
                fps: config.fps
            ) { burst in
                socket.sendBatch(burst, to: peers)
            }

            frameCount += 1
            byteCount += output.bitstream.count
            stats.record(frameBytes: output.bitstream.count)
            lastSentFrame = (output.bitstream, width, height, frameGeneration)
            lastFrameSentNanos = SPPWCaptureClock.nowNanoseconds()
        } catch {
            log("Encode error: \(error)", isError: true)
        }
    }

    private func maximumBitstreamBytes(width: Int, height: Int, config: ClientConfiguration) -> Int {
        let safeQuality = min(max(config.quality, 0.01), 1)
        let bitrateBudget: Double
        if config.automaticBitrate {
            let autoBudget = Double(width * height) * 1.4 * safeQuality / 8
            if config.maxBitrate > 0 {
                let capBudget = Double(config.maxBitrate) / 8.0 / Double(max(config.fps, 1))
                bitrateBudget = min(autoBudget, capBudget)
            } else {
                bitrateBudget = autoBudget
            }
        } else {
            bitrateBudget = (Double(config.maxBitrate) / 8 / Double(max(config.fps, 1))) * safeQuality
        }
        return min(max(Int(bitrateBudget), 4096), 32 * 1024 * 1024)
    }

    private func log(_ text: String, isError: Bool = false) {
        if isError { fputs(text + "\n", stderr) } else { print(text) }
        logID += 1
        logHandler?(ServerLogEntry(id: logID, timestamp: Date(), text: text, isError: isError))
    }
}

/// iOS client session.
struct IOSClientSession: Sendable {
    let streamID: UInt32
    var peer: SPPWUDPPeerAddress
    var peerAddress: String
    var config: ClientConfiguration
    var lastSeen: UInt64 = DispatchTime.now().uptimeNanoseconds
}
