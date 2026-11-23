import AVFoundation
import Combine
import CoreVideo
import Foundation
import UIKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif

@MainActor
final class IOSServerModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case card = "Test card"
        case screen = "Screen"
        case image = "Image"
        case video = "Video"

        var id: String { rawValue }
        var localizedTitle: String {
            switch self {
            case .card: SPPWLocalization.tr("server.mode.card")
            case .screen: SPPWLocalization.tr("server.mode.screen")
            case .image: SPPWLocalization.tr("server.mode.image")
            case .video: SPPWLocalization.tr("server.mode.video")
            }
        }
        var symbol: String {
            switch self {
            case .card: "tv"
            case .screen: "display"
            case .image: "photo"
            case .video: "film"
            }
        }
    }

    @Published var mode: Mode = .card
    @Published var port: Int = UserDefaults.standard.object(forKey: "iosServerPort") as? Int ?? 9888 {
        didSet { UserDefaults.standard.set(port, forKey: "iosServerPort") }
    }
    @Published private(set) var selectedImageAsset: URL?
    @Published private(set) var selectedVideoAsset: URL? {
        didSet {
            if selectedVideoAsset != oldValue {
                loadSelectedVideoMetadata()
            }
        }
    }
    @Published var videoDurationSeconds: Double = 0
    @Published var videoCurrentTimeSeconds: Double = 0
    var isScrubbingVideo: Bool = false
    @Published private(set) var isRunning = false
    @Published private(set) var isStartingScreenCapture = false
    @Published private(set) var status = StreamStatus()
    @Published private(set) var logs: [ServerLogEntry] = []
    @Published private(set) var previewPixelBuffer: CVPixelBuffer?
    /// Audio sources read from the system (none, app/system audio, audio inputs).
    @Published private(set) var audioSources: [SPPWAudioSourceOption] = SPPWAudioSourceCatalog.availableSources()
    /// Persisted choice (`SPPWAudioSourceOption.id`); applies to screen capture, read at start.
    @Published var audioSourceID: String = UserDefaults.standard.string(forKey: "iosServerAudioSource") ?? SPPWAudioSourceOption.system.id {
        didSet { UserDefaults.standard.set(audioSourceID, forKey: "iosServerAudioSource") }
    }
    /// Input volume 0...2 (100% = unchanged); applied live, also to video file audio.
    @Published var audioInputVolume: Double = UserDefaults.standard.object(forKey: "iosServerAudioInputVolume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(audioInputVolume, forKey: "iosServerAudioInputVolume")
            server?.setAudioInputGain(Float(audioInputVolume))
        }
    }
    private var microphone: SPPWMicrophoneCapture?
    /// Background streaming (continued-processing GPU task) + diagnostics while the server runs.
    private var backgroundGuard: IOSBackgroundStreamingGuard?
    private var isAppInForeground = true
    /// The system screen capture stopped while serving; restarted when the app is on screen.
    private var screenCaptureNeedsRestart = false
    private var screenCaptureResolution = (width: 0, height: 0)

    func refreshAudioSources() {
        audioSources = SPPWAudioSourceCatalog.availableSources()
        if !audioSources.contains(where: { $0.id == audioSourceID }) {
            audioSourceID = SPPWAudioSourceOption.system.id
        }
    }

    @Published var previewEnabled: Bool = UserDefaults.standard.object(forKey: "iosServerPreviewEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(previewEnabled, forKey: "iosServerPreviewEnabled")
            if !previewEnabled {
                previewPixelBuffer = nil
            }
            if let activeServer = server {
                let enabled = previewEnabled
                Task { await activeServer.setPreviewEnabled(enabled) }
            }
        }
    }

    var selectedAsset: URL? {
        switch mode {
        case .image: selectedImageAsset
        case .video: selectedVideoAsset
        case .card, .screen: nil
        }
    }
    @Published var errorMessage: String?

    private var server: IOSStreamServer?
    private var screenCapture: IOSScreenCaptureCoordinator?
    private let previewDecoder = IOSPreviewDecoder()
    private var statusTask: Task<Void, Never>?
    private var nextLogID = 0
    private var videoMetadataGeneration: UInt64 = 0

    var canStart: Bool {
        guard !isRunning, !isStartingScreenCapture, (1...65_534).contains(port) else { return false }
        if mode == .image || mode == .video { return selectedAsset != nil }
        return true
    }

    func start() {
        guard canStart else { return }
        let selectedSource: IOSServerSource
        switch mode {
        case .card: selectedSource = .card
        case .screen: selectedSource = .screen
        case .image:
            guard let selectedAsset else { return }
            selectedSource = .image(selectedAsset)
        case .video:
            guard let selectedAsset else { return }
            selectedSource = .video(selectedAsset)
        }

        let nativeBounds = UIScreen.main.nativeBounds.size
        let serverScreenResolution = IOSStreamServer.clampedEvenResolution(
            width: Int(nativeBounds.width.rounded()),
            height: Int(nativeBounds.height.rounded())
        )
        let instance = IOSStreamServer(
            source: selectedSource,
            screenResolution: serverScreenResolution,
            previewEnabled: previewEnabled,
            audioInputGain: Float(audioInputVolume),
            logHandler: { [weak self] entry in
                Task { @MainActor in self?.append(entry) }
            },
            previewHandler: { [weak self] bitstream, width, height in
                Task { @MainActor [weak self] in
                    guard let self, self.previewEnabled else { return }
                    await self.updatePreview(bitstream, width: width, height: height)
                }
            }
        )
        server = instance
        previewPixelBuffer = nil
        errorMessage = nil

        let initialSeek = (mode == .video && videoCurrentTimeSeconds > 0) ? videoCurrentTimeSeconds : 0
        Task { [weak self] in
            guard let self else { return }
            do {
                if initialSeek > 0 {
                    await instance.seekVideo(to: initialSeek)
                }
                try await instance.start(port: UInt16(self.port))
                self.isRunning = true
                // No auto-lock while serving; a locked device suspends the app and the stream.
                IOSKeepAwake.shared.acquire(.server)
                self.isAppInForeground = UIApplication.shared.applicationState != .background
                self.backgroundGuard = IOSBackgroundStreamingGuard(
                    onEvent: { [weak self] message, isError in
                        self?.append(ServerLogEntry(id: 0, timestamp: Date(), text: message, isError: isError))
                    },
                    onVideoAllowedChanged: { allowed in
                        Task { await instance.setVideoSuspended(!allowed) }
                    },
                    onForegroundChanged: { [weak self] foreground in
                        self?.appForegroundChanged(foreground, instance: instance)
                    },
                    snapshot: { [weak self] in
                        let status = self?.status ?? StreamStatus()
                        return IOSBackgroundStreamingGuard.Snapshot(
                            framesSent: status.framesSent,
                            connectedClients: status.connectedClients,
                            megabitsPerSecond: status.megabitsPerSecond
                        )
                    }
                )
                self.startStatusPolling(for: instance)
                self.append(ServerLogEntry(
                    id: 0,
                    timestamp: Date(),
                    text: "Server started on UDP \(self.port); video sent via unicast on same port",
                    isError: false
                ))

                if self.mode == .screen {
                    self.isStartingScreenCapture = true
                    let capture = self.makeScreenCapture(for: instance)
                    self.screenCapture = capture
                    self.screenCaptureResolution = serverScreenResolution
                    do {
                        let audioKind = SPPWAudioSourceCatalog.source(withID: self.audioSourceID, in: self.audioSources).kind
                        let frames = try await capture.start(
                            width: serverScreenResolution.width,
                            height: serverScreenResolution.height,
                            audioHandler: self.systemAudioHandler(for: instance)
                        )
                        if case .input(let portUID) = audioKind {
                            let microphone = SPPWMicrophoneCapture()
                            do {
                                try microphone.start(portUID: portUID) { buffer, capturedAt in
                                    instance.ingestAudio(pcmBuffer: buffer, captureNanoseconds: capturedAt)
                                }
                                self.microphone = microphone
                            } catch {
                                self.append(ServerLogEntry(
                                    id: 0,
                                    timestamp: Date(),
                                    text: "Microphone capture failed: \(error.localizedDescription)",
                                    isError: true
                                ))
                            }
                        }
                        await instance.setScreenFrameStream(frames)
                        self.append(ServerLogEntry(
                            id: 0,
                            timestamp: Date(),
                            text: "System screen sharing approved (\(serverScreenResolution.width)x\(serverScreenResolution.height)); frames will stream when a client joins",
                            isError: false
                        ))
                    } catch {
                        await instance.stop()
                        self.server = nil
                        self.isRunning = false
                        throw error
                    }
                    self.isStartingScreenCapture = false
                }
            } catch {
                self.isStartingScreenCapture = false
                self.errorMessage = error.localizedDescription
                self.isRunning = false
                self.backgroundGuard?.invalidate()
                self.backgroundGuard = nil
                IOSKeepAwake.shared.release(.server)
            }
        }
    }

    func stop() {
        statusTask?.cancel()
        statusTask = nil
        let activeServer = server
        server = nil
        isRunning = false
        isStartingScreenCapture = false
        previewPixelBuffer = nil
        if let activeServer { Task { await activeServer.stop() } }
        if let capture = screenCapture {
            self.screenCapture = nil
            Task { await capture.stop() }
        }
        microphone?.stop()
        microphone = nil
        screenCaptureNeedsRestart = false
        backgroundGuard?.invalidate()
        backgroundGuard = nil
        IOSKeepAwake.shared.release(.server)
    }

    func acceptFile(_ url: URL, for targetMode: Mode? = nil) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let name = "\(UUID().uuidString)-\(url.lastPathComponent)"
            let destination = documents.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
            acceptImportedSandboxFile(destination, for: targetMode ?? mode)
        } catch {
            errorMessage = SPPWLocalization.tr("server.error.file_import_fmt", error.localizedDescription)
        }
    }

    func acceptImportedSandboxFile(_ destination: URL, for targetMode: Mode) {
        switch targetMode {
        case .image:
            selectedImageAsset = destination
        case .video:
            selectedVideoAsset = destination
        case .card, .screen:
            break
        }
        append(ServerLogEntry(
            id: 0,
            timestamp: Date(),
            text: "Selected \(targetMode.rawValue.lowercased()): \(destination.lastPathComponent)",
            isError: false
        ))
    }

    func notePreviewError(_ message: String) {
        append(ServerLogEntry(
            id: 0,
            timestamp: Date(),
            text: "Preview display: \(message)",
            isError: true
        ))
    }

    func clearLogs() { logs.removeAll() }

    func seekVideo(to seconds: Double) {
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

    func nudgeVideo(by deltaSeconds: Double) {
        seekVideo(to: videoCurrentTimeSeconds + deltaSeconds)
    }

    private func loadSelectedVideoMetadata() {
        videoMetadataGeneration &+= 1
        let gen = videoMetadataGeneration
        videoCurrentTimeSeconds = 0
        videoDurationSeconds = 0
        guard let url = selectedVideoAsset else { return }
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

    static func formatPlaybackTime(_ seconds: Double) -> String {
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

    // MARK: Background and capture recovery

    private func systemAudioHandler(for instance: IOSStreamServer) -> (@Sendable (CMSampleBuffer) -> Void)? {
        let audioKind = SPPWAudioSourceCatalog.source(withID: audioSourceID, in: audioSources).kind
        guard audioKind == .system else { return nil }
        return { sampleBuffer in instance.ingestAudio(sampleBuffer) }
    }

    private func makeScreenCapture(for instance: IOSStreamServer) -> IOSScreenCaptureCoordinator {
        let capture = IOSScreenCaptureCoordinator()
        capture.onCaptureStopped = { [weak self, weak capture] reason in
            guard let self, let capture, self.screenCapture === capture else { return }
            self.screenCaptureStopped(reason, instance: instance)
        }
        return capture
    }

    private func appForegroundChanged(_ foreground: Bool, instance: IOSStreamServer) {
        isAppInForeground = foreground
        // The preview is invisible in the background; skip its GPU decode there.
        let enabled = previewEnabled && foreground
        Task { await instance.setPreviewEnabled(enabled) }
        if foreground {
            restartScreenCaptureIfNeeded(instance: instance)
        }
    }

    private func screenCaptureStopped(_ reason: String, instance: IOSStreamServer) {
        guard isRunning, server === instance, mode == .screen else { return }
        screenCaptureNeedsRestart = true
        append(ServerLogEntry(
            id: 0,
            timestamp: Date(),
            text: "Screen capture stopped by iOS (\(reason)); "
                + (isAppInForeground ? "restarting it" : "it restarts when PyrowaveCast returns to the foreground"),
            isError: true
        ))
        if isAppInForeground {
            restartScreenCaptureIfNeeded(instance: instance)
        }
    }

    /// Starts a new system capture after iOS stopped the previous one, so the stream comes
    /// back by itself instead of staying frozen until the server is restarted.
    private func restartScreenCaptureIfNeeded(instance: IOSStreamServer) {
        guard screenCaptureNeedsRestart, isRunning, server === instance,
              mode == .screen, !isStartingScreenCapture else { return }
        screenCaptureNeedsRestart = false
        isStartingScreenCapture = true
        let previous = screenCapture
        let capture = makeScreenCapture(for: instance)
        screenCapture = capture
        let resolution = screenCaptureResolution
        Task { [weak self] in
            await previous?.stop()
            guard let self else { return }
            do {
                let frames = try await capture.start(
                    width: resolution.width,
                    height: resolution.height,
                    audioHandler: self.systemAudioHandler(for: instance)
                )
                guard self.server === instance, self.screenCapture === capture else {
                    await capture.stop()
                    return
                }
                await instance.setScreenFrameStream(frames)
                self.append(ServerLogEntry(id: 0, timestamp: Date(), text: "Screen capture restarted", isError: false))
            } catch {
                self.append(ServerLogEntry(
                    id: 0,
                    timestamp: Date(),
                    text: "Screen capture could not restart (\(error.localizedDescription)); stop and start the server to share the screen again",
                    isError: true
                ))
            }
            self.isStartingScreenCapture = false
        }
    }

    private func startStatusPolling(for instance: IOSStreamServer) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                let latest = await instance.status()
                guard let self else { return }
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
                let intervalNanos: UInt64 = latest.connectedClients > 0 ? 500_000_000 : 2_000_000_000
                do { try await Task.sleep(nanoseconds: intervalNanos) }
                catch { return }
            }
        }
    }

    private func updatePreview(_ bitstream: Data, width: Int, height: Int) async {
        guard previewEnabled else { return }
        do {
            guard let decoded = try await previewDecoder.decode(bitstream, width: width, height: height) else { return }
            guard previewEnabled else { return }
            previewPixelBuffer = decoded.pixelBuffer
        } catch {
            append(ServerLogEntry(
                id: 0,
                timestamp: Date(),
                text: "Preview decode failed: \(error)",
                isError: true
            ))
        }
    }

    private func append(_ entry: ServerLogEntry) {
        nextLogID += 1
        let uniqueEntry = ServerLogEntry(
            id: nextLogID,
            timestamp: entry.timestamp,
            text: entry.text,
            isError: entry.isError
        )
        logs.append(uniqueEntry)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
}
