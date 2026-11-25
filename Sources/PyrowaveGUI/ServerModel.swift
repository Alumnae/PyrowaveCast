import AVFoundation
import AppKit
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import PyrowaveKit
import PyrowaveServerKit
import SPPWCommon
import SwiftUI
import UniformTypeIdentifiers

/// Carries a decoded CVPixelBuffer across concurrency domains.
struct SendablePreviewBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

/// Decodes the frames the server produces so the user interface can show
/// a preview of what a client receives.
actor PreviewDecoder {
    private var session: PyrowaveDecoderSession?
    private var size: (width: Int, height: Int)?
    private var sessionPixelFormat: OSType?
    /// `PyrowaveDecoderSession` is not reentrant, so only one decode may run at
    /// a time. While a frame is being decoded the next ones are dropped — the
    /// preview only cares about the newest frame anyway.
    private var isDecoding = false
    private var lastDecodeNanos: UInt64 = 0
    private var loggedFailure = false
    private var cachedBundleAvailable: Bool?
    /// Cap server preview decoding to ~10 fps so it doesn't compete with
    /// real-time 60 fps encoding and client decoding.
    private let minimumIntervalNanos: UInt64 = 100_000_000

    private func resourceBundleAvailable() -> Bool {
        if let cached = cachedBundleAvailable { return cached }
        let result = checkResourceBundleAvailable()
        cachedBundleAvailable = result
        return result
    }

    private func checkResourceBundleAvailable() -> Bool {
        let name = "PyrowaveKit_PyrowaveKit"
        let executableDir = ProcessInfo.processInfo.arguments.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: PreviewDecoder.self).resourceURL,
            Bundle.main.bundleURL,
            executableDir,
            executableDir?.appendingPathComponent("../Resources")
        ]
        if candidates.contains(where: {
            guard let url = $0?.appendingPathComponent(name + ".bundle") else { return false }
            return Bundle(url: url) != nil
        }) {
            return true
        }
        #if DEBUG
        // Development only: release builds must not embed `#filePath` (absolute home folder path).
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PyrowaveKit/Metal/PyrowaveKernels.metal")
        return FileManager.default.fileExists(atPath: sourceFallback.path)
        #else
        return false
        #endif
    }

    func decode(bitstream: Data, width: Int, height: Int) async -> SendablePreviewBuffer? {
        guard !isDecoding else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastDecodeNanos >= minimumIntervalNanos else { return nil }
        guard resourceBundleAvailable() else { return nil }
        isDecoding = true
        lastDecodeNanos = now
        defer { isDecoding = false }

        do {
            let pixelFormat = PyrowaveSessionDescriptor.preferredPixelFormat(forBitstream: bitstream)
            if session == nil || size?.width != width || size?.height != height || sessionPixelFormat != pixelFormat {
                let descriptor = try PyrowaveSessionDescriptor(
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    videoSignal: VideoSignalMetadata(yCbCrRange: .full)
                )
                session = try PyrowaveDecoderSession(descriptor: descriptor, minimumOutputBufferCount: 4)
                size = (width, height)
                sessionPixelFormat = pixelFormat
                loggedFailure = false
            }
            guard let session else { return nil }
            let result = try await session.decode(EncodedFrame(data: bitstream))
            loggedFailure = false
            return SendablePreviewBuffer(pixelBuffer: result.pixelBuffer)
        } catch {
            if !loggedFailure {
                loggedFailure = true
                fputs("Server preview decode failed (\(width)x\(height)): \(error)\n", stderr)
            }
            return nil
        }
    }
}

/// The state of the user interface.
@MainActor
public final class ServerModel: ObservableObject {
    public enum Mode: String, CaseIterable, Identifiable {
        case card = "Test card"
        case screen = "Screen"
        case image = "Image"
        case video = "Video"

        public var id: String { rawValue }

        public var localizedTitle: String {
            switch self {
            case .card: SPPWLocalization.tr("server.mode.card")
            case .screen: SPPWLocalization.tr("server.mode.screen")
            case .image: SPPWLocalization.tr("server.mode.image")
            case .video: SPPWLocalization.tr("server.mode.video")
            }
        }

        public var symbolName: String {
            switch self {
            case .card: "tv"
            case .screen: "display"
            case .image: "photo"
            case .video: "film"
            }
        }
    }

    @Published public var mode: Mode = .card
    @Published public var port: UInt16 = 9888
    @Published public var imagePath: String?
    @Published public var videoPath: String? {
        didSet {
            if videoPath != oldValue {
                loadSelectedVideoMetadata()
            }
        }
    }
    @Published public var videoDurationSeconds: Double = 0
    @Published public var videoCurrentTimeSeconds: Double = 0
    public var isScrubbingVideo: Bool = false
    @Published public var isRunning = false
    @Published public var status = StreamStatus()
    @Published public var logs: [ServerLogEntry] = []
    /// Thread-safe pre-filter so disabled or throttled preview frames never
    /// allocate a `@MainActor` Task from the 60 fps server encode thread.
    private final class PreviewGate: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool
        private var lastSubmitNanos: UInt64 = 0
        private let minIntervalNanos: UInt64 = 100_000_000 // ~10 fps max

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func setEnabled(_ value: Bool) {
            lock.lock()
            enabled = value
            lock.unlock()
        }

        func shouldAccept() -> Bool {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            defer { lock.unlock() }
            guard enabled else { return false }
            guard now &- lastSubmitNanos >= minIntervalNanos else { return false }
            lastSubmitNanos = now
            return true
        }
    }

    public let previewPublisher = PassthroughSubject<CVPixelBuffer?, Never>()
    @Published public private(set) var hasPreviewFrame: Bool = false
    public private(set) var previewPixelBuffer: CVPixelBuffer? {
        didSet {
            let nowHas = (previewPixelBuffer != nil)
            if hasPreviewFrame != nowHas {
                hasPreviewFrame = nowHas
            }
            previewPublisher.send(previewPixelBuffer)
        }
    }
    /// Screen capture in full resolution chroma (PyroWave 4:4:4). Read when the
    /// server starts; test sources always stay 4:2:0.
    @Published public var fullChroma444: Bool = UserDefaults.standard.bool(forKey: "serverFullChroma444") {
        didSet {
            UserDefaults.standard.set(fullChroma444, forKey: "serverFullChroma444")
        }
    }
    /// Audio sources read from the system (none, system audio, microphones).
    @Published public private(set) var audioSources: [SPPWAudioSourceOption] = SPPWAudioSourceCatalog.availableSources()
    /// Persisted choice (`SPPWAudioSourceOption.id`); applies to screen capture, read at start.
    @Published public var audioSourceID: String = UserDefaults.standard.string(forKey: "serverAudioSource") ?? SPPWAudioSourceOption.system.id {
        didSet {
            UserDefaults.standard.set(audioSourceID, forKey: "serverAudioSource")
        }
    }
    /// Input volume, 0...2 (100% = unchanged). Applied live, also to video file audio.
    @Published public var audioInputVolume: Double = UserDefaults.standard.object(forKey: "serverAudioInputVolume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(audioInputVolume, forKey: "serverAudioInputVolume")
            server?.setAudioInputGain(Float(audioInputVolume))
        }
    }

    public func refreshAudioSources() {
        audioSources = SPPWAudioSourceCatalog.availableSources()
        if !audioSources.contains(where: { $0.id == audioSourceID }) {
            audioSourceID = SPPWAudioSourceOption.system.id
        }
    }

    @Published public var previewEnabled: Bool = UserDefaults.standard.object(forKey: "serverPreviewEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(previewEnabled, forKey: "serverPreviewEnabled")
            previewGate.setEnabled(previewEnabled)
            if !previewEnabled {
                previewPixelBuffer = nil
            }
        }
    }
    /// Allow connected clients to control this Mac's mouse and keyboard (screen capture mode only).
    /// Takes effect immediately, also while streaming; requires macOS Accessibility permission.
    @Published public var remoteControlEnabled: Bool = UserDefaults.standard.bool(forKey: "serverRemoteControlEnabled") {
        didSet {
            UserDefaults.standard.set(remoteControlEnabled, forKey: "serverRemoteControlEnabled")
            server?.setRemoteInputEnabled(remoteControlEnabled)
            if remoteControlEnabled {
                refreshAccessibilityPermission()
            }
        }
    }
    @Published public var errorMessage: String?

    // MARK: Security (encryption and pairing, PROTOCOL.md §7)

    public let securityStore = SPPWSecurityStore.shared
    /// Lives as long as the model, so a PIN on screen and the settings survive start/stop.
    public private(set) lazy var security: SPPWServerSecurity = {
        let security = SPPWServerSecurity(
            store: securityStore,
            configuration: securityConfiguration,
            serverName: Host.current().localizedName ?? "Mac"
        ) { [weak self] event in
            Task { @MainActor in self?.handleSecurityEvent(event) }
        }
        securityStore.onChange = { [weak self] in
            Task { @MainActor in self?.refreshPairedClients() }
        }
        return security
    }()
    /// Encrypt the stream and require the secure handshake (receivers must match).
    @Published public var encryptionEnabled: Bool = UserDefaults.standard.object(forKey: "serverEncryptionEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(encryptionEnabled, forKey: "serverEncryptionEnabled")
            security.update(securityConfiguration)
        }
    }
    /// How unknown receivers are admitted while encryption is on.
    @Published public var pairingMode: SPPWPairingMode = SPPWPairingMode(rawValue: UInt8(UserDefaults.standard.integer(forKey: "serverPairingMode"))) ?? .pin {
        didSet {
            UserDefaults.standard.set(Int(pairingMode.rawValue), forKey: "serverPairingMode")
            security.update(securityConfiguration)
        }
    }
    /// The PIN to show while a receiver is pairing.
    @Published public private(set) var pairingPIN: SPPWPairingPINPrompt?
    @Published public private(set) var pairedClients: [SPPWTrustedPeer] = SPPWSecurityStore.shared.trustedPeers(.clients)
    @Published public private(set) var hasPairingPassword: Bool = SPPWSecurityStore.shared.hasServerPassword

    private var securityConfiguration: SPPWServerSecurityConfiguration {
        SPPWServerSecurityConfiguration(encryptionEnabled: encryptionEnabled, pairingMode: pairingMode)
    }

    /// This Mac's fingerprint, to compare with what a receiver shows.
    public var serverFingerprint: String { securityStore.identity.fingerprint.display }

    public func setPairingPassword(_ password: String) {
        securityStore.setServerPassword(password)
        hasPairingPassword = securityStore.hasServerPassword
    }

    public func forgetPairedClient(_ peer: SPPWTrustedPeer) {
        securityStore.forget(.clients, fingerprintHex: peer.fingerprintHex)
        security.revoke(fingerprintHex: peer.fingerprintHex)
        refreshPairedClients()
    }

    public func dismissPairingPIN() {
        security.cancelPIN()
    }

    private func refreshPairedClients() {
        pairedClients = securityStore.trustedPeers(.clients)
    }

    private func handleSecurityEvent(_ event: SPPWServerSecurityEvent) {
        let text: String
        switch event {
        case let .pinRequested(prompt):
            pairingPIN = prompt
            NSApp.requestUserAttention(.informationalRequest)
            text = SPPWLocalization.english("security.log.pin_requested_fmt", prompt.clientName, prompt.clientFingerprint.short)
        case .pinCleared:
            pairingPIN = nil
            return
        case let .paired(peer):
            pairingPIN = nil
            refreshPairedClients()
            text = SPPWLocalization.english("security.log.paired_fmt", peer.name, peer.fingerprint.short)
        case let .clientAuthenticated(name, fingerprint, paired):
            text = SPPWLocalization.english(paired ? "security.log.session_paired_fmt" : "security.log.session_fmt", name, fingerprint.short)
        case let .log(message):
            text = message
        }
        append(ServerLogEntry(id: logs.count + 1, timestamp: Date(), text: text, isError: false))
    }

    @Published public var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published public var hasAccessibilityPermission: Bool = SPPWMacInputInjector.isAccessibilityTrusted
    @Published public var serverScreenResolutionText: String = ServerDisplay.streamResolutionText

    private var server: StreamServer?
    private var statusTask: Task<Void, Never>?
    private var videoMetadataGeneration: UInt64 = 0
    private let previewDecoder = PreviewDecoder()
    private lazy var previewGate = PreviewGate(enabled: previewEnabled)
    private var activeObserverCancellable: AnyCancellable?
    private var nextLogID = 0

    public init() {
        _ = previewGate
        activeObserverCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshScreenRecordingPermission()
                self?.refreshAccessibilityPermission()
            }
    }

    public func refreshScreenRecordingPermission() {
        let granted = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermission != granted {
            hasScreenRecordingPermission = granted
        }
        let resolutionText = ServerDisplay.streamResolutionText
        if serverScreenResolutionText != resolutionText {
            serverScreenResolutionText = resolutionText
        }
    }

    public func refreshAccessibilityPermission() {
        let granted = SPPWMacInputInjector.isAccessibilityTrusted
        if hasAccessibilityPermission != granted {
            hasAccessibilityPermission = granted
        }
    }

    public func requestAccessibilityPermission() {
        let granted = SPPWMacInputInjector.requestAccessibilityPermission()
        refreshAccessibilityPermission()
        if !granted && !hasAccessibilityPermission {
            openAccessibilitySettings()
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func requestScreenRecordingPermission() {
        let granted = CGRequestScreenCaptureAccess()
        refreshScreenRecordingPermission()
        if !granted && !hasScreenRecordingPermission {
            openScreenRecordingSettings()
        }
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    public var canStart: Bool {
        guard !isRunning else { return false }
        switch mode {
        case .image: return imagePath != nil
        case .video: return videoPath != nil
        case .card, .screen: return true
        }
    }

    // MARK: - Commands

    public func start() {
        guard canStart else { return }

        if mode == .screen {
            refreshScreenRecordingPermission()
            refreshAccessibilityPermission()
            if !hasScreenRecordingPermission {
                _ = CGRequestScreenCaptureAccess()
                refreshScreenRecordingPermission()
                append(ServerLogEntry(
                    id: logs.count + 1,
                    timestamp: Date(),
                    text: SPPWLocalization.english("server.log.permission_missing_warning"),
                    isError: true
                ))
            }
            if remoteControlEnabled && !hasAccessibilityPermission && SPPWDistribution.allowsRemoteInputInjection {
                append(ServerLogEntry(
                    id: logs.count + 1,
                    timestamp: Date(),
                    text: SPPWLocalization.english("server.log.accessibility_missing_warning"),
                    isError: true
                ))
            }
        }

        let contentMode: TestContentMode?
        switch mode {
        case .card:
            contentMode = .card
        case .screen:
            contentMode = nil
        case .image:
            contentMode = imagePath.map { TestContentMode.image(URL(fileURLWithPath: $0)) }
        case .video:
            contentMode = videoPath.map { TestContentMode.video(URL(fileURLWithPath: $0)) }
        }

        let gate = previewGate
        let decoder = previewDecoder
        let server = StreamServer(
            testContentMode: contentMode,
            fullChroma444: fullChroma444,
            audioSource: SPPWAudioSourceCatalog.source(withID: audioSourceID, in: audioSources).kind,
            audioInputGain: Float(audioInputVolume),
            remoteInputEnabled: remoteControlEnabled,
            security: security,
            logHandler: { [weak self] entry in
                Task { @MainActor in self?.append(entry) }
            },
            previewHandler: { [weak self] bitstream, width, height in
                guard gate.shouldAccept() else { return }
                Task.detached(priority: .utility) { [weak self] in
                    guard let decoded = await decoder.decode(
                        bitstream: bitstream,
                        width: width,
                        height: height
                    ) else { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.previewEnabled else { return }
                        self.previewPixelBuffer = decoded.pixelBuffer
                    }
                }
            }
        )
        self.server = server

        let initialSeek = (mode == .video && videoCurrentTimeSeconds > 0) ? videoCurrentTimeSeconds : 0
        Task {
            do {
                if initialSeek > 0 {
                    await server.seekVideo(to: initialSeek)
                }
                try await server.start(port: port)
                isRunning = true
                append(ServerLogEntry(
                    id: logs.count + 1,
                    timestamp: Date(),
                    text: SPPWLocalization.english("server.log.started_port_fmt", Int(port)),
                    isError: false
                ))
            } catch {
                errorMessage = SPPWLocalization.tr("server.error.start_failed_fmt", String(describing: error))
                isRunning = false
            }
        }

        startStatusPolling()
    }

    public func stop() {
        guard let server else { return }
        Task { await server.stop() }
        self.server = nil
        isRunning = false
        statusTask?.cancel()
        statusTask = nil
        previewPixelBuffer = nil
    }

    public func chooseImage() {
        guard let url = Self.openPanel(allowed: ["png", "jpg", "jpeg", "tiff", "bmp", "heic"]) else { return }
        imagePath = url.path
    }

    public func chooseVideo() {
        guard let url = Self.openPanel(allowed: ["mov", "mp4", "m4v"]) else { return }
        videoPath = url.path
    }

    public func seekVideo(to seconds: Double) {
        let clamped: Double
        if videoDurationSeconds > 0 {
            clamped = min(max(0, seconds), videoDurationSeconds)
        } else {
            clamped = max(0, seconds)
        }
        videoCurrentTimeSeconds = clamped
        if let server {
            Task { await server.seekVideo(to: clamped) }
        }
    }

    public func nudgeVideo(by deltaSeconds: Double) {
        seekVideo(to: videoCurrentTimeSeconds + deltaSeconds)
    }

    private func loadSelectedVideoMetadata() {
        videoMetadataGeneration &+= 1
        let gen = videoMetadataGeneration
        videoCurrentTimeSeconds = 0
        videoDurationSeconds = 0
        guard let path = videoPath else { return }
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .utility) { [weak self] in
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            let secs = duration?.seconds ?? 0
            guard secs.isFinite && secs > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self, self.videoMetadataGeneration == gen else { return }
                self.videoDurationSeconds = secs
            }
        }
    }

    public static func formatPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private static func openPanel(allowed: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Updates

    private func append(_ entry: ServerLogEntry) {
        nextLogID += 1
        let uniqueEntry = ServerLogEntry(
            id: nextLogID,
            timestamp: entry.timestamp,
            text: entry.text,
            isError: entry.isError
        )
        logs.append(uniqueEntry)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let server = self.server else { return }
                let latest = await server.status()
                if self.status != latest {
                    self.status = latest
                }
                if self.mode == .video && !self.isScrubbingVideo {
                    if latest.videoDurationSeconds > 0,
                       abs(self.videoDurationSeconds - latest.videoDurationSeconds) > 0.25 {
                        self.videoDurationSeconds = latest.videoDurationSeconds
                    }
                    if latest.connectedClients > 0 && latest.videoDurationSeconds > 0,
                       abs(self.videoCurrentTimeSeconds - latest.videoCurrentTimeSeconds) > 0.2 {
                        self.videoCurrentTimeSeconds = latest.videoCurrentTimeSeconds
                    }
                }
                // Poll more slowly when idle (0 connected clients) to minimize idle CPU wakeups.
                let intervalNanos: UInt64 = latest.connectedClients > 0 ? 500_000_000 : 2_000_000_000
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    return
                }
            }
        }
    }
}
