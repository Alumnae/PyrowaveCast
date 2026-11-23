import Combine
import CoreVideo
import Foundation
import Network
import UIKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif

@MainActor
final class IOSReceiverModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case waiting
        case streaming
        case reconnecting(attempt: Int, remainingSeconds: Int)
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: SPPWLocalization.tr("state.disconnected")
            case .connecting: SPPWLocalization.tr("state.connecting")
            case .waiting: SPPWLocalization.tr("state.waiting_video")
            case .streaming: SPPWLocalization.tr("state.streaming")
            case let .reconnecting(attempt, remainingSeconds):
                SPPWLocalization.tr("state.reconnecting_fmt", attempt, remainingSeconds)
            case .failed(let message):
                SPPWLocalization.tr("state.error_fmt", message)
            }
        }
    }

    struct FavoriteServer: Codable, Identifiable, Equatable, Sendable {
        var id: String { "\(host.lowercased()):\(port)" }
        var name: String
        var host: String
        var port: UInt16

        init(name: String, host: String, port: UInt16 = 9888) {
            self.name = name
            self.host = host
            self.port = port
        }
    }

    struct DiscoveredServer: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let host: String
        let port: UInt16
        let endpoint: NWEndpoint
    }

    @Published var host = UserDefaults.standard.string(forKey: "iosReceiverHost") ?? "127.0.0.1"
    @Published var portText: String = {
        let saved = UserDefaults.standard.object(forKey: "iosReceiverPort") as? Int
        if let saved, saved != 9945 { return String(saved) }
        return "9888"
    }()
    @Published var favorites: [FavoriteServer] = []
    @Published private(set) var discoveredServers: [DiscoveredServer] = []
    @Published private(set) var isDiscovering = false
    @Published var width = UserDefaults.standard.object(forKey: "iosReceiverWidth") as? Int ?? 1920
    @Published var height = UserDefaults.standard.object(forKey: "iosReceiverHeight") as? Int ?? 1080
    @Published var fps = UserDefaults.standard.object(forKey: "iosReceiverFPS") as? Int ?? 60
    @Published var quality = UserDefaults.standard.object(forKey: "iosReceiverQuality") as? Double ?? 0.5
    @Published var bitrateMbps = UserDefaults.standard.object(forKey: "iosReceiverBitrate") as? Double ?? 80
    @Published var automaticBitrate = UserDefaults.standard.object(forKey: "iosReceiverAutomaticBitrate") as? Bool ?? true
    @Published var fecPercent = UserDefaults.standard.object(forKey: "iosReceiverFECPercent") as? Int ?? 18
    @Published var latencyMode: SPPWLatencyMode = {
        let raw = UserDefaults.standard.object(forKey: "iosReceiverLatencyMode") as? Int ?? 2
        return SPPWLatencyMode(rawValue: UInt8(clamping: raw)) ?? .wifiResilient
    }() {
        didSet {
            UserDefaults.standard.set(Int(latencyMode.rawValue), forKey: "iosReceiverLatencyMode")
            assemblyLock.lock()
            adaptiveBuffer.mode = latencyMode
            assemblyLock.unlock()
        }
    }

    @Published private(set) var state: State = .disconnected
    /// Dedicated high-frequency frame stream that does NOT trigger
    /// `ObservableObject.objectWillChange` (avoiding 60 Hz full UIKit form/log
    /// rebuilds on the main thread).
    let pixelBufferSubject = PassthroughSubject<CVPixelBuffer?, Never>()
    @Published private(set) var hasVideoFrame: Bool = false
    private(set) var currentPixelBuffer: CVPixelBuffer? {
        didSet {
            let nowHasFrame = (currentPixelBuffer != nil)
            if hasVideoFrame != nowHasFrame {
                hasVideoFrame = nowHasFrame
            }
            pixelBufferSubject.send(currentPixelBuffer)
        }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var statistics = ReceiverStatistics()
    @Published private(set) var events: [String] = []
    @Published private(set) var agreedTimeoutSeconds: Int = 30
    @Published private(set) var serverControlledResolution: Bool = false
    /// Requested stream resolution: native, automatic or a short-side level
    /// (`SPPWResolutionLadder`). The server derives the exact size from its own aspect ratio.
    @Published var resolutionMode: SPPWResolutionMode = SPPWResolutionMode(
        id: UserDefaults.standard.string(forKey: "iosReceiverResolutionMode") ?? "native"
    ) {
        didSet {
            guard resolutionMode != oldValue else { return }
            UserDefaults.standard.set(resolutionMode.id, forKey: "iosReceiverResolutionMode")
            autoResolution.reset()
            appendEvent("Risoluzione richiesta: \(resolutionMode.title)")
            if isConnected {
                applySettings()
            }
        }
    }
    /// Short side of the server's native size (learned while streaming native).
    @Published private(set) var nativeShortSide: Int?
    private var nativeSize: (width: Int, height: Int)?
    private var autoResolution = SPPWAutoResolutionController()
    /// Active bitrate target (Mb/s) chosen by the 1-second ABR loop when `automaticBitrate` is enabled.
    @Published private(set) var activeAutoBitrateMbps: Double = 0
    /// Video orientation (0°/90°/180°/270° rotation + horizontal/vertical flip).
    /// When a 90° rotation swaps landscape/portrait dimensions, `(width, height)`
    /// are automatically swapped and renegotiated with the server.
    @Published var videoOrientation: SPPWVideoOrientation = {
        if let data = UserDefaults.standard.data(forKey: "iosReceiverVideoOrientation"),
           let saved = try? JSONDecoder().decode(SPPWVideoOrientation.self, from: data) {
            return saved
        }
        return SPPWVideoOrientation()
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(videoOrientation) {
                UserDefaults.standard.set(data, forKey: "iosReceiverVideoOrientation")
            }
        }
    }

    // MARK: Remote control settings

    @Published var remoteInputMode: IOSRemoteInputMode = IOSRemoteInputMode(
        rawValue: UserDefaults.standard.string(forKey: "iosReceiverRemoteInputMode") ?? ""
    ) ?? .trackpad {
        didSet { UserDefaults.standard.set(remoteInputMode.rawValue, forKey: "iosReceiverRemoteInputMode") }
    }

    /// Trackpad pointer speed, `1...10`.
    @Published var pointerSpeed: Double = UserDefaults.standard.object(forKey: "iosReceiverPointerSpeed") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(pointerSpeed, forKey: "iosReceiverPointerSpeed") }
    }

    /// Two-finger scrolling moves the content with the fingers (like iOS).
    @Published var naturalScrolling: Bool = UserDefaults.standard.object(forKey: "iosReceiverNaturalScrolling") as? Bool ?? true {
        didSet { UserDefaults.standard.set(naturalScrolling, forKey: "iosReceiverNaturalScrolling") }
    }

    /// Clipboard sync with the Mac (Mac → iPhone automatic, iPhone → Mac on explicit paste).
    @Published var clipboardSyncEnabled: Bool = UserDefaults.standard.object(forKey: "iosReceiverClipboardSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(clipboardSyncEnabled, forKey: "iosReceiverClipboardSync")
            clipboardSession.setEnabled(clipboardSyncEnabled)
        }
    }

    /// Sticky modifier bar state shared by the on-screen keyboard and the special keys panel.
    @Published var stickyModifiers = SPPWStickyModifiers()

    nonisolated let clipboardSession = IOSClipboardSession()
    private var inputSequencer = SPPWInputSequencer()

    func rotateVideo() {
        let swapped = videoOrientation.rotate()
        handleOrientationDimensionChange(swappedDimensions: swapped)
    }

    func toggleFlip() {
        videoOrientation.toggleFlip()
        appendEvent("Video orientation: \(videoOrientation.summaryLabel)")
    }

    private func handleOrientationDimensionChange(swappedDimensions: Bool) {
        // Rotation is display-only: the request is a short side, so nothing is renegotiated.
        _ = swappedDimensions
        appendEvent("Video orientation: \(videoOrientation.summaryLabel)")
    }

    struct ReceiverStatistics: Equatable {
        var fragments = 0
        var completeFrames = 0
        var decodedFrames = 0
        var droppedFrames = 0
        var expiredFrames = 0
        var llDroppedFrames = 0
        var fecRecoveredFrames = 0
        var fecRecoveredPackets = 0
        var partialHFFrames = 0
        var jitterMilliseconds = 0.0
        var decodeMilliseconds = 0.0
        var ageMilliseconds = 0.0
        var receivedMbps = 0.0
        var frameWidth = 0
        var frameHeight = 0
    }

    private var udpSocket: SPPWUDPClientSocket?
    private var controlConnection: NWConnection?
    private var browsers: [String: NWBrowser] = [:]
    private var browseResultsByService: [String: Set<NWBrowser.Result>] = [:]
    private var resolvedHostsByID: [String: (host: String, port: UInt16)] = [:]
    private let bonjourResolver = SPPWBonjourServiceResolver()
    private var discoveryAutoStopTask: Task<Void, Never>?
    private var socketOpenTask: Task<Void, Never>?
    private var connectAttemptGeneration: UInt64 = 0
    private var isOpeningSocket = false
    private let controlQueue = DispatchQueue(label: "com.pyrowavecast.ios.receiver.control", qos: .userInteractive)
    private var controlStreamID: UInt32 = 0
    /// Single unified lock protecting all background packet-assembly state
    /// (`assembler`, `adaptiveBuffer`, `mediaStreamID`, `lastServerActivityNanos`,
    /// and byte/fragment counters) so each UDP packet
    /// acquires at most ONE lock and queries the kernel clock at most ONCE.
    private let assemblyLock = NSLock()
    nonisolated(unsafe) private var mediaStreamID: UInt32 = 0
    nonisolated(unsafe) private var assembler = IOSReceiverFrameAssembler()
    nonisolated(unsafe) private var adaptiveBuffer = SPPWAdaptiveWiFiBuffer(mode: .wifiResilient)
    private let audioPlayer = SPPWAudioPlayer()
    /// Lip-sync timeline: video presentation feeds it, audio playout follows it.
    private let avSyncClock = SPPWAVSyncClock()
    nonisolated(unsafe) private var decoder: IOSReceiverDecoder!
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var abrTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var abrController = SPPWAdaptiveBitrateController()
    private var abrPrevCompleteFrames = 0
    private var abrPrevLLDroppedFrames = 0
    private var abrPrevExpiredFrames = 0
    private var abrPrevPartialHFFrames = 0
    private var abrPrevFECRecoveredFrames = 0
    private var abrPrevLateDroppedFrames = 0
    private var activeEndpoint: NWEndpoint?
    private var shouldAutoReconnect = false
    private var reconnectDeadlineNanos: UInt64?
    private var reconnectAttempt = 0
    private var resyncStartedAt: PyrowaveClock.Instant?
    private var connectStartedNanos: UInt64 = 0
    nonisolated(unsafe) private var lastServerActivityNanos: UInt64 = 0
    private var lastGoodFrameAt: PyrowaveClock.Instant?
    private var lastResyncAt: PyrowaveClock.Instant?
    private var lastFrameID: UInt32 = 0
    private var hasReceivedFrame = false
    /// When the receiver started waiting for a first frame (server hello or resync).
    private var frameWaitStartedAt: PyrowaveClock.Instant?
    private var lastDecodeErrorLogged = ""
    private var localCompleteFrames = 0
    private var localDecodedFrames = 0
    private var localDroppedFrames = 0
    private var lastUIDecodeStatNanos: UInt64 = 0
    nonisolated(unsafe) private var byteWindowStartNanos: UInt64 = 0
    nonisolated(unsafe) private var lastStatFlushNanos: UInt64 = 0
    nonisolated(unsafe) private var windowBytes = 0
    nonisolated(unsafe) private var pendingFragments = 0
    nonisolated(unsafe) private var bgCompleteFrames = 0
    nonisolated(unsafe) private var bgFrameWidth = 0
    nonisolated(unsafe) private var bgFrameHeight = 0
    private var isResynchronizing = false

    init() {
        adaptiveBuffer.mode = latencyMode
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        byteWindowStartNanos = nowNanos
        lastStatFlushNanos = nowNanos
        loadFavorites()
        audioPlayer.syncClock = avSyncClock
        decoder = IOSReceiverDecoder(
            outputHandler: { [weak self] decoded in self?.receive(decoded) },
            errorHandler: { [weak self] frameID, message in self?.receiveDecodeError(frameID: frameID, message: message) }
        )
    }

    var isConnected: Bool { udpSocket != nil || controlConnection != nil || reconnectTask != nil || isOpeningSocket }

    private static let favoritesStorageKey = "iosReceiverFavoriteServers"

    var isCurrentHostFavorite: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let portValue = UInt16(portText) else { return false }
        return favorites.contains { $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame && $0.port == portValue }
    }

    func addFavorite(name: String? = nil) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let portValue = UInt16(portText), portValue > 0 else { return }
        let label = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? trimmedHost
        let entry = FavoriteServer(name: label, host: trimmedHost, port: portValue)
        if let index = favorites.firstIndex(where: { $0.id == entry.id }) {
            favorites[index] = entry
        } else {
            favorites.append(entry)
        }
        saveFavorites()
        appendEvent("Saved favorite: \(entry.name) (\(entry.host):\(entry.port))")
    }

    func toggleCurrentFavorite() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let portValue = UInt16(portText) else { return }
        if let index = favorites.firstIndex(where: { $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame && $0.port == portValue }) {
            let removed = favorites.remove(at: index)
            saveFavorites()
            appendEvent("Removed favorite: \(removed.name)")
        } else {
            let matched = discoveredServers.first {
                $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame && $0.port == portValue
            }
            addFavorite(name: matched?.name)
        }
    }

    func removeFavorite(_ favorite: FavoriteServer) {
        favorites.removeAll { $0.id == favorite.id }
        saveFavorites()
    }

    func selectFavorite(_ favorite: FavoriteServer, connectImmediately: Bool = false) {
        host = favorite.host
        portText = String(favorite.port)
        if connectImmediately {
            connect()
        }
    }

    func selectDiscovered(_ server: DiscoveredServer, connectImmediately: Bool = false) {
        host = server.host
        portText = String(server.port)
        if connectImmediately {
            connect(endpoint: server.endpoint)
        }
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: Self.favoritesStorageKey),
              let decoded = try? JSONDecoder().decode([FavoriteServer].self, from: data) else {
            return
        }
        favorites = decoded
    }

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: Self.favoritesStorageKey)
    }

    func startDiscovery() {
        stopDiscovery()
        let serviceTypes = ["_pyrowavecast._udp", "_pyrowave._udp"]
        isDiscovering = true

        for serviceType in serviceTypes {
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let newBrowser = NWBrowser(for: descriptor, using: parameters)
            browsers[serviceType] = newBrowser

            newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
                Task { @MainActor in
                    guard let self, let newBrowser, self.browsers[serviceType] === newBrowser else { return }
                    switch state {
                    case .ready:
                        if !self.isDiscovering {
                            self.isDiscovering = true
                        }
                    case .failed, .cancelled:
                        self.browsers.removeValue(forKey: serviceType)
                        self.browseResultsByService.removeValue(forKey: serviceType)
                        self.rebuildDiscoveredServers()
                        if self.browsers.isEmpty && self.isDiscovering {
                            self.isDiscovering = false
                        }
                    default:
                        break
                    }
                }
            }

            newBrowser.browseResultsChangedHandler = { [weak self, weak newBrowser] results, _ in
                Task { @MainActor in
                    guard let self, let newBrowser, self.browsers[serviceType] === newBrowser else { return }
                    self.browseResultsByService[serviceType] = results
                    self.rebuildDiscoveredServers()
                }
            }

            newBrowser.start(queue: .main)
        }

        // Bound active mDNS/AWDL browsing to a 12 s window so idle receivers
        // consume 0% CPU while keeping discovered servers selectable in the list.
        discoveryAutoStopTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            self?.stopDiscovery()
        }
    }

    func stopDiscovery() {
        discoveryAutoStopTask?.cancel()
        discoveryAutoStopTask = nil
        for browser in browsers.values {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browsers.removeAll()
        browseResultsByService.removeAll()
        bonjourResolver.cancelAll()
        if isDiscovering {
            isDiscovering = false
        }
    }

    private func rebuildDiscoveredServers() {
        let orderedServiceTypes = ["_pyrowavecast._udp", "_pyrowave._udp"]
        var dedupedByEndpointKey: [String: DiscoveredServer] = [:]

        for serviceType in orderedServiceTypes {
            guard let results = browseResultsByService[serviceType] else { continue }
            for result in results {
                guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                var port: UInt16 = 9888
                var resolvedHost = SPPWNetworkInterface.sanitizedMDNSHostname(serviceName: name, domain: domain)
                if case let .bonjour(txtRecord) = result.metadata {
                    if let portStr = txtRecord["port"], let parsedPort = UInt16(portStr), parsedPort > 0 {
                        port = parsedPort
                    }
                    let txtHostCandidate = txtRecord["ip"] ?? txtRecord["host"]
                    if let txtHost = txtHostCandidate, !txtHost.isEmpty {
                        if txtHost.hasSuffix(".local") || txtHost.contains(".") || txtHost.contains(":") {
                            resolvedHost = txtHost
                        } else {
                            resolvedHost = SPPWNetworkInterface.sanitizedMDNSHostname(serviceName: txtHost, domain: domain)
                        }
                    }
                }

                let dedupeKey = "\(resolvedHost.lowercased()):\(port)"
                // Prefer `_pyrowavecast._udp` when the same server advertises both service types.
                if dedupedByEndpointKey[dedupeKey] != nil {
                    continue
                }

                let id = "\(name)@\(resolvedHost):\(port)"
                if let cached = resolvedHostsByID[id] {
                    if Self.isIPv4Address(cached.host) || !Self.isIPv4Address(resolvedHost) {
                        resolvedHost = cached.host
                        port = cached.port
                    }
                }

                dedupedByEndpointKey[dedupeKey] = DiscoveredServer(
                    id: id,
                    name: name,
                    host: resolvedHost,
                    port: port,
                    endpoint: result.endpoint
                )

                // Only resolve via NetService when TXT did not already provide a concrete IPv4 address.
                if !Self.isIPv4Address(resolvedHost) {
                    resolveBonjourEndpointIfNeeded(
                        result.endpoint,
                        id: id,
                        name: name,
                        type: type,
                        domain: domain,
                        fallbackPort: port
                    )
                }
            }
        }

        var updated = Array(dedupedByEndpointKey.values)
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if discoveredServers != updated {
            discoveredServers = updated
        }
    }

    private func resolveBonjourEndpointIfNeeded(
        _ endpoint: NWEndpoint,
        id: String,
        name: String,
        type: String,
        domain: String,
        fallbackPort: UInt16
    ) {
        bonjourResolver.resolve(
            id: id,
            name: name,
            type: type,
            domain: domain,
            timeout: 5.0
        ) { [weak self] resolved in
            guard let resolved else { return }
            let rawHost = Self.cleanResolvedHost(resolved.host)
            let portValue = resolved.port > 0 ? resolved.port : fallbackPort
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let index = self.discoveredServers.firstIndex(where: { $0.id == id }) {
                    let existingHost = self.discoveredServers[index].host
                    let shouldReplace = Self.isIPv4Address(rawHost) || !Self.isIPv4Address(existingHost)
                    if shouldReplace {
                        self.resolvedHostsByID[id] = (host: rawHost, port: portValue)
                        let updated = DiscoveredServer(
                            id: id,
                            name: name,
                            host: rawHost,
                            port: portValue,
                            endpoint: endpoint
                        )
                        if self.discoveredServers[index] != updated {
                            self.discoveredServers[index] = updated
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func isIPv4Address(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    private nonisolated static func isLinkLocalIPv6(_ host: String) -> Bool {
        host.lowercased().hasPrefix("fe80:")
    }

    private nonisolated static func cleanResolvedHost(_ raw: String) -> String {
        // Preserve interface scope (`%en0`) on link-local IPv6 addresses so POSIX UDP sockets can route them.
        if isLinkLocalIPv6(raw) {
            return raw
        }
        if let percentIndex = raw.firstIndex(of: "%") {
            return String(raw[..<percentIndex])
        }
        return raw
    }

    func connect(endpoint: NWEndpoint? = nil) {
        stopDiscovery()
        teardownActiveConnection(clearAutoReconnect: true)
        activeEndpoint = endpoint
        shouldAutoReconnect = true
        reconnectDeadlineNanos = nil
        reconnectAttempt = 0
        // No auto-lock while connected (also across automatic reconnects).
        IOSKeepAwake.shared.acquire(.receiver)
        openConnection(endpoint: endpoint, isReconnectAttempt: false)
    }

    private func openConnection(endpoint: NWEndpoint?, isReconnectAttempt: Bool) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = UInt16(portText) ?? 0

        if endpoint == nil {
            guard !trimmedHost.isEmpty, portValue > 0 else {
                shouldAutoReconnect = false
                state = .failed(SPPWLocalization.tr("receiver.error.invalid_host_port"))
                return
            }
            UserDefaults.standard.set(trimmedHost, forKey: "iosReceiverHost")
            UserDefaults.standard.set(Int(portValue), forKey: "iosReceiverPort")
        }

        if !isReconnectAttempt {
            state = .connecting
            lastError = nil
            connectStartedNanos = DispatchTime.now().uptimeNanoseconds
        }

        // Prefer a direct POSIX UDP socket with 2 MB SO_RCVBUF and DSCP CS4
        // on iOS Wi-Fi whenever we have a resolved host and port. Run `getaddrinfo()`
        // off the main thread so slow LAN DNS / `.local` resolution never freezes UI.
        var targetHost = trimmedHost
        var targetPort = portValue
        if let endpoint,
           let matched = discoveredServers.first(where: { $0.endpoint == endpoint }),
           !matched.host.isEmpty {
            targetHost = matched.host
            targetPort = matched.port
        }

        if !targetHost.isEmpty, targetPort > 0 {
            connectAttemptGeneration &+= 1
            let generation = connectAttemptGeneration
            let resolvedTargetHost = targetHost
            let resolvedTargetPort = targetPort
            let fallbackEndpoint = endpoint
            let fallbackHost = trimmedHost
            let fallbackPort = portValue
            let sendBuf = SPPWSocketBufferTuning.defaultSendBufferBytes
            let recvBuf = SPPWSocketBufferTuning.defaultReceiveBufferBytes
            isOpeningSocket = true
            socketOpenTask?.cancel()
            socketOpenTask = Task.detached(priority: .userInitiated) { [weak self] in
                let clientSocket = try? SPPWUDPClientSocket(
                    host: resolvedTargetHost,
                    port: resolvedTargetPort,
                    sendBufferBytes: sendBuf,
                    receiveBufferBytes: recvBuf
                )
                await MainActor.run {
                    guard let self else {
                        clientSocket?.stop()
                        return
                    }
                    guard self.connectAttemptGeneration == generation, !Task.isCancelled else {
                        clientSocket?.stop()
                        return
                    }
                    self.isOpeningSocket = false
                    self.socketOpenTask = nil
                    if let clientSocket {
                        self.attachUDPSocket(clientSocket)
                    } else {
                        self.openNWConnectionFallback(
                            endpoint: fallbackEndpoint,
                            trimmedHost: fallbackHost,
                            portValue: fallbackPort
                        )
                    }
                }
            }
            return
        }

        openNWConnectionFallback(endpoint: endpoint, trimmedHost: trimmedHost, portValue: portValue)
    }

    private func attachUDPSocket(_ clientSocket: SPPWUDPClientSocket) {
        udpSocket = clientSocket
        clientSocket.start(
            datagramHandler: { [weak self] data in
                self?.handleDatagramBackground(data)
            },
            errorHandler: { [weak self] err in
                Task { @MainActor [weak self] in
                    guard let self, self.udpSocket === clientSocket else { return }
                    if self.shouldAutoReconnect {
                        self.triggerAutoReconnect(reason: "Ricezione UDP interrotta: \(err.localizedDescription)")
                    }
                }
            }
        )
        if reconnectTask == nil {
            state = .waiting
        }
        let hello = IOSReceiverWireHeader.control(.clientHello, payload: makeConfiguration().payload)
        send(hello)
        startHelloRetryLoop()
        if reconnectAttempt == 0 {
            appendEvent("Control link ready (SO_RCVBUF=\(clientSocket.tuning.actualReceiveBytes / 1024)KB, DSCP=CS4) · sent SPPW/1 hello")
        }
    }

    private func openNWConnectionFallback(endpoint: NWEndpoint?, trimmedHost: String, portValue: UInt16) {
        let connection: NWConnection
        if let endpoint {
            connection = NWConnection(to: endpoint, using: .sppwInteractiveVideo())
        } else if let port = NWEndpoint.Port(rawValue: portValue) {
            connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: port, using: .sppwInteractiveVideo())
        } else {
            shouldAutoReconnect = false
            state = .failed(SPPWLocalization.tr("receiver.error.invalid_host_port"))
            return
        }
        controlConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            Task { @MainActor in
                guard let self, let connection, self.controlConnection === connection else { return }
                self.handleControlState(newState)
            }
        }
        connection.start(queue: controlQueue)
        receiveNext(on: connection)
    }

    func disconnect() {
        teardownActiveConnection(clearAutoReconnect: true)
        state = .disconnected
        appendEvent("Disconnected")
    }

    private func teardownActiveConnection(clearAutoReconnect: Bool) {
        connectAttemptGeneration &+= 1
        socketOpenTask?.cancel()
        socketOpenTask = nil
        isOpeningSocket = false
        if clearAutoReconnect {
            IOSKeepAwake.shared.release(.receiver)
            shouldAutoReconnect = false
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectDeadlineNanos = nil
            reconnectAttempt = 0
            activeEndpoint = nil
            serverControlledResolution = false
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        abrTask?.cancel()
        abrTask = nil
        activeAutoBitrateMbps = 0
        udpSocket?.stop()
        udpSocket = nil
        let connection = controlConnection
        controlConnection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        audioPlayer.stop()
        avSyncClock.reset()
        clipboardSession.stop()
        controlStreamID = 0
        lastFrameID = 0
        hasReceivedFrame = false
        frameWaitStartedAt = nil
        lastDecodeErrorLogged = ""
        localCompleteFrames = 0
        localDecodedFrames = 0
        localDroppedFrames = 0
        lastGoodFrameAt = nil
        resyncStartedAt = nil
        isResynchronizing = false
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        assemblyLock.lock()
        mediaStreamID = 0
        assembler.reset()
        adaptiveBuffer.reset()
        bgCompleteFrames = 0
        bgFrameWidth = 0
        bgFrameHeight = 0
        pendingFragments = 0
        windowBytes = 0
        byteWindowStartNanos = nowNanos
        lastStatFlushNanos = nowNanos
        assemblyLock.unlock()
        if clearAutoReconnect {
            currentPixelBuffer = nil
        }
        // During an automatic reconnect the last picture stays (frozen) until the
        // new session delivers a frame, instead of flashing to black.
        let activeDecoder = decoder
        Task { await activeDecoder?.reset() }
    }

    func clearEvents() { events.removeAll() }

    /// Sends an input event to the macOS host. Discrete events (keys, text, clicks) are wrapped in
    /// `.sequenced` and sent twice, 12 ms apart; the server applies each sequence number once.
    func sendInputEvent(_ event: SPPWInputEvent) {
        guard (udpSocket != nil || controlConnection != nil), controlStreamID != 0 else { return }
        guard SPPWInputSequencer.needsRedundancy(event) else {
            send(IOSReceiverWireHeader.control(.input, streamID: controlStreamID, payload: event.encode()))
            return
        }
        let datagram = IOSReceiverWireHeader.control(
            .input,
            streamID: controlStreamID,
            payload: inputSequencer.wrap(event).encode()
        )
        send(datagram)
        let streamID = controlStreamID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(12)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.controlStreamID == streamID else { return }
                self.send(datagram)
            }
        }
    }

    /// Whether the Mac should leave its cursor out of the video (set by the fullscreen view).
    /// Resent with every heartbeat while hidden and after each `serverHello`: the server
    /// forgets it per session and plain UDP may lose both redundant copies.
    private(set) var remoteCursorHidden = false

    func setRemoteCursorHidden(_ hidden: Bool) {
        guard hidden != remoteCursorHidden else { return }
        remoteCursorHidden = hidden
        sendInputEvent(.cursorVisibility(hidden: hidden))
    }

    // MARK: Receiver-drawn pointer

    /// Pointer drawn by the fullscreen view and sent to the Mac as absolute positions, so it
    /// shows exactly where the Mac clicks with no video delay (the Mac cursor stays out of
    /// the video). Starts in the middle of the remote screen.
    private(set) var localPointer = SPPWLocalPointer()
    /// Fires on every pointer change; not `@Published`, so SwiftUI does not re-render at 120 Hz.
    let localPointerSubject = PassthroughSubject<SPPWLocalPointer, Never>()
    /// Size of the displayed (unzoomed) video in its own axes, set by the fullscreen view on
    /// layout. Relative motion is measured against it.
    var pointerViewport: (width: Double, height: Double)?

    /// Default trackpad gain (`SPPWPointerAcceleration` at speed 5, slow moves): divided out so
    /// a slow swipe across the shown picture crosses the remote screen once at the default speed.
    private static let pointerGainReference = 1.85

    /// Relative motion (trackpad swipe, iPad mouse), already rotated into the video's axes
    /// and accelerated: moves the local pointer and the Mac's.
    func moveLocalPointer(videoDX: Double, videoDY: Double) {
        guard let viewport = pointerViewport else { return }
        var pointer = localPointer
        pointer.move(
            videoDX: videoDX / Self.pointerGainReference,
            videoDY: videoDY / Self.pointerGainReference,
            displayedVideoWidth: viewport.width,
            displayedVideoHeight: viewport.height
        )
        guard pointer != localPointer else { return }
        localPointer = pointer
        sendInputEvent(pointer.moveEvent)
        localPointerSubject.send(pointer)
    }

    /// Direct touch: the finger is the pointer (the touch event itself moves the Mac's).
    func placeLocalPointer(normalizedX: Double, normalizedY: Double) {
        let pointer = SPPWLocalPointer(normalizedX: normalizedX, normalizedY: normalizedY)
        guard pointer != localPointer else { return }
        localPointer = pointer
        localPointerSubject.send(pointer)
    }

    /// Sends the local pointer's position before a click at the cursor, so a lost motion
    /// datagram can never make the click land somewhere else than where the pointer is drawn.
    func syncLocalPointerToRemote() {
        sendInputEvent(localPointer.moveEvent)
    }

    /// Committed keyboard text (after IME composition) with the sticky modifiers applied once.
    func sendTypedText(_ text: String) {
        let modifiers = stickyModifiers.consume()
        for event in SPPWKeyboardTranslator.events(forCommittedText: text, modifiers: modifiers) {
            sendInputEvent(event)
        }
    }

    func sendDeleteBackward() {
        sendInputEvent(SPPWKeyboardTranslator.deleteBackward(modifiers: stickyModifiers.consume()))
    }

    func sendSpecialKey(_ key: SPPWSpecialKey) {
        sendInputEvent(key.event(adding: stickyModifiers.consume()))
    }

    /// Hardware keyboard key (macOS key code) with the device's own modifiers plus sticky ones.
    func sendHardwareKey(keyCode: UInt16, isDown: Bool, modifiers: SPPWKeyModifiers) {
        let combined = isDown ? modifiers.union(stickyModifiers.consume()) : modifiers
        sendInputEvent(.key(keyCode: keyCode, isDown: isDown, modifiers: combined.rawValue))
    }

    /// Sends the item the user explicitly pasted into the dock's paste control to the Mac.
    func sendClipboardToHost(_ content: SPPWClipboardContent) {
        guard controlStreamID != 0 else { return }
        if clipboardSession.offer(content) {
            appendEvent("Appunti inviati al Mac (\(content.format == .png ? "immagine" : "testo"), \(content.data.count) B)")
        }
    }

    func sendTouch(phase: UInt8, normalizedX: Float, normalizedY: Float, id: UInt32 = 0) {
        sendInputEvent(.touch([SPPWTouchPoint(id: id, phase: phase, normalizedX: normalizedX, normalizedY: normalizedY)]))
    }

    func applySettings() {
        resetAdaptiveBitrate(nowNanos: DispatchTime.now().uptimeNanoseconds)
        let config = makeConfiguration()
        guard (udpSocket != nil || controlConnection != nil), controlStreamID != 0 else {
            appendEvent("Settings saved: \(config.width)x\(config.height) @ \(config.fps) fps")
            return
        }
        startAdaptiveBitrateLoop()
        send(IOSReceiverWireHeader.control(.streamConfiguration, streamID: controlStreamID, payload: config.payload))
        state = .waiting
        appendEvent("Configuration sent: \(config.width)x\(config.height) @ \(config.fps) fps, FEC \(config.fec)%")
    }

    private func handleControlState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            if reconnectTask == nil {
                state = .waiting
            }
            let hello = IOSReceiverWireHeader.control(.clientHello, payload: makeConfiguration().payload)
            send(hello)
            startHelloRetryLoop()
            if reconnectAttempt == 0 {
                appendEvent("Control link ready · sent SPPW/1 hello")
            }
        case .failed(let error), .waiting(let error):
            lastError = error.localizedDescription
            if shouldAutoReconnect {
                triggerAutoReconnect(reason: "Link interrotto: \(error.localizedDescription)")
            } else {
                state = .failed(error.localizedDescription)
                appendEvent("Control link: \(error.localizedDescription)")
            }
        case .cancelled:
            if !shouldAutoReconnect && state != .disconnected { state = .disconnected }
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private nonisolated func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data {
                self.handleDatagramBackground(data)
            }
            if let error {
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection, self.controlConnection === connection else { return }
                    if self.shouldAutoReconnect {
                        self.triggerAutoReconnect(reason: "Ricezione UDP interrotta: \(error.localizedDescription)")
                    }
                }
            } else {
                self.receiveNext(on: connection)
            }
        }
    }

    private nonisolated func noteServerActivity(_ nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        assemblyLock.lock()
        lastServerActivityNanos = nowNanos
        assemblyLock.unlock()
    }

    private nonisolated func secondsSinceLastServerActivity() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        assemblyLock.lock()
        let last = lastServerActivityNanos
        assemblyLock.unlock()
        guard last > 0, now >= last else { return 0 }
        return Double(now - last) / 1_000_000_000.0
    }

    private nonisolated func handleDatagramBackground(_ data: Data) {
        guard let header = IOSReceiverWireHeader(data) else { return }
        let arrivalNanos = DispatchTime.now().uptimeNanoseconds

        switch header.kind {
        case .serverHello, .streamConfiguration, .ping:
            noteServerActivity(arrivalNanos)
            Task { @MainActor [weak self] in self?.handleControlDatagram(data, header: header) }

        case .pong:
            noteServerActivity(arrivalNanos)

        case .clipboard:
            noteServerActivity(arrivalNanos)
            let payload = data.count > IOSReceiverWireHeader.byteCount
                ? data.subdata(in: IOSReceiverWireHeader.byteCount..<data.count)
                : Data()
            if let content = clipboardSession.receive(payload) {
                Task { @MainActor [weak self] in
                    IOSClipboardBridge.write(content)
                    self?.appendEvent("Appunti dal Mac (\(content.format == .png ? "immagine" : "testo"), \(content.data.count) B)")
                }
            }

        case .audioFrame:
            noteServerActivity(arrivalNanos)
            let payload = data.count > IOSReceiverWireHeader.byteCount
                ? data.subdata(in: IOSReceiverWireHeader.byteCount..<data.count)
                : Data()
            audioPlayer.enqueue(audioPayload: payload, senderTimestampNanoseconds: header.timestampNanoseconds)

        case .frameFragment, .fecParity:
            assemblyLock.lock()
            lastServerActivityNanos = arrivalNanos
            if mediaStreamID != 0, header.streamID != 0, header.streamID != mediaStreamID {
                mediaStreamID = header.streamID
            }

            let timeoutMs = adaptiveBuffer.recommendedTimeoutMs(fps: 60)
            let frame = assembler.ingest(
                data,
                parsedHeader: header,
                timeoutMilliseconds: timeoutMs,
                allowPartialHFDecode: true
            )
            if let frame {
                adaptiveBuffer.recordFrameArrival(
                    senderTimestampNanos: frame.senderTimestampNanoseconds,
                    arrivalUptimeNanos: arrivalNanos
                )
            }

            windowBytes += data.count
            pendingFragments += 1
            var dimensionsChanged = false
            if let frame {
                bgCompleteFrames += 1
                if bgFrameWidth != frame.width || bgFrameHeight != frame.height {
                    bgFrameWidth = frame.width
                    bgFrameHeight = frame.height
                    dimensionsChanged = true
                }
            }

            var receivedMbps: Double = 0
            if arrivalNanos >= byteWindowStartNanos &+ 1_000_000_000 {
                let elapsedSec = Double(arrivalNanos - byteWindowStartNanos) / 1_000_000_000.0
                receivedMbps = Double(windowBytes * 8) / elapsedSec / 1_000_000.0
                windowBytes = 0
                byteWindowStartNanos = arrivalNanos
            }

            // Throttle UI statistics tasks to ~2 Hz (every 500 ms) or on resolution change.
            let shouldFlushStats = dimensionsChanged
                || receivedMbps > 0
                || (arrivalNanos >= lastStatFlushNanos &+ 500_000_000)

            var flushedFragments = 0
            var totalComplete = 0
            var currentW = 0
            var currentH = 0
            var expired = 0
            var llDropped = 0
            var fecFrames = 0
            var fecPackets = 0
            var partialHF = 0
            var jitterMs = 0.0

            if shouldFlushStats {
                flushedFragments = pendingFragments
                pendingFragments = 0
                lastStatFlushNanos = arrivalNanos
                totalComplete = bgCompleteFrames
                currentW = bgFrameWidth
                currentH = bgFrameHeight
                expired = assembler.expiredFrames
                llDropped = assembler.llDroppedFrames
                fecFrames = assembler.fecRecoveredFrames
                fecPackets = assembler.fecRecoveredPackets
                partialHF = assembler.partialHFFrames
                jitterMs = adaptiveBuffer.jitterMilliseconds
            }
            assemblyLock.unlock()

            if let frame {
                let activeDecoder = decoder
                Task { await activeDecoder?.submit(frame) }
            }

            if shouldFlushStats {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.localCompleteFrames = totalComplete
                    // Mutate a local copy and assign once so `@Published var statistics`
                    // fires `objectWillChange` only ONCE per 500 ms instead of 11 times.
                    var updated = self.statistics
                    updated.fragments += flushedFragments
                    if receivedMbps > 0 { updated.receivedMbps = receivedMbps }
                    updated.expiredFrames = expired
                    updated.llDroppedFrames = llDropped
                    updated.fecRecoveredFrames = fecFrames
                    updated.fecRecoveredPackets = fecPackets
                    updated.partialHFFrames = partialHF
                    updated.jitterMilliseconds = jitterMs
                    updated.completeFrames = totalComplete
                    if currentW > 0 && currentH > 0 {
                        updated.frameWidth = currentW
                        updated.frameHeight = currentH
                    }
                    if self.statistics != updated {
                        self.statistics = updated
                    }
                }
            }

        case .clientHello, .input:
            break
        }
    }

    @MainActor
    private func handleControlDatagram(_ data: Data, header: IOSReceiverWireHeader) {
        let payload = data.count > IOSReceiverWireHeader.byteCount
            ? Data(data.dropFirst(IOSReceiverWireHeader.byteCount))
            : Data()
        switch header.kind {
        case .serverHello:
            let wasReconnecting = reconnectTask != nil || reconnectAttempt > 0
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectDeadlineNanos = nil
            reconnectAttempt = 0
            lastError = nil

            controlStreamID = header.streamID
            isResynchronizing = false
            resyncStartedAt = nil
            state = .waiting
            lastFrameID = 0
            hasReceivedFrame = false
            frameWaitStartedAt = PyrowaveClock.now
            lastDecodeErrorLogged = ""
            var parsedMediaID: UInt32 = 0
            if payload.count >= 4 {
                parsedMediaID = UInt32(payload[0]) << 24
                    | UInt32(payload[1]) << 16
                    | UInt32(payload[2]) << 8
                    | UInt32(payload[3])
            }
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            assemblyLock.lock()
            assembler.reset()
            adaptiveBuffer.reset()
            bgCompleteFrames = 0
            bgFrameWidth = 0
            bgFrameHeight = 0
            pendingFragments = 0
            windowBytes = 0
            byteWindowStartNanos = nowNanos
            lastStatFlushNanos = nowNanos
            lastServerActivityNanos = nowNanos
            if parsedMediaID != 0 {
                mediaStreamID = parsedMediaID
            }
            assemblyLock.unlock()

            if payload.count >= 6 {
                let serverTimeout = Int(UInt16(payload[4]) << 8 | UInt16(payload[5]))
                if (5...120).contains(serverTimeout) {
                    agreedTimeoutSeconds = serverTimeout
                }
            }
            let serverDrivesResolution = (header.flags & 1) != 0
            serverControlledResolution = serverDrivesResolution
            if header.width > 0 && header.height > 0 {
                let serverW = Int(header.width)
                let serverH = Int(header.height)
                noteServerStreamSize(width: serverW, height: serverH)
                var updated = statistics
                updated.frameWidth = serverW
                updated.frameHeight = serverH
                statistics = updated
                appendEvent("Risoluzione concordata: \(serverW)×\(serverH) (\(resolutionMode.title))")
            }
            resetAdaptiveBitrate(nowNanos: nowNanos)
            startHeartbeat()
            startWatchdog()
            startAdaptiveBitrateLoop()
            sendReadinessPing()
            startClipboardSession()
            if remoteCursorHidden {
                sendInputEvent(.cursorVisibility(hidden: true))
            }
            if wasReconnecting {
                appendEvent("Riconnesso automaticamente · sessione \(controlStreamID), media \(mediaStreamID), timeout \(agreedTimeoutSeconds)s")
            } else {
                appendEvent("Server hello · control session \(controlStreamID), media stream \(mediaStreamID), timeout \(agreedTimeoutSeconds)s")
            }

        case .streamConfiguration:
            let serverDrivesResolution = (header.flags & 1) != 0
            serverControlledResolution = serverDrivesResolution
            if header.width > 0 && header.height > 0 {
                let serverW = Int(header.width)
                let serverH = Int(header.height)
                if width != serverW || height != serverH {
                    noteServerStreamSize(width: serverW, height: serverH)
                    appendEvent("Risoluzione stream: \(serverW)×\(serverH) (\(resolutionMode.title))")
                }
            }
            if isResynchronizing {
                isResynchronizing = false
                resyncStartedAt = nil
                appendEvent("Configuration acknowledged")
            }

        case .ping:
            send(IOSReceiverWireHeader.control(.pong, streamID: controlStreamID))

        default:
            break
        }
    }

    private func sendReadinessPing() {
        send(IOSReceiverWireHeader.control(
            .ping,
            streamID: controlStreamID,
            payload: Data("READY".utf8)
        ))
    }

    /// What goes on the wire for the current resolution mode: `0×0` native, `0×S` short side.
    private func requestedResolution(fps: Int, quality: Double, manualBitrateMbps: Double) -> (width: Int, height: Int) {
        switch resolutionMode {
        case .native:
            return (0, 0)
        case .shortSide(let lines):
            return (0, lines)
        case .automatic:
            if !automaticBitrate {
                let best = SPPWAutoResolutionController.bestShortSide(
                    bitrateBps: Int(manualBitrateMbps * 1_000_000),
                    fps: fps,
                    quality: quality,
                    native: nativeSize ?? (width, height)
                )
                if best != autoResolution.shortSide {
                    autoResolution.reset(shortSide: best)
                }
            }
            return autoResolution.shortSide.map { (0, $0) } ?? (0, 0)
        }
    }

    private func makeConfiguration() -> IOSReceiverWireSettings {
        let safeFPS = max(1, min(fps, 120))
        let safeQuality = max(0.1, min(1.0, quality))
        let safeBitrate = max(5.0, min(1000.0, bitrateMbps))
        let safeFEC = max(0, min(50, fecPercent))
        let request = requestedResolution(fps: safeFPS, quality: safeQuality, manualBitrateMbps: safeBitrate)
        let expected = SPPWResolutionLadder.resolve(
            requestedWidth: request.width,
            requestedHeight: request.height,
            native: nativeSize ?? (max(width, 320), max(height, 240))
        )
        let safeWidth = expected.width
        let safeHeight = expected.height
        UserDefaults.standard.set(safeFPS, forKey: "iosReceiverFPS")
        UserDefaults.standard.set(safeQuality, forKey: "iosReceiverQuality")
        UserDefaults.standard.set(safeBitrate, forKey: "iosReceiverBitrate")
        UserDefaults.standard.set(automaticBitrate, forKey: "iosReceiverAutomaticBitrate")
        UserDefaults.standard.set(safeFEC, forKey: "iosReceiverFECPercent")
        let effectiveBitrateBps: UInt32
        if automaticBitrate {
            let ceiling = SPPWAdaptiveBitrateController.recommendedCeilingBitrateBps(
                width: safeWidth,
                height: safeHeight,
                fps: safeFPS,
                quality: safeQuality
            )
            if abrController.maxCeilingBitrateBps != ceiling {
                abrController.reset(ceilingBitrateBps: ceiling, nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
            }
            activeAutoBitrateMbps = Double(abrController.currentBitrateBps) / 1_000_000.0
            effectiveBitrateBps = UInt32(clamping: abrController.currentBitrateBps)
        } else {
            effectiveBitrateBps = UInt32(safeBitrate * 1_000_000)
        }
        return IOSReceiverWireSettings(
            width: UInt16(clamping: request.width),
            height: UInt16(clamping: request.height),
            fps: UInt16(safeFPS),
            automaticBitrate: automaticBitrate,
            latencyMode: latencyMode.rawValue,
            bitrate: effectiveBitrateBps,
            quality: UInt16(safeQuality * 10_000),
            fec: UInt16(safeFEC),
            mtu: 1200,
            frameTimeout: 35,
            bufferedFrames: latencyMode == .ultraLow ? 0 : 1
        )
    }

    func noteDisplayError(_ message: String) {
        appendEvent("Display: \(message)")
    }

    private func receive(_ decoded: IOSDecodedReceiverFrame) {
        assemblyLock.lock()
        let maxAge = adaptiveBuffer.maxAcceptableAgeMs
        assemblyLock.unlock()
        guard decoded.ageMilliseconds <= maxAge || !decoded.isSuperseded else {
            localDroppedFrames += 1
            return
        }
        // Pass the CVPixelBuffer directly to AVSampleBufferDisplayLayer via
        // pixelBufferSubject (without firing ObservableObject.objectWillChange
        // on every frame).
        currentPixelBuffer = decoded.pixelBuffer
        avSyncClock.noteVideoPresented(senderCaptureNanos: decoded.senderTimestampNanoseconds)
        if state != .streaming {
            state = .streaming
        }
        lastGoodFrameAt = PyrowaveClock.now
        localDecodedFrames += 1
        lastDecodeErrorLogged = ""
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        if nowNanos >= lastUIDecodeStatNanos &+ 500_000_000 || localDecodedFrames == 1 {
            lastUIDecodeStatNanos = nowNanos
            var updated = statistics
            updated.decodedFrames = localDecodedFrames
            updated.completeFrames = max(updated.completeFrames, localCompleteFrames)
            updated.droppedFrames = localDroppedFrames
            updated.decodeMilliseconds = decoded.decodeMilliseconds
            updated.ageMilliseconds = decoded.ageMilliseconds
            statistics = updated
        }
    }

    private func receiveDecodeError(frameID: UInt32, message: String) {
        localDroppedFrames += 1
        statistics.droppedFrames = localDroppedFrames
        lastError = message
        if message != lastDecodeErrorLogged || localDroppedFrames % 30 == 1 {
            lastDecodeErrorLogged = message
            appendEvent("Decode failed for frame \(frameID): \(message)")
        }
    }

    private func startHelloRetryLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, (self.udpSocket != nil || self.controlConnection != nil), self.controlStreamID == 0 else { return }
                if self.reconnectTask == nil {
                    let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds &- self.connectStartedNanos) / 1_000_000_000.0
                    if elapsedSec >= Double(self.agreedTimeoutSeconds) {
                        self.teardownActiveConnection(clearAutoReconnect: true)
                        self.state = .failed(SPPWLocalization.tr("receiver.error.connection_timeout_fmt", self.agreedTimeoutSeconds))
                        self.appendEvent("Nessuna risposta dal server entro \(self.agreedTimeoutSeconds)s")
                        return
                    }
                }
                let hello = IOSReceiverWireHeader.control(.clientHello, payload: self.makeConfiguration().payload)
                self.send(hello)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
                guard let self, (self.udpSocket != nil || self.controlConnection != nil), self.controlStreamID != 0 else { return }
                self.send(IOSReceiverWireHeader.control(
                    .ping,
                    streamID: self.controlStreamID,
                    payload: Data("HB01".utf8)
                ))
                if self.remoteCursorHidden {
                    self.sendInputEvent(.cursorVisibility(hidden: true))
                }
            }
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                guard let self, (self.udpSocket != nil || self.controlConnection != nil), self.controlStreamID != 0 else { return }

                let silenceSeconds = self.secondsSinceLastServerActivity()
                if silenceSeconds >= 6.0 {
                    self.triggerAutoReconnect(reason: "Nessuna risposta dal server da \(Int(silenceSeconds))s")
                    return
                }

                if self.isResynchronizing,
                   let started = self.resyncStartedAt,
                   started.duration(to: PyrowaveClock.now) >= .seconds(3) {
                    self.triggerAutoReconnect(reason: "Resync senza risposta dal server")
                    return
                }

                guard self.mediaStreamID > 0, !self.isResynchronizing else { continue }
                // A stream that never showed its first frame (lost, or a slow start at a
                // high resolution) also asks for the live edge, after a longer grace period.
                guard let reference = self.lastGoodFrameAt ?? self.frameWaitStartedAt else { continue }
                let freshFrameLimit: PyrowaveDuration = self.lastGoodFrameAt != nil ? .seconds(2) : .seconds(4)
                if reference.duration(to: PyrowaveClock.now) > freshFrameLimit {
                    self.requestLiveResync(reason: "No fresh frame; requesting live edge")
                }
            }
        }
    }

    private func resetAdaptiveBitrate(nowNanos: UInt64) {
        let safeW = max(320, min(width, 3840)) & ~1
        let safeH = max(240, min(height, 2160)) & ~1
        let safeFPS = max(1, min(fps, 120))
        let safeQuality = max(0.1, min(1.0, quality))
        let ceiling = SPPWAdaptiveBitrateController.recommendedCeilingBitrateBps(
            width: safeW,
            height: safeH,
            fps: safeFPS,
            quality: safeQuality
        )
        abrController.reset(ceilingBitrateBps: ceiling, nowNanoseconds: nowNanos)
        activeAutoBitrateMbps = automaticBitrate ? Double(abrController.currentBitrateBps) / 1_000_000.0 : 0

        assemblyLock.lock()
        abrPrevCompleteFrames = bgCompleteFrames
        abrPrevLLDroppedFrames = assembler.llDroppedFrames
        abrPrevExpiredFrames = assembler.expiredFrames
        abrPrevPartialHFFrames = assembler.partialHFFrames
        abrPrevFECRecoveredFrames = assembler.fecRecoveredFrames
        assemblyLock.unlock()
        abrPrevLateDroppedFrames = localDroppedFrames
    }

    /// Evaluates network loss/jitter every 1 second when `automaticBitrate` is enabled.
    /// Steps bitrate down every second until stable; probes upward only after >= 10 s clean,
    /// and reverts/locks to the problem-free bitrate if instability persists.
    private func sampleAssemblyStats() -> (Int, Int, Int, Int, Int, Double) {
        assemblyLock.lock()
        defer { assemblyLock.unlock() }
        return (
            bgCompleteFrames,
            assembler.llDroppedFrames,
            assembler.expiredFrames,
            assembler.partialHFFrames,
            assembler.fecRecoveredFrames,
            adaptiveBuffer.jitterMilliseconds
        )
    }

    /// Records the size the server streams; while the request is native it is the server's
    /// native size, which bounds the resolution menu and the automatic levels.
    private func noteServerStreamSize(width serverW: Int, height serverH: Int) {
        width = serverW
        height = serverH
        let requestIsNative: Bool
        switch resolutionMode {
        case .native: requestIsNative = true
        case .automatic: requestIsNative = autoResolution.shortSide == nil
        case .shortSide: requestIsNative = false
        }
        if !serverControlledResolution {
            nativeSize = nil
            nativeShortSide = nil
        } else if requestIsNative {
            nativeSize = (serverW, serverH)
            nativeShortSide = min(serverW, serverH)
        }
    }

    /// Automatic resolution, evaluated every adaptive-bitrate tick (`SPPWAutoResolutionController`).
    private func evaluateAutomaticResolution(nowNanos: UInt64) {
        guard resolutionMode == .automatic, automaticBitrate else { return }
        let change = autoResolution.evaluate(
            currentBitrateBps: abrController.currentBitrateBps,
            ceilingBitrateBps: abrController.maxCeilingBitrateBps,
            nativeShortSide: nativeShortSide ?? SPPWResolutionLadder.maximumHeight,
            now: nowNanos
        )
        guard case .changed(let level) = change else { return }
        let config = makeConfiguration()
        send(IOSReceiverWireHeader.control(.streamConfiguration, streamID: controlStreamID, payload: config.payload))
        appendEvent("Risoluzione automatica: \(level.map(SPPWResolutionMode.levelTitle) ?? SPPWLocalization.tr("settings.resolution_native"))")
    }

    private func startAdaptiveBitrateLoop() {
        abrTask?.cancel()
        abrTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self,
                      (self.udpSocket != nil || self.controlConnection != nil),
                      self.controlStreamID != 0 else { return }
                guard self.automaticBitrate,
                      self.mediaStreamID > 0,
                      !self.isResynchronizing else { continue }

                let nowNanos = DispatchTime.now().uptimeNanoseconds
                let (curComplete, curLLDrop, curExpired, curPartialHF, curFECRecovered, jitterMs) = self.sampleAssemblyStats()
                let curLateDrop = self.localDroppedFrames

                let sample = SPPWAdaptiveBitrateSample(
                    timestampNanoseconds: nowNanos,
                    completeFramesDelta: max(0, curComplete - self.abrPrevCompleteFrames),
                    llDroppedFramesDelta: max(0, curLLDrop - self.abrPrevLLDroppedFrames),
                    expiredFramesDelta: max(0, curExpired - self.abrPrevExpiredFrames),
                    partialHFFramesDelta: max(0, curPartialHF - self.abrPrevPartialHFFrames),
                    fecRecoveredFramesDelta: max(0, curFECRecovered - self.abrPrevFECRecoveredFrames),
                    lateDroppedFramesDelta: max(0, curLateDrop - self.abrPrevLateDroppedFrames),
                    jitterMs: jitterMs
                )
                self.abrPrevCompleteFrames = curComplete
                self.abrPrevLLDroppedFrames = curLLDrop
                self.abrPrevExpiredFrames = curExpired
                self.abrPrevPartialHFFrames = curPartialHF
                self.abrPrevFECRecoveredFrames = curFECRecovered
                self.abrPrevLateDroppedFrames = curLateDrop

                let decision = self.abrController.evaluate(sample)
                defer { self.evaluateAutomaticResolution(nowNanos: nowNanos) }
                switch decision {
                case .hold:
                    break
                case let .stepDown(newBps, reason):
                    self.activeAutoBitrateMbps = Double(newBps) / 1_000_000.0
                    let config = self.makeConfiguration()
                    self.send(IOSReceiverWireHeader.control(.streamConfiguration, streamID: self.controlStreamID, payload: config.payload))
                    self.appendEvent("Auto bitrate: ↓ \(newBps / 1_000_000) Mb/s (\(reason))")
                case let .probeUp(newBps):
                    self.activeAutoBitrateMbps = Double(newBps) / 1_000_000.0
                    let config = self.makeConfiguration()
                    self.send(IOSReceiverWireHeader.control(.streamConfiguration, streamID: self.controlStreamID, payload: config.payload))
                    self.appendEvent("Auto bitrate: ↑ \(newBps / 1_000_000) Mb/s (probe rete stabile ≥10s)")
                case let .revertToStable(newBps, lockedCeiling, reason):
                    self.activeAutoBitrateMbps = Double(newBps) / 1_000_000.0
                    let config = self.makeConfiguration()
                    self.send(IOSReceiverWireHeader.control(.streamConfiguration, streamID: self.controlStreamID, payload: config.payload))
                    let suffix = lockedCeiling ? " · mantenuto limite stabile" : ""
                    self.appendEvent("Auto bitrate: ↩ \(newBps / 1_000_000) Mb/s (\(reason))\(suffix)")
                }
            }
        }
    }

    private func triggerAutoReconnect(reason: String) {
        guard shouldAutoReconnect else { return }
        if reconnectTask != nil { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = UInt64(max(5, agreedTimeoutSeconds)) * 1_000_000_000
        if reconnectDeadlineNanos == nil {
            reconnectDeadlineNanos = now &+ timeoutNanos
        }
        guard let deadline = reconnectDeadlineNanos else { return }
        if now >= deadline {
            teardownActiveConnection(clearAutoReconnect: true)
            let msg = "Timeout riconnessione (\(agreedTimeoutSeconds)s)"
            lastError = msg
            state = .failed(msg)
            appendEvent("Riconnessione automatica scaduta dopo \(agreedTimeoutSeconds)s")
            return
        }

        appendEvent("\(reason) · avvio riconnessione automatica (timeout \(agreedTimeoutSeconds)s)")
        teardownActiveConnection(clearAutoReconnect: false)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.shouldAutoReconnect {
                let tickNow = DispatchTime.now().uptimeNanoseconds
                guard let activeDeadline = self.reconnectDeadlineNanos, tickNow < activeDeadline else {
                    self.teardownActiveConnection(clearAutoReconnect: true)
                    let msg = "Timeout riconnessione (\(self.agreedTimeoutSeconds)s)"
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.appendEvent("Riconnessione automatica scaduta dopo \(self.agreedTimeoutSeconds)s")
                    return
                }

                self.reconnectAttempt += 1
                let remaining = max(1, Int((activeDeadline - tickNow) / 1_000_000_000))
                self.state = .reconnecting(attempt: self.reconnectAttempt, remainingSeconds: remaining)
                self.appendEvent("Tentativo riconnessione #\(self.reconnectAttempt) (rimangono \(remaining)s)…")

                self.teardownActiveConnection(clearAutoReconnect: false)
                self.openConnection(endpoint: self.activeEndpoint, isReconnectAttempt: true)

                for _ in 0..<2 {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { return }
                    guard self.shouldAutoReconnect, self.controlStreamID == 0 else { return }
                    let current = DispatchTime.now().uptimeNanoseconds
                    if let d = self.reconnectDeadlineNanos, current < d {
                        let rem = max(1, Int((d - current) / 1_000_000_000))
                        self.state = .reconnecting(attempt: self.reconnectAttempt, remainingSeconds: rem)
                    }
                }
            }
        }
    }

    private func requestLiveResync(reason: String) {
        guard (udpSocket != nil || controlConnection != nil), controlStreamID != 0, !isResynchronizing else { return }
        let now = PyrowaveClock.now
        if let lastResyncAt, lastResyncAt.duration(to: now) < .seconds(2) { return }
        lastResyncAt = now
        isResynchronizing = true
        resyncStartedAt = now
        lastGoodFrameAt = nil
        // Keep the last picture on screen (frozen) instead of flashing to black: the
        // server answers with a fresh frame, usually within a few hundred ms.
        frameWaitStartedAt = now
        state = .waiting
        assemblyLock.lock()
        assembler.reset()
        adaptiveBuffer.reset()
        assemblyLock.unlock()
        let activeDecoder = decoder
        Task { await activeDecoder?.reset() }
        send(IOSReceiverWireHeader.control(
            .streamConfiguration,
            streamID: controlStreamID,
            payload: makeConfiguration().payload,
            flags: 1
        ))
        appendEvent(reason)
    }

    /// (Re)creates the clipboard channel for the current control session and sends the
    /// subscription. Chunks are sent from the channel's queue straight to the socket.
    private func startClipboardSession() {
        let socket = udpSocket
        let connection = controlConnection
        let streamID = controlStreamID
        clipboardSession.start(mtu: Int(makeConfiguration().mtu), enabled: clipboardSyncEnabled) { payload in
            let datagram = IOSReceiverWireHeader.control(.clipboard, streamID: streamID, payload: payload)
            if let socket {
                socket.send(datagram)
            } else {
                connection?.send(content: datagram, completion: .idempotent)
            }
        }
    }

    private func send(_ data: Data) {
        if let udpSocket {
            udpSocket.send(data)
            return
        }
        controlConnection?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.appendEvent("UDP send failed: \(error.localizedDescription)")
            }
        })
    }

    private func appendEvent(_ event: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        events.append("\(time)  \(event)")
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
