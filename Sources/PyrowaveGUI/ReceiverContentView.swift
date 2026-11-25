import AppKit
import SwiftUI
import SPPWCommon

public struct ReceiverContentView: View {
    @EnvironmentObject private var model: ReceiverModel
    @State private var isVideoFullscreen = false
    @State private var enteredNativeFullscreen = false
    /// Floating control button over the video (app logo, 50 % opacity until hovered): drag it
    /// anywhere, click it for the controls. Its centre is stored as a fraction of the free
    /// travel, so it keeps its place when the window or fullscreen changes size.
    @AppStorage("receiverControlPuckX") private var puckX: Double = 0.5
    @AppStorage("receiverControlPuckY") private var puckY: Double = 0
    @State private var puckDragOffset: CGSize = .zero
    @State private var puckDragging = false
    @State private var puckHovered = false
    @State private var puckMenuShown = false
    @State private var showFullscreenExitHint = false
    @StateObject private var exitChordMonitor = FullscreenExitChordMonitor()
    @AppStorage(SPPWLocalization.languageDefaultsKey) private var selectedLanguageRaw: String = SPPWAppLanguage.system.rawValue

    /// The unified app has one language picker in its sidebar, so it hides this one.
    private let showsLanguagePicker: Bool

    public init(showsLanguagePicker: Bool = true) {
        self.showsLanguagePicker = showsLanguagePicker
    }

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
            model.isVideoFullscreen = false
        }
        .onExitCommand {
            if isVideoFullscreen && (!model.remoteControlEnabled || !model.isCapturingKeyboard) {
                exitVideoFullscreen()
            }
        }
        .onChange(of: isVideoFullscreen) { _, fullscreen in
            model.isVideoFullscreen = fullscreen
        }
        .sheet(item: Binding(
            get: { model.pairingRequest.map(PairingSheetItem.init) },
            set: { if $0 == nil && model.pairingRequest != nil { model.cancelPairing() } }
        )) { item in
            PairingSecretSheet(request: item.request) { secret in
                model.providePairingSecret(secret)
            } onCancel: {
                model.cancelPairing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            if isVideoFullscreen {
                isVideoFullscreen = false
                enteredNativeFullscreen = false
                exitChordMonitor.stop()
            }
        }
    }

    private func enterVideoFullscreen() {
        isVideoFullscreen = true
        exitChordMonitor.start { exitVideoFullscreen() }
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
            if let info = model.securityInfo {
                Label(ReceiverModel.securityStatusText(info), systemImage: info.trust == .plaintext ? "lock.open" : (info.trust == .paired ? "lock.fill" : "lock"))
                    .font(.caption)
                    .foregroundStyle(info.trust == .paired ? Color.green : (info.trust == .plaintext ? Color.orange : Color.secondary))
                    .help(info.fingerprint?.display ?? "")
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

                if showsLanguagePicker {
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
                    Toggle(SPPWLocalization.tr("settings.prefer_high_quality"), isOn: $model.preferHighQuality)
                        .help(SPPWLocalization.tr("settings.prefer_high_quality_help"))
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
                ReceiverSecuritySection(model: model)

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
                    },
                    zoomScale: model.videoZoomScale,
                    onZoomChanged: { scale in
                        if abs(model.videoZoomScale - scale) > 0.001 {
                            model.videoZoomScale = scale
                        }
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
        .background {
            if hasVideo { zoomShortcuts }
        }
        .overlay(alignment: .bottomLeading) {
            // Large clipboard files on their way (background transfer), with cancel.
            FileTransfersView(compact: true)
                .padding(18)
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
        .overlay {
            GeometryReader { geometry in
                controlPuck(in: geometry.size, hasVideo: hasVideo)
            }
            .padding(isVideoFullscreen ? 0 : 12)
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

    static let puckSize: CGFloat = 40
    static let puckMargin: CGFloat = 10

    /// Centre of the control button for the stored fractions plus the drag in progress,
    /// kept inside the video area.
    private func puckCenter(in size: CGSize) -> CGPoint {
        let half = Self.puckSize / 2 + Self.puckMargin
        let travelX = max(0, size.width - 2 * half)
        let travelY = max(0, size.height - 2 * half)
        let x = half + travelX * puckX + puckDragOffset.width
        let y = half + travelY * puckY + puckDragOffset.height
        return CGPoint(
            x: min(max(x, half), max(half, size.width - half)),
            y: min(max(y, half), max(half, size.height - half))
        )
    }

    /// The app logo as a small floating button: 50 % opacity until hovered, so the remote
    /// screen underneath stays visible; drag it out of the way, click it for the controls.
    private func controlPuck(in size: CGSize, hasVideo: Bool) -> some View {
        let active = puckHovered || puckMenuShown || puckDragging
        return ZStack(alignment: .topTrailing) {
            Circle()
                .fill(.black.opacity(0.72))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .overlay(
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                )
            if model.remoteControlEnabled && hasVideo {
                Circle()
                    .fill(model.isCapturingKeyboard ? Color.green : Color.white)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                    .offset(x: -1, y: 1)
            }
        }
        .frame(width: Self.puckSize, height: Self.puckSize)
        .contentShape(Circle())
        .opacity(active ? 1 : 0.5)
        .scaleEffect(puckDragging ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: active)
        .onHover { puckHovered = $0 }
        .help(SPPWLocalization.tr("receiver.controls_puck_help"))
        .accessibilityLabel(SPPWLocalization.tr("receiver.controls_puck_help"))
        .accessibilityAddTraits(.isButton)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    puckDragging = true
                    puckDragOffset = value.translation
                }
                .onEnded { _ in
                    let center = puckCenter(in: size)
                    let half = Self.puckSize / 2 + Self.puckMargin
                    let travelX = max(1, size.width - 2 * half)
                    let travelY = max(1, size.height - 2 * half)
                    puckX = min(max((center.x - half) / travelX, 0), 1)
                    puckY = min(max((center.y - half) / travelY, 0), 1)
                    puckDragOffset = .zero
                    puckDragging = false
                }
        )
        .onTapGesture { puckMenuShown.toggle() }
        .popover(isPresented: $puckMenuShown, arrowEdge: .bottom) {
            controlMenu(hasVideo: hasVideo)
        }
        .position(puckCenter(in: size))
    }

    /// The video controls, grouped in the control button's popover.
    private func controlMenu(hasVideo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

                if model.remoteControlEnabled {
                    Button {
                        model.clipboardSyncEnabled.toggle()
                    } label: {
                        Label(
                            SPPWLocalization.tr("remote.clipboard_sync"),
                            systemImage: model.clipboardSyncEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.clipboardSyncEnabled ? .green : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(SPPWLocalization.tr("receiver.clipboard_sync_help"))
                } else {
                    // With remote control on the remote cursor is always hidden.
                    Button {
                        model.hideRemoteCursor.toggle()
                    } label: {
                        Label(
                            SPPWLocalization.tr("receiver.hide_remote_cursor"),
                            systemImage: model.hideRemoteCursor ? "cursorarrow.slash" : "cursorarrow.rays"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.hideRemoteCursor ? .green : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(SPPWLocalization.tr("receiver.hide_remote_cursor_help"))
                }

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

                zoomControl
            }

            Button {
                puckMenuShown = false
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
        .padding(12)
    }

    /// ⌘+ / ⌘− / ⌘0 on invisible buttons, so they keep working while the controls popover is
    /// closed. Bound only while the keyboard is not captured: during remote control the same
    /// keys reach the remote Mac.
    private var zoomShortcuts: some View {
        let captured = model.remoteControlEnabled && model.isCapturingKeyboard
        return ZStack {
            Button("") { model.stepVideoZoom(by: 0.25) }
                .keyboardShortcut(captured ? nil : KeyboardShortcut("=", modifiers: .command))
            Button("") { model.stepVideoZoom(by: 0.25) }
                .keyboardShortcut(captured ? nil : KeyboardShortcut("+", modifiers: .command))
            Button("") { model.stepVideoZoom(by: -0.25) }
                .keyboardShortcut(captured ? nil : KeyboardShortcut("-", modifiers: .command))
            Button("") { model.resetVideoZoom() }
                .keyboardShortcut(captured ? nil : KeyboardShortcut("0", modifiers: .command))
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// "− 1.0× +": local magnifier up to 2× (the number resets to 1×).
    private var zoomControl: some View {
        let scale = model.videoZoomScale
        return HStack(spacing: 6) {
            Button { model.stepVideoZoom(by: -0.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(scale <= SPPWViewZoom.minimumScale + 0.001)
            .help(SPPWLocalization.tr("zoom.out_help"))

            Button { model.resetVideoZoom() } label: {
                Text(String(format: "%.1f×", scale))
                    .monospacedDigit()
                    .frame(minWidth: 30)
            }
            .buttonStyle(.plain)
            .help(SPPWLocalization.tr("zoom.reset_help"))

            Button { model.stepVideoZoom(by: 0.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(scale >= SPPWViewZoom.maximumScale - 0.001)
            .help(SPPWLocalization.tr("zoom.in_help"))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(scale > 1.001 ? .cyan : .white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.65), in: Capsule())
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
    /// The running monitor; the video view reports keys it consumes before this monitor sees them.
    private static weak var active: FullscreenExitChordMonitor?

    /// A key went to the remote Mac (⌃⌥ + key is a shortcut, not the exit chord).
    static func noteOtherInput() {
        active?.detector.otherInput()
    }

    func start(onExit: @escaping @MainActor () -> Void) {
        stop()
        detector.reset()
        Self.active = self
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
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
            default:
                self.detector.otherInput()
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        detector.reset()
        if Self.active === self { Self.active = nil }
    }
}


// MARK: - Security (receiver)

private struct PairingSheetItem: Identifiable {
    let request: SPPWPairingRequest
    var id: String { "\(request.serverFingerprint.hex)-\(request.attemptsLeft)-\(request.previousAttemptFailed)" }
}

/// Asks for the PIN shown on the server (or the headless server's password).
struct PairingSecretSheet: View {
    let request: SPPWPairingRequest
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var secret = ""
    @FocusState private var focused: Bool

    private var isPIN: Bool { request.method == .pin }
    private var isValid: Bool { isPIN ? secret.count == 5 && secret.allSatisfy(\.isNumber) : !secret.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                SPPWLocalization.tr(isPIN ? "security.prompt.pin.title" : "security.prompt.password.title"),
                systemImage: "lock.shield"
            )
            .font(.title3.weight(.semibold))
            Text(SPPWLocalization.tr(
                isPIN ? "security.prompt.pin.message_fmt" : "security.prompt.password.message_fmt",
                request.serverName,
                request.serverFingerprint.display
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if request.previousAttemptFailed {
                Text(isPIN && request.attemptsLeft >= SPPWServerSecurity.pinAttempts
                     ? SPPWLocalization.tr("security.prompt.renewed")
                     : SPPWLocalization.tr("security.prompt.wrong_fmt", request.attemptsLeft))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Group {
                if isPIN {
                    TextField("00000", text: $secret)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onChange(of: secret) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(5))
                            if digits != value { secret = digits }
                        }
                } else {
                    SecureField(SPPWLocalization.tr("security.prompt.password.title"), text: $secret)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { if isValid { onSubmit(secret) } }
            HStack {
                Spacer()
                Button(SPPWLocalization.tr("security.prompt.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(SPPWLocalization.tr("security.prompt.pair")) { onSubmit(secret) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

/// Encryption toggle, this device's fingerprint and the paired servers.
struct ReceiverSecuritySection: View {
    @ObservedObject var model: ReceiverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(SPPWLocalization.tr("security.encryption"), isOn: $model.encryptionEnabled)
                .font(.subheadline)
                .help(SPPWLocalization.tr("security.receiver.encryption.help"))
                .disabled(model.isConnected)
            if model.encryptionEnabled {
                Text(SPPWLocalization.tr("security.fingerprint_this"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.deviceFingerprint)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                DisclosureGroup(SPPWLocalization.tr("security.paired_servers_fmt", model.pairedServers.count)) {
                    if model.pairedServers.isEmpty {
                        Text(SPPWLocalization.tr("security.none_paired"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.pairedServers) { peer in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.name).font(.caption)
                                Text(peer.fingerprint.short).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(SPPWLocalization.tr("security.forget"), role: .destructive) {
                                model.forgetPairedServer(peer)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }
}
