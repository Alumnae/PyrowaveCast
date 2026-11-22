import AppKit
import SwiftUI
import SPPWCommon

public struct ReceiverContentView: View {
    @EnvironmentObject private var model: ReceiverModel
    @State private var isVideoFullscreen = false
    @State private var enteredNativeFullscreen = false
    @AppStorage(SPPWLocalization.languageDefaultsKey) private var selectedLanguageRaw: String = SPPWAppLanguage.system.rawValue

    public init() {}

    public var body: some View {
        let _ = selectedLanguageRaw
        Group {
            if isVideoFullscreen {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    statusBar
                    Divider()
                    HStack(spacing: 0) {
                        controls
                            .frame(width: 310)
                        Divider()
                        preview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    eventLog
                        .frame(height: 165)
                }
            }
        }
        .background(isVideoFullscreen ? Color.black : Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .onAppear {
            if !model.isConnected {
                model.startDiscovery()
            }
        }
        .onDisappear {
            model.stopDiscovery()
        }
        .onExitCommand {
            if isVideoFullscreen {
                exitVideoFullscreen()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            if isVideoFullscreen {
                isVideoFullscreen = false
                enteredNativeFullscreen = false
            }
        }
    }

    private func enterVideoFullscreen() {
        isVideoFullscreen = true
        if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            enteredNativeFullscreen = true
            window.toggleFullScreen(nil)
        } else {
            enteredNativeFullscreen = false
        }
    }

    private func exitVideoFullscreen() {
        isVideoFullscreen = false
        if enteredNativeFullscreen {
            enteredNativeFullscreen = false
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    private func toggleVideoFullscreen() {
        if isVideoFullscreen {
            exitVideoFullscreen()
        } else {
            enterVideoFullscreen()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(model.state.label)
                    .font(.headline)
                    .lineLimit(1)
            }
            Divider().frame(height: 20)
            metric(SPPWLocalization.tr("metric.client"), SPPWLocalization.tr("metric.frames_fmt", model.statistics.decodedFrames))
            metric(SPPWLocalization.tr("metric.video"), model.statistics.frameWidth > 0
                ? "\(model.statistics.frameWidth)×\(model.statistics.frameHeight)"
                : "—")
            metric(SPPWLocalization.tr("metric.decode"), String(format: "%.1f ms", model.statistics.decodeMilliseconds))
            metric(SPPWLocalization.tr("metric.age"), String(format: "%.0f ms", model.statistics.ageMilliseconds))
            metric(SPPWLocalization.tr("metric.network"), String(format: "%.1f Mb/s", model.statistics.receivedMbps))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    @State private var favoriteNameText = ""
    @State private var showingFavoritePopover = false

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SPPWLocalization.tr("receiver.connect_to_server"))
                    .font(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text(SPPWLocalization.tr("settings.language")).font(.caption).foregroundStyle(.secondary)
                    Picker(SPPWLocalization.tr("settings.language"), selection: Binding(
                        get: { SPPWAppLanguage(rawValue: selectedLanguageRaw) ?? .system },
                        set: { newLang in
                            selectedLanguageRaw = newLang.rawValue
                            SPPWLocalization.selectedLanguage = newLang
                        }
                    )) {
                        ForEach(SPPWAppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(SPPWLocalization.tr("receiver.server_address")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("192.168.1.20", text: $model.host)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isConnected)
                        Button {
                            model.toggleCurrentFavorite()
                        } label: {
                            Image(systemName: model.isCurrentHostFavorite ? "star.fill" : "star")
                                .foregroundStyle(model.isCurrentHostFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(model.isCurrentHostFavorite
                              ? SPPWLocalization.tr("favorites.remove_help")
                              : SPPWLocalization.tr("favorites.add_help"))
                        .disabled(model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UInt16(model.portText) == nil)
                        Button {
                            favoriteNameText = model.host
                            showingFavoritePopover = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(SPPWLocalization.tr("favorites.save_named_help"))
                        .disabled(model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UInt16(model.portText) == nil)
                        .popover(isPresented: $showingFavoritePopover) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(SPPWLocalization.tr("favorites.save_title"))
                                    .font(.headline)
                                TextField(SPPWLocalization.tr("favorites.server_name_placeholder"), text: $favoriteNameText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                HStack {
                                    Spacer()
                                    Button(SPPWLocalization.tr("action.cancel")) { showingFavoritePopover = false }
                                    Button(SPPWLocalization.tr("action.save")) {
                                        model.addFavorite(name: favoriteNameText)
                                        showingFavoritePopover = false
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(12)
                        }
                    }
                    Text(SPPWLocalization.tr("receiver.control_udp_port")).font(.caption).foregroundStyle(.secondary)
                    TextField("9888", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isConnected)
                }

                HStack(spacing: 8) {
                    if model.isConnected {
                        Button(role: .destructive) { model.disconnect() } label: {
                            Label(SPPWLocalization.tr("action.disconnect"), systemImage: "xmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button { model.connect() } label: {
                            Label(SPPWLocalization.tr("action.connect"), systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.host.isEmpty || UInt16(model.portText) == nil)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(SPPWLocalization.tr("discovery.nearby"), systemImage: "bonjour")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if model.isDiscovering {
                            Image(systemName: "wave.3.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            model.startDiscovery()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(SPPWLocalization.tr("discovery.refresh_help"))
                    }
                    if model.discoveredServers.isEmpty {
                        Text(SPPWLocalization.tr("discovery.empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discoveredServers) { server in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(server.host):\(server.port)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    model.selectDiscovered(server, connectImmediately: false)
                                } label: {
                                    Text(SPPWLocalization.tr("action.use"))
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button {
                                    model.selectDiscovered(server, connectImmediately: true)
                                } label: {
                                    Text(SPPWLocalization.tr("action.connect"))
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button {
                                    model.host = server.host
                                    model.portText = String(server.port)
                                    model.addFavorite(name: server.name)
                                } label: {
                                    Image(systemName: "star")
                                }
                                .buttonStyle(.borderless)
                                .help(SPPWLocalization.tr("favorites.save_title"))
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(SPPWLocalization.tr("favorites.title"), systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(model.favorites.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if model.favorites.isEmpty {
                        Text(SPPWLocalization.tr("favorites.empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.favorites) { fav in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fav.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(fav.host):\(fav.port)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    model.selectFavorite(fav, connectImmediately: false)
                                } label: {
                                    Text(SPPWLocalization.tr("action.use"))
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button {
                                    model.selectFavorite(fav, connectImmediately: true)
                                } label: {
                                    Text(SPPWLocalization.tr("action.connect"))
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button(role: .destructive) {
                                    model.removeFavorite(fav)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help(SPPWLocalization.tr("favorites.remove_help"))
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Divider()
                Text(SPPWLocalization.tr("settings.stream_request"))
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(SPPWLocalization.tr("settings.resolution_preset"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker(SPPWLocalization.tr("settings.resolution_preset"), selection: resolutionPresetBinding) {
                            if model.serverControlledResolution && model.isConnected {
                                Text(SPPWLocalization.tr("settings.resolution_server_screen"))
                                    .tag(ResolutionPreset.serverScreenCapture)
                            }
                            Text("720p (1280×720)").tag(ResolutionPreset.p720)
                            Text("1080p (1920×1080)").tag(ResolutionPreset.p1080)
                            Text("1440p (2560×1440)").tag(ResolutionPreset.p1440)
                            Text("4K (3840×2160)").tag(ResolutionPreset.p4k)
                            Text(SPPWLocalization.tr("settings.resolution_custom"))
                                .tag(ResolutionPreset.custom)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(model.serverControlledResolution && model.isConnected)
                    }

                    HStack(spacing: 6) {
                        ForEach([ResolutionPreset.p720, .p1080, .p1440, .p4k]) { preset in
                            Button(preset.shortTitle) {
                                applyResolutionPreset(preset)
                            }
                            .buttonStyle(.bordered)
                            .tint(currentResolutionPreset == preset ? .blue : nil)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.serverControlledResolution && model.isConnected)

                    HStack(alignment: .bottom, spacing: 8) {
                        dimensionField(SPPWLocalization.tr("settings.width"), value: $model.width)
                            .disabled(model.serverControlledResolution && model.isConnected)
                        Button {
                            let oldW = model.width
                            model.width = model.height
                            model.height = oldW
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.bottom, 2)
                        .disabled(model.serverControlledResolution && model.isConnected)
                        dimensionField(SPPWLocalization.tr("settings.height"), value: $model.height)
                            .disabled(model.serverControlledResolution && model.isConnected)
                    }
                }
                if model.serverControlledResolution && model.isConnected {
                    Label(SPPWLocalization.tr("settings.server_controlled_resolution"), systemImage: "display.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.isConnected {
                    Text(SPPWLocalization.tr("settings.agreed_timeout_fmt", model.agreedTimeoutSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text(SPPWLocalization.tr("settings.frame_rate"))
                        Spacer()
                        Picker("FPS", selection: $model.fps) {
                            ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    HStack {
                        Text(SPPWLocalization.tr("settings.quality"))
                        Slider(value: $model.quality, in: 0.35...1, step: 0.01)
                        Text(String(format: "%.2f", model.quality))
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                    Toggle(SPPWLocalization.tr("settings.automatic_bitrate"), isOn: $model.automaticBitrate)
                    if model.automaticBitrate && model.isConnected && model.activeAutoBitrateMbps > 0 {
                        HStack {
                            Text(SPPWLocalization.tr("settings.auto_target"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(model.activeAutoBitrateMbps)) Mb/s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !model.automaticBitrate {
                        HStack {
                            Text(SPPWLocalization.tr("metric.bitrate"))
                            Spacer()
                            TextField("180", value: $model.bitrateMbps, format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("Mb/s").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(SPPWLocalization.tr("settings.fec_parity"))
                        Slider(
                            value: Binding(
                                get: { Double(model.fecPercent) },
                                set: { model.fecPercent = Int($0.rounded()) }
                            ),
                            in: 0...50,
                            step: 5
                        )
                        Text("\(model.fecPercent)%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                    HStack {
                        Text(SPPWLocalization.tr("settings.wifi_jitter_mode"))
                        Spacer()
                        Picker(SPPWLocalization.tr("settings.wifi_jitter_mode"), selection: $model.latencyMode) {
                            ForEach(SPPWLatencyMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                .font(.subheadline)

                Button { model.applySettings() } label: {
                    Label(SPPWLocalization.tr("action.apply_resync"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.isConnected)

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(SPPWLocalization.tr("orientation.title"), systemImage: "rotate.right")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(model.videoOrientation.summaryLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button {
                            model.rotateVideo()
                        } label: {
                            Label(SPPWLocalization.tr("orientation.rotate"), systemImage: "rotate.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(SPPWLocalization.tr("orientation.rotate_help"))

                        Button {
                            model.toggleFlip()
                        } label: {
                            Label(
                                SPPWLocalization.tr("orientation.flip"),
                                systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.videoOrientation.isFlippedHorizontally ? .blue : nil)
                        .controlSize(.small)
                        .help(SPPWLocalization.tr("orientation.flip_help"))
                    }
                }

                Divider()
                HStack {
                    Text(SPPWLocalization.tr("metric.fragments"))
                    Spacer()
                    Text("\(model.statistics.fragments)").monospacedDigit()
                }
                HStack {
                    Text(SPPWLocalization.tr("metric.complete_decoded"))
                    Spacer()
                    Text("\(model.statistics.completeFrames) / \(model.statistics.decodedFrames)").monospacedDigit()
                }
                HStack {
                    Text(SPPWLocalization.tr("metric.dropped_expired"))
                    Spacer()
                    Text("\(model.statistics.droppedFrames) / \(model.statistics.expiredFrames)").monospacedDigit()
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(16)
        }
    }

    private enum ResolutionPreset: String, CaseIterable, Identifiable {
        case serverScreenCapture
        case p720
        case p1080
        case p1440
        case p4k
        case custom

        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .serverScreenCapture: SPPWLocalization.tr("settings.resolution_server_screen")
            case .p720: "720p"
            case .p1080: "1080p"
            case .p1440: "1440p"
            case .p4k: "4K"
            case .custom: SPPWLocalization.tr("settings.resolution_custom")
            }
        }

        var landscapeDimensions: (width: Int, height: Int)? {
            switch self {
            case .p720: (1280, 720)
            case .p1080: (1920, 1080)
            case .p1440: (2560, 1440)
            case .p4k: (3840, 2160)
            case .serverScreenCapture, .custom: nil
            }
        }
    }

    private var currentResolutionPreset: ResolutionPreset {
        if model.serverControlledResolution && model.isConnected {
            return .serverScreenCapture
        }
        let swapped = model.videoOrientation.swapsDimensions
        for preset in [ResolutionPreset.p720, .p1080, .p1440, .p4k] {
            if let dims = preset.landscapeDimensions {
                let expectedW = swapped ? dims.height : dims.width
                let expectedH = swapped ? dims.width : dims.height
                if model.width == expectedW && model.height == expectedH {
                    return preset
                }
            }
        }
        return .custom
    }

    private var resolutionPresetBinding: Binding<ResolutionPreset> {
        Binding(
            get: { currentResolutionPreset },
            set: { newPreset in
                applyResolutionPreset(newPreset)
            }
        )
    }

    private func applyResolutionPreset(_ preset: ResolutionPreset) {
        guard let dims = preset.landscapeDimensions else { return }
        let swapped = model.videoOrientation.swapsDimensions
        model.width = swapped ? dims.height : dims.width
        model.height = swapped ? dims.width : dims.height
    }

    private func dimensionField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var preview: some View {
        let hasVideo = model.hasVideoFrame
        return ZStack {
            (isVideoFullscreen ? Color.black : Color.black.opacity(0.9))
            if hasVideo {
                // AVSampleBufferDisplayLayer — hardware-accelerated video
                // pipeline. `MetalVideoSurface` subscribes directly to
                // `model.pixelBufferSubject` so 60–120 fps frames bypass
                // SwiftUI's `ObservableObject.objectWillChange` diffing.
                MetalVideoSurface(
                    framePublisher: model.pixelBufferSubject,
                    initialPixelBuffer: model.currentPixelBuffer,
                    orientation: model.videoOrientation
                ) { message in
                    DispatchQueue.main.async { model.noteDisplayError(message) }
                }
                .padding(isVideoFullscreen ? 0 : 12)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "display")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.secondary)
                    Text({
                        if case .reconnecting = model.state { return model.state.label }
                        return model.isConnected
                            ? SPPWLocalization.tr("receiver.waiting_complete_frame")
                            : SPPWLocalization.tr("receiver.connect_prompt_title")
                    }())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(SPPWLocalization.tr("receiver.connect_prompt_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            toggleVideoFullscreen()
        }
        .overlay(alignment: .topTrailing) {
            if !isVideoFullscreen {
                HStack(spacing: 8) {
                    if hasVideo {
                        HStack(spacing: 8) {
                            Button { model.rotateVideo() } label: {
                                Label(SPPWLocalization.tr("orientation.rotate"), systemImage: "rotate.right")
                            }
                            .buttonStyle(.plain)
                            .help(SPPWLocalization.tr("orientation.rotate_help"))

                            Button { model.toggleFlip() } label: {
                                Label(
                                    SPPWLocalization.tr("orientation.flip"),
                                    systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
                                )
                                .foregroundStyle(model.videoOrientation.isFlippedHorizontally ? .cyan : .white)
                            }
                            .buttonStyle(.plain)
                            .help(SPPWLocalization.tr("orientation.flip_help"))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                    }

                    Button {
                        toggleVideoFullscreen()
                    } label: {
                        Label(
                            SPPWLocalization.tr("action.fullscreen"),
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .help(SPPWLocalization.tr("action.fullscreen_help"))
                }
                .padding(14)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if hasVideo && !isVideoFullscreen {
                Text("LIVE  ·  PyrowaveCast SPPW/1")
                    .font(.caption2.monospaced().weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(14)
            }
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SPPWLocalization.tr("receiver.log_title")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(SPPWLocalization.tr("action.clear")) { model.clearEvents() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { index, event in
                            Text(event)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .onChange(of: model.events.count) {
                    if !model.events.isEmpty { proxy.scrollTo(model.events.count - 1, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var statusColor: Color {
        switch model.state {
        case .streaming: .green
        case .connecting, .waiting, .reconnecting: .orange
        case .disconnected, .failed: .secondary
        }
    }
}
