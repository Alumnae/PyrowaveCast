import AppKit
import SwiftUI
import SPPWCommon

public struct ReceiverContentView: View {
    @EnvironmentObject private var model: ReceiverModel
    @State private var isVideoFullscreen = false
    @State private var enteredNativeFullscreen = false
    /// Fullscreen top-right bar: shown on entry and on mouse movement, hidden after a pause.
    @State private var fullscreenBarVisible = true
    @State private var fullscreenBarHovered = false
    @State private var fullscreenBarHideTask: Task<Void, Never>?
    @State private var showFullscreenExitHint = false
    @StateObject private var exitChordMonitor = FullscreenExitChordMonitor()
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
            if isVideoFullscreen && (!model.remoteControlEnabled || !model.isCapturingKeyboard) {
                exitVideoFullscreen()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            if isVideoFullscreen {
                isVideoFullscreen = false
                enteredNativeFullscreen = false
                exitChordMonitor.stop()
                fullscreenBarHideTask?.cancel()
                fullscreenBarHideTask = nil
            }
        }
    }

    /// Height of the top strip that brings the fullscreen bar back on hover.
    static let fullscreenRevealBandHeight: CGFloat = 48

    /// Shows the fullscreen bar and schedules it to slide up after 3 s away from it.
    private func revealFullscreenBar() {
        guard isVideoFullscreen else { return }
        if !fullscreenBarVisible {
            withAnimation(.easeOut(duration: 0.2)) { fullscreenBarVisible = true }
        }
        fullscreenBarHideTask?.cancel()
        fullscreenBarHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isVideoFullscreen, !fullscreenBarHovered else { return }
            withAnimation(.easeInOut(duration: 0.35)) { fullscreenBarVisible = false }
        }
    }

    private func enterVideoFullscreen() {
        isVideoFullscreen = true
        exitChordMonitor.start { exitVideoFullscreen() } onPointerNearTop: { revealFullscreenBar() }
        revealFullscreenBar()
        showFullscreenExitHint = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.4)) { showFullscreenExitHint = false }
        }
        if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            enteredNativeFullscreen = true
            window.toggleFullScreen(nil)
        } else {
            enteredNativeFullscreen = false
        }
    }

    private func exitVideoFullscreen() {
        isVideoFullscreen = false
        exitChordMonitor.stop()
        fullscreenBarHideTask?.cancel()
        fullscreenBarHideTask = nil
        showFullscreenExitHint = false
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
                        Picker(SPPWLocalization.tr("settings.resolution_preset"), selection: $model.resolutionMode) {
                            ForEach(resolutionOptions) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    if model.isConnected, model.statistics.frameWidth > 0 {
                        Text(SPPWLocalization.tr(
                            "settings.resolution_current_fmt",
                            "\(model.statistics.frameWidth)×\(model.statistics.frameHeight)"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
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
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(SPPWLocalization.tr("receiver.remote_control"), isOn: $model.remoteControlEnabled)
                        .font(.subheadline)
                        .help(SPPWLocalization.tr("receiver.remote_control_help"))
                    if model.remoteControlEnabled {
                        Text(SPPWLocalization.tr("receiver.remote_control_hint"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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

    /// Native, automatic and the short-side levels below the server's native size; the
    /// current choice stays listed even if the server is smaller than it.
    private var resolutionOptions: [SPPWResolutionMode] {
        var options = SPPWResolutionMode.menuOptions(nativeShortSide: model.nativeShortSide)
        if !options.contains(model.resolutionMode) {
            options.append(model.resolutionMode)
        }
        return options
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
                    orientation: model.videoOrientation,
                    remoteControlEnabled: model.remoteControlEnabled && model.isConnected,
                    onInputEvent: { event in
                        model.sendInputEvent(event)
                    },
                    onCaptureFocusChanged: { focused in
                        model.isCapturingKeyboard = focused
                    }
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
        .onContinuousHover { phase in
            // Mouse-moved events only reach the monitor while remote control tracks the
            // pointer; hover covers the view-only case. Only the top edge brings the bar back.
            if case let .active(location) = phase, isVideoFullscreen,
               location.y <= Self.fullscreenRevealBandHeight {
                revealFullscreenBar()
            }
        }
        .onTapGesture(count: 2) {
            if !model.remoteControlEnabled {
                toggleVideoFullscreen()
            }
        }
        .overlay(alignment: .top) {
            if isVideoFullscreen && showFullscreenExitHint {
                Label(SPPWLocalization.tr("receiver.fullscreen_exit_hint"), systemImage: "keyboard")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.top, 18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isVideoFullscreen || fullscreenBarVisible {
                HStack(spacing: 8) {
                    if hasVideo {
                        Button {
                            model.remoteControlEnabled.toggle()
                        } label: {
                            Label(
                                SPPWLocalization.tr("receiver.remote_control_short"),
                                systemImage: model.remoteControlEnabled ? "cursorarrow.click.2" : "cursorarrow"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.remoteControlEnabled ? .green : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.65), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(SPPWLocalization.tr("receiver.remote_control_help"))

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
                            isVideoFullscreen
                                ? SPPWLocalization.tr("action.exit_fullscreen")
                                : SPPWLocalization.tr("action.fullscreen"),
                            systemImage: isVideoFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .help(isVideoFullscreen
                        ? SPPWLocalization.tr("receiver.fullscreen_exit_help")
                        : SPPWLocalization.tr("action.fullscreen_help"))
                }
                .padding(14)
                .onHover { hovering in
                    fullscreenBarHovered = hovering
                    if !hovering { revealFullscreenBar() }
                }
                // Slides up out of the screen when it hides, and back down when the pointer
                // reaches the top edge.
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if hasVideo && !isVideoFullscreen {
                HStack(spacing: 8) {
                    Text("LIVE  ·  PyrowaveCast SPPW/1")
                        .font(.caption2.monospaced().weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())

                    if model.remoteControlEnabled {
                        Label(
                            model.isCapturingKeyboard
                                ? SPPWLocalization.tr("receiver.remote_control_active_badge")
                                : SPPWLocalization.tr("receiver.remote_control_click_badge"),
                            systemImage: model.isCapturingKeyboard ? "keyboard.fill" : "cursorarrow.click"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(model.isCapturingKeyboard ? .green : .white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.72), in: Capsule())
                    }
                }
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

/// While the receiver is in fullscreen, watches local keyboard and mouse events for a clean
/// ⌃⌥ press-and-release (exit) and for pointer motion (reveal the bar). Events pass through
/// unchanged, so the remote Mac still receives Control and Option.
@MainActor
final class FullscreenExitChordMonitor: ObservableObject {
    private var monitor: Any?
    private var detector = SPPWModifierChordDetector(required: [.control, .option])

    func start(onExit: @escaping @MainActor () -> Void, onPointerNearTop: @escaping @MainActor () -> Void) {
        stop()
        detector.reset()
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                let flags = SPPWKeyModifiers(rawValue: UInt32(truncatingIfNeeded:
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
                if self.detector.modifiersChanged(flags) {
                    // Let Control/Option reach the remote first, then leave fullscreen.
                    DispatchQueue.main.async { onExit() }
                }
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                if Self.isNearTopEdge(event) { onPointerNearTop() }
            default:
                self.detector.otherInput()
            }
            return event
        }
    }

    /// True when the pointer is in the top strip of the event's window.
    private static func isNearTopEdge(_ event: NSEvent) -> Bool {
        guard let height = event.window?.contentView?.bounds.height else { return false }
        return height - event.locationInWindow.y <= ReceiverContentView.fullscreenRevealBandHeight
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        detector.reset()
    }
}
