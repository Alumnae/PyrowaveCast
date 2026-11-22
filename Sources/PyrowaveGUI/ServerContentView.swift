import SwiftUI
import SPPWCommon

public struct ServerContentView: View {
    @EnvironmentObject private var model: ServerModel
    @State private var showScreenPermissionGuide = true
    @State private var showAccessibilityPermissionGuide = true
    @AppStorage(SPPWLocalization.languageDefaultsKey) private var selectedLanguageRaw: String = SPPWAppLanguage.system.rawValue

    public init() {}

    public var body: some View {
        let _ = selectedLanguageRaw
        VStack(spacing: 0) {
            statusBar
            Divider()

            HSplitView {
                settings
                    .frame(minWidth: 290, idealWidth: 320, maxWidth: 380)
                preview
                    .frame(minWidth: 420)
            }
            .frame(maxHeight: .infinity)

            Divider()
            logPanel
                .frame(height: 190)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(model.isRunning ? SPPWLocalization.tr("state.listening") : SPPWLocalization.tr("state.stopped"))
                    .font(.headline)
            }

            Divider().frame(height: 16)

            statusItem(
                title: SPPWLocalization.tr("metric.port"),
                value: model.isRunning ? "\(model.status.port)" : "\(model.port)",
                systemImage: "network"
            )
            statusItem(
                title: SPPWLocalization.tr("metric.clients"),
                value: "\(model.status.connectedClients)",
                systemImage: "iphone"
            )
            statusItem(
                title: SPPWLocalization.tr("metric.resolution"),
                value: model.status.width > 0
                    ? "\(model.status.width)×\(model.status.height)"
                    : "—",
                systemImage: "aspectratio"
            )
            statusItem(
                title: SPPWLocalization.tr("metric.frame"),
                value: "\(model.status.framesSent)",
                systemImage: "film.stack"
            )
            statusItem(
                title: SPPWLocalization.tr("metric.bitrate"),
                value: String(format: "%.1f Mb/s", model.status.megabitsPerSecond),
                systemImage: "speedometer"
            )
            statusItem(
                title: SPPWLocalization.tr("metric.mode"),
                value: model.mode.localizedTitle,
                systemImage: model.mode.symbolName
            )

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func statusItem(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit())
            }
        }
    }

    // MARK: - Settings

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SPPWLocalization.tr("tab.settings"))
                    .font(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 8) {
                    Text(SPPWLocalization.tr("settings.language"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text(SPPWLocalization.tr("server.source"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(SPPWLocalization.tr("server.source"), selection: $model.mode) {
                        ForEach(ServerModel.Mode.allCases) { mode in
                            Label(mode.localizedTitle, systemImage: mode.symbolName)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(model.isRunning)
                }

                if model.mode == .image {
                    fileRow(
                        title: SPPWLocalization.tr("server.mode.image"),
                        path: model.imagePath,
                        placeholder: SPPWLocalization.tr("server.no_image_selected"),
                        action: model.chooseImage
                    )
                }

                if model.mode == .video {
                    fileRow(
                        title: SPPWLocalization.tr("server.mode.video"),
                        path: model.videoPath,
                        placeholder: SPPWLocalization.tr("server.no_video_selected"),
                        action: model.chooseVideo
                    )

                    if model.videoDurationSeconds > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Quick Track", systemImage: "timeline.selection")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(ServerModel.formatPlaybackTime(model.videoCurrentTimeSeconds)) / \(ServerModel.formatPlaybackTime(model.videoDurationSeconds))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.primary)
                            }
                            HStack(spacing: 8) {
                                Button {
                                    model.nudgeVideo(by: -15)
                                } label: {
                                    Image(systemName: "gobackward.15")
                                }
                                .buttonStyle(.borderless)
                                .help("-15s")

                                Slider(
                                    value: Binding(
                                        get: { min(max(0, model.videoCurrentTimeSeconds), model.videoDurationSeconds) },
                                        set: { newValue in
                                            model.videoCurrentTimeSeconds = newValue
                                            if !model.isScrubbingVideo {
                                                model.seekVideo(to: newValue)
                                            }
                                        }
                                    ),
                                    in: 0...max(model.videoDurationSeconds, 1),
                                    onEditingChanged: { editing in
                                        model.isScrubbingVideo = editing
                                        if !editing {
                                            model.seekVideo(to: model.videoCurrentTimeSeconds)
                                        }
                                    }
                                )

                                Button {
                                    model.nudgeVideo(by: 15)
                                } label: {
                                    Image(systemName: "goforward.15")
                                }
                                .buttonStyle(.borderless)
                                .help("+15s")
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(SPPWLocalization.tr("server.udp_port"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("9888", value: $model.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .disabled(model.isRunning)
                        Spacer()
                    }
                }

                if model.mode == .screen {
                    Toggle(SPPWLocalization.tr("server.chroma444"), isOn: $model.fullChroma444)
                        .font(.subheadline)
                        .help(SPPWLocalization.tr("server.chroma444.help"))
                        .disabled(model.isRunning)

                    Toggle(SPPWLocalization.tr("server.remote_control"), isOn: $model.remoteControlEnabled)
                        .font(.subheadline)
                        .help(SPPWLocalization.tr("server.remote_control.help"))
                }

                if model.mode == .screen {
                    HStack {
                        Picker(SPPWLocalization.tr("audio.source.label"), selection: $model.audioSourceID) {
                            ForEach(model.audioSources) { source in
                                Text(source.name).tag(source.id)
                            }
                        }
                        .disabled(model.isRunning)
                        Button {
                            model.refreshAudioSources()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(SPPWLocalization.tr("audio.refresh_sources"))
                        .disabled(model.isRunning)
                    }
                    .font(.subheadline)
                }

                if model.mode == .screen || model.mode == .video {
                    HStack {
                        Image(systemName: model.audioInputVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .foregroundStyle(.secondary)
                        Text(SPPWLocalization.tr("audio.input_volume"))
                        Slider(value: $model.audioInputVolume, in: 0...2)
                        Text("\(Int((model.audioInputVolume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.subheadline)
                }

                Toggle(SPPWLocalization.tr("server.client_preview"), isOn: $model.previewEnabled)
                    .font(.subheadline)

                HStack(spacing: 10) {
                    if model.isRunning {
                        Button(role: .destructive) {
                            model.stop()
                        } label: {
                            Label(SPPWLocalization.tr("action.stop"), systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            model.start()
                        } label: {
                            Label(SPPWLocalization.tr("action.start"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                    }
                }

                if model.mode == .screen {
                    screenCaptureGuidanceCard
                    if model.remoteControlEnabled {
                        accessibilityGuidanceCard
                    }
                } else {
                    Label(
                        SPPWLocalization.tr("server.test_modes_no_permission"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .onAppear {
            model.refreshScreenRecordingPermission()
            model.refreshAccessibilityPermission()
            showScreenPermissionGuide = !model.hasScreenRecordingPermission
            showAccessibilityPermissionGuide = !model.hasAccessibilityPermission
        }
        .onChange(of: model.hasScreenRecordingPermission) { _, granted in
            if !granted { showScreenPermissionGuide = true }
        }
        .onChange(of: model.hasAccessibilityPermission) { _, granted in
            showAccessibilityPermissionGuide = !granted
        }
        .onChange(of: model.remoteControlEnabled) { _, enabled in
            if enabled {
                model.refreshAccessibilityPermission()
                if !model.hasAccessibilityPermission {
                    showAccessibilityPermissionGuide = true
                }
            }
        }
    }

    private var screenCaptureGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.hasScreenRecordingPermission ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.hasScreenRecordingPermission ? .green : .orange)
                Text(model.hasScreenRecordingPermission
                     ? SPPWLocalization.tr("server.screen_permission_active")
                     : SPPWLocalization.tr("server.screen_permission_required"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.hasScreenRecordingPermission ? .green : .orange)
                Spacer()
            }

            Text(SPPWLocalization.tr("server.screen_resolution_info_fmt", model.serverScreenResolutionText))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(
                isExpanded: $showScreenPermissionGuide,
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        guideStep(
                            number: "1",
                            text: SPPWLocalization.tr("server.permission_guide_step1")
                        )
                        guideStep(
                            number: "2",
                            text: SPPWLocalization.tr("server.permission_guide_step2")
                        )
                        guideStep(
                            number: "3",
                            text: SPPWLocalization.tr("server.permission_guide_step3")
                        )
                        guideStep(
                            number: "4",
                            text: SPPWLocalization.tr("server.permission_guide_step4")
                        )

                        Divider()

                        VStack(spacing: 6) {
                            Button {
                                model.requestScreenRecordingPermission()
                            } label: {
                                Label(SPPWLocalization.tr("action.request_permission"), systemImage: "hand.raised.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                model.openScreenRecordingSettings()
                            } label: {
                                Label(SPPWLocalization.tr("action.open_system_settings"), systemImage: "gearshape.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            HStack(spacing: 6) {
                                Button {
                                    model.revealAppInFinder()
                                } label: {
                                    Label(SPPWLocalization.tr("action.show_in_finder"), systemImage: "folder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    model.refreshScreenRecordingPermission()
                                } label: {
                                    Label(SPPWLocalization.tr("action.verify"), systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 6)
                },
                label: {
                    Text(SPPWLocalization.tr("server.permission_guide_title"))
                        .font(.caption.weight(.medium))
                }
            )
        }
        .padding(10)
        .background(
            (model.hasScreenRecordingPermission ? Color.green : Color.orange).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((model.hasScreenRecordingPermission ? Color.green : Color.orange).opacity(0.35), lineWidth: 1)
        )
    }

    private var accessibilityGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.hasAccessibilityPermission ? "hand.point.up.left.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.hasAccessibilityPermission ? .green : .orange)
                Text(model.hasAccessibilityPermission
                     ? SPPWLocalization.tr("server.accessibility_permission_active")
                     : SPPWLocalization.tr("server.accessibility_permission_required"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.hasAccessibilityPermission ? .green : .orange)
                Spacer()
            }

            if !model.hasAccessibilityPermission {
                Text(SPPWLocalization.tr("server.accessibility_permission_hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(
                isExpanded: $showAccessibilityPermissionGuide,
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        guideStep(
                            number: "1",
                            text: SPPWLocalization.tr("server.accessibility_guide_step1")
                        )
                        guideStep(
                            number: "2",
                            text: SPPWLocalization.tr("server.accessibility_guide_step2")
                        )
                        guideStep(
                            number: "3",
                            text: SPPWLocalization.tr("server.accessibility_guide_step3")
                        )
                        guideStep(
                            number: "4",
                            text: SPPWLocalization.tr("server.accessibility_guide_step4")
                        )

                        Divider()

                        VStack(spacing: 6) {
                            Button {
                                model.requestAccessibilityPermission()
                            } label: {
                                Label(SPPWLocalization.tr("action.request_permission"), systemImage: "hand.raised.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                model.openAccessibilitySettings()
                            } label: {
                                Label(SPPWLocalization.tr("action.open_system_settings"), systemImage: "gearshape.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            HStack(spacing: 6) {
                                Button {
                                    model.revealAppInFinder()
                                } label: {
                                    Label(SPPWLocalization.tr("action.show_in_finder"), systemImage: "folder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    model.refreshAccessibilityPermission()
                                } label: {
                                    Label(SPPWLocalization.tr("action.verify"), systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 6)
                },
                label: {
                    Text(SPPWLocalization.tr("server.accessibility_guide_title"))
                        .font(.caption.weight(.medium))
                }
            )
        }
        .padding(10)
        .background(
            (model.hasAccessibilityPermission ? Color.green : Color.orange).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((model.hasAccessibilityPermission ? Color.green : Color.orange).opacity(0.35), lineWidth: 1)
        )
    }

    private func guideStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.caption2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileRow(
        title: String,
        path: String?,
        placeholder: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? placeholder)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(SPPWLocalization.tr("action.choose"), action: action)
                    .disabled(model.isRunning)
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 8) {
            HStack {
                Text(SPPWLocalization.tr("server.preview_header"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                if !model.previewEnabled {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(SPPWLocalization.tr("server.preview_disabled"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if model.hasPreviewFrame {
                    MetalVideoSurface(
                        framePublisher: model.previewPublisher,
                        initialPixelBuffer: model.previewPixelBuffer
                    )
                    .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(model.isRunning
                             ? SPPWLocalization.tr("server.preview_waiting_frame")
                             : SPPWLocalization.tr("server.preview_start_prompt"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Log

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SPPWLocalization.tr("server.log_title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(SPPWLocalization.tr("action.clear")) { model.logs.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logs.count) {
                    if let last = model.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
