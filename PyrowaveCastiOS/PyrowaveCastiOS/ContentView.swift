import Combine
import CoreVideo
import PhotosUI
import UIKit
import UniformTypeIdentifiers
#if canImport(SPPWCommon)
import SPPWCommon
#endif

final class IOSServerViewController: UIViewController, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private let model: IOSServerModel
    private let receiverModel: IOSReceiverModel?
    private var cancellables = Set<AnyCancellable>()
    private var shownError: String?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let stateLabel = UILabel()
    private let modeLabel = UILabel()
    private let statsLabel = UILabel()
    private let streamSettingsHeaderLabel = UILabel()
    private let sourceControl = UISegmentedControl(items: IOSServerModel.Mode.allCases.map(\.localizedTitle))
    private let portLabel = UILabel()
    private let portField = UITextField()
    private let assetLabel = UILabel()
    private let chooseAssetButton = UIButton(type: .system)
    private let startButton = UIButton(type: .system)
    private let helpLabel = UILabel()
    private let previewTitleLabel = UILabel()
    private let previewSwitch = UISwitch()
    private let previewContainer = UIView()
    private let previewSurfaceView = IOSVideoSurfaceView()
    private var pendingPickerMode: IOSServerModel.Mode = .image
    private let previewPlaceholder = UILabel()
    private let serverLogHeaderLabel = UILabel()
    private let logsView = UITextView()
    private let fileRow = UIStackView()
    private let videoSeekContainer = UIStackView()
    private let videoSeekTitleLabel = UILabel()
    private let videoTimeLabel = UILabel()
    private let videoSeekBackButton = UIButton(type: .system)
    private let videoSeekSlider = UISlider()
    private let videoSeekForwardButton = UIButton(type: .system)
    private let audioSourceRow = UIStackView()
    private let audioSourceLabel = UILabel()
    private let audioSourceButton = UIButton(type: .system)
    private let audioVolumeRow = UIStackView()
    private let audioVolumeIcon = UIImageView()
    private let audioVolumeSlider = UISlider()
    private let audioVolumeValueLabel = UILabel()
    private var lastAudioMenuSignature = ""
    private var clearBarItem: UIBarButtonItem?
    private var gearBarItem: UIBarButtonItem?
    private var lastRenderedLogCount = -1
    private var lastRenderedLastLogID: Int?

    init(model: IOSServerModel, receiverModel: IOSReceiverModel? = nil) {
        self.model = model
        self.receiverModel = receiverModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SPPWLocalization.tr("server.title")
        view.backgroundColor = .systemGroupedBackground
        let clearItem = UIBarButtonItem(
            title: SPPWLocalization.tr("action.clear_log"),
            image: UIImage(systemName: "trash"),
            primaryAction: UIAction { [weak self] _ in self?.model.clearLogs() }
        )
        self.clearBarItem = clearItem
        if let receiverModel {
            let gearItem = UIBarButtonItem(
                title: SPPWLocalization.tr("tab.settings"),
                image: UIImage(systemName: "gearshape.fill"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    let settingsVC = IOSSettingsViewController(receiverModel: receiverModel, serverModel: self.model)
                    let nav = UINavigationController(rootViewController: settingsVC)
                    if let sheet = nav.sheetPresentationController {
                        sheet.detents = [.medium(), .large()]
                        sheet.prefersGrabberVisible = true
                    }
                    self.present(nav, animated: true)
                }
            )
            self.gearBarItem = gearItem
            navigationItem.rightBarButtonItems = [gearItem, clearItem]
        } else {
            navigationItem.rightBarButtonItem = clearItem
        }
        buildInterface()
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshUI() }
            }
            .store(in: &cancellables)
        model.$previewPixelBuffer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffer in
                self?.renderPreview(buffer)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SPPWLocalization.didChangeLanguageNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastRenderedLogCount = -1
                self?.lastRenderedLastLogID = nil
                self?.refreshLocalizedStrings()
                self?.refreshUI()
            }
            .store(in: &cancellables)
        refreshLocalizedStrings()
        refreshUI()
        renderPreview(model.previewPixelBuffer)
    }

    private func refreshLocalizedStrings() {
        title = SPPWLocalization.tr("server.title")
        clearBarItem?.title = SPPWLocalization.tr("action.clear_log")
        gearBarItem?.title = SPPWLocalization.tr("tab.settings")
        streamSettingsHeaderLabel.text = SPPWLocalization.tr("server.stream_settings")
        for (idx, mode) in IOSServerModel.Mode.allCases.enumerated() where idx < sourceControl.numberOfSegments {
            sourceControl.setTitle(mode.localizedTitle, forSegmentAt: idx)
        }
        chooseAssetButton.setTitle(SPPWLocalization.tr("action.choose"), for: .normal)
        portLabel.text = SPPWLocalization.tr("receiver.control_udp_port")
        previewTitleLabel.text = SPPWLocalization.tr("server.client_preview")
        serverLogHeaderLabel.text = SPPWLocalization.tr("server.log_title")
    }

    private func buildInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 14
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18)
        ])

        contentStack.addArrangedSubview(makeStatusSection())
        contentStack.addArrangedSubview(makeSourceSection())
        contentStack.addArrangedSubview(makePreviewSection())
        contentStack.addArrangedSubview(makeLogSection())
    }

    private func makeStatusSection() -> UIView {
        let stack = sectionStack(headerLabel: nil)
        let headline = UIStackView()
        headline.axis = .horizontal
        headline.alignment = .center
        headline.spacing = 8
        let indicator = UIView()
        indicator.tag = 4001
        indicator.backgroundColor = .secondaryLabel
        indicator.layer.cornerRadius = 5
        NSLayoutConstraint.activate([indicator.widthAnchor.constraint(equalToConstant: 10), indicator.heightAnchor.constraint(equalToConstant: 10)])
        stateLabel.font = .preferredFont(forTextStyle: .headline)
        modeLabel.font = .preferredFont(forTextStyle: .caption1)
        modeLabel.textColor = .secondaryLabel
        headline.addArrangedSubview(indicator)
        headline.addArrangedSubview(stateLabel)
        headline.addArrangedSubview(UIView())
        headline.addArrangedSubview(modeLabel)
        stack.addArrangedSubview(headline)

        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statsLabel.numberOfLines = 0
        statsLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(statsLabel)
        return card(stack)
    }

    private func makeSourceSection() -> UIView {
        streamSettingsHeaderLabel.text = SPPWLocalization.tr("server.stream_settings")
        let stack = sectionStack(headerLabel: streamSettingsHeaderLabel)
        sourceControl.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)
        stack.addArrangedSubview(sourceControl)

        fileRow.axis = .horizontal
        fileRow.alignment = .center
        fileRow.spacing = 8
        assetLabel.font = .preferredFont(forTextStyle: .caption1)
        assetLabel.textColor = .secondaryLabel
        assetLabel.lineBreakMode = .byTruncatingMiddle
        assetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseAssetButton.setTitle(SPPWLocalization.tr("action.choose"), for: .normal)
        chooseAssetButton.addTarget(self, action: #selector(chooseAsset), for: .touchUpInside)
        fileRow.addArrangedSubview(assetLabel)
        fileRow.addArrangedSubview(chooseAssetButton)
        stack.addArrangedSubview(fileRow)

        videoSeekContainer.axis = .vertical
        videoSeekContainer.spacing = 6
        videoSeekContainer.isLayoutMarginsRelativeArrangement = true
        videoSeekContainer.layoutMargins = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        videoSeekContainer.backgroundColor = .tertiarySystemGroupedBackground
        videoSeekContainer.layer.cornerRadius = 10

        let seekHeaderRow = UIStackView()
        seekHeaderRow.axis = .horizontal
        seekHeaderRow.alignment = .center
        seekHeaderRow.spacing = 6
        videoSeekTitleLabel.text = "Quick Track"
        videoSeekTitleLabel.font = .preferredFont(forTextStyle: .caption1)
        videoSeekTitleLabel.textColor = .secondaryLabel
        videoTimeLabel.text = "00:00 / 00:00"
        videoTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        videoTimeLabel.textColor = .label
        seekHeaderRow.addArrangedSubview(videoSeekTitleLabel)
        seekHeaderRow.addArrangedSubview(UIView())
        seekHeaderRow.addArrangedSubview(videoTimeLabel)

        let seekControlRow = UIStackView()
        seekControlRow.axis = .horizontal
        seekControlRow.alignment = .center
        seekControlRow.spacing = 8
        videoSeekBackButton.setImage(UIImage(systemName: "gobackward.15"), for: .normal)
        videoSeekBackButton.addTarget(self, action: #selector(videoSeekBackPressed), for: .touchUpInside)
        videoSeekSlider.minimumValue = 0
        videoSeekSlider.maximumValue = 1
        videoSeekSlider.addTarget(self, action: #selector(videoSliderTouchDown), for: .touchDown)
        videoSeekSlider.addTarget(self, action: #selector(videoSliderValueChanged), for: .valueChanged)
        videoSeekSlider.addTarget(self, action: #selector(videoSliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        videoSeekForwardButton.setImage(UIImage(systemName: "goforward.15"), for: .normal)
        videoSeekForwardButton.addTarget(self, action: #selector(videoSeekForwardPressed), for: .touchUpInside)
        seekControlRow.addArrangedSubview(videoSeekBackButton)
        seekControlRow.addArrangedSubview(videoSeekSlider)
        seekControlRow.addArrangedSubview(videoSeekForwardButton)

        videoSeekContainer.addArrangedSubview(seekHeaderRow)
        videoSeekContainer.addArrangedSubview(seekControlRow)
        videoSeekContainer.isHidden = true
        stack.addArrangedSubview(videoSeekContainer)

        // Audio source (screen capture) and input volume (screen capture + video file).
        audioSourceRow.axis = .horizontal
        audioSourceRow.alignment = .center
        audioSourceRow.spacing = 8
        audioSourceLabel.text = SPPWLocalization.tr("audio.source.label")
        audioSourceLabel.font = .preferredFont(forTextStyle: .subheadline)
        audioSourceButton.showsMenuAsPrimaryAction = true
        audioSourceButton.changesSelectionAsPrimaryAction = false
        audioSourceButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        audioSourceButton.contentHorizontalAlignment = .trailing
        audioSourceRow.addArrangedSubview(audioSourceLabel)
        audioSourceRow.addArrangedSubview(UIView())
        audioSourceRow.addArrangedSubview(audioSourceButton)
        stack.addArrangedSubview(audioSourceRow)

        audioVolumeRow.axis = .horizontal
        audioVolumeRow.alignment = .center
        audioVolumeRow.spacing = 8
        audioVolumeIcon.tintColor = .secondaryLabel
        audioVolumeIcon.contentMode = .scaleAspectFit
        audioVolumeIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        audioVolumeIcon.accessibilityLabel = SPPWLocalization.tr("audio.input_volume")
        audioVolumeSlider.minimumValue = 0
        audioVolumeSlider.maximumValue = 2
        audioVolumeSlider.value = Float(model.audioInputVolume)
        audioVolumeSlider.accessibilityLabel = SPPWLocalization.tr("audio.input_volume")
        audioVolumeSlider.addTarget(self, action: #selector(audioVolumeChanged), for: .valueChanged)
        audioVolumeValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        audioVolumeValueLabel.textColor = .secondaryLabel
        audioVolumeValueLabel.textAlignment = .right
        audioVolumeValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        audioVolumeRow.addArrangedSubview(audioVolumeIcon)
        audioVolumeRow.addArrangedSubview(audioVolumeSlider)
        audioVolumeRow.addArrangedSubview(audioVolumeValueLabel)
        stack.addArrangedSubview(audioVolumeRow)

        let portRow = UIStackView()
        portRow.axis = .horizontal
        portRow.alignment = .center
        portLabel.text = SPPWLocalization.tr("receiver.control_udp_port")
        portLabel.font = .preferredFont(forTextStyle: .subheadline)
        portField.borderStyle = .roundedRect
        portField.keyboardType = .numberPad
        portField.textAlignment = .right
        portField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        portField.placeholder = "9888"
        portField.widthAnchor.constraint(equalToConstant: 115).isActive = true
        portField.addTarget(self, action: #selector(portChanged), for: .editingChanged)
        portRow.addArrangedSubview(portLabel)
        portRow.addArrangedSubview(UIView())
        portRow.addArrangedSubview(portField)
        stack.addArrangedSubview(portRow)

        startButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startButton.configuration = .filled()
        startButton.addTarget(self, action: #selector(startStopPressed), for: .touchUpInside)
        stack.addArrangedSubview(startButton)

        helpLabel.font = .preferredFont(forTextStyle: .caption1)
        helpLabel.textColor = .secondaryLabel
        helpLabel.numberOfLines = 0
        stack.addArrangedSubview(helpLabel)
        return card(stack)
    }

    private func makePreviewSection() -> UIView {
        let stack = sectionStack(headerLabel: nil)
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        previewTitleLabel.text = SPPWLocalization.tr("server.client_preview")
        previewTitleLabel.font = .preferredFont(forTextStyle: .headline)
        previewSwitch.isOn = model.previewEnabled
        previewSwitch.addTarget(self, action: #selector(previewToggled), for: .valueChanged)
        headerRow.addArrangedSubview(previewTitleLabel)
        headerRow.addArrangedSubview(UIView())
        headerRow.addArrangedSubview(previewSwitch)
        stack.addArrangedSubview(headerRow)

        previewContainer.backgroundColor = .black
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        previewContainer.heightAnchor.constraint(equalToConstant: 220).isActive = true
        previewSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        previewSurfaceView.onDiagnostic = { [weak self] message in
            self?.model.notePreviewError(message)
        }
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewPlaceholder.textColor = .secondaryLabel
        previewPlaceholder.font = .preferredFont(forTextStyle: .caption1)
        previewPlaceholder.textAlignment = .center
        previewPlaceholder.numberOfLines = 2
        previewContainer.addSubview(previewSurfaceView)
        previewContainer.addSubview(previewPlaceholder)
        NSLayoutConstraint.activate([
            previewSurfaceView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),
            previewSurfaceView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 6),
            previewSurfaceView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -6),
            previewSurfaceView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6),
            previewPlaceholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            previewPlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: previewContainer.leadingAnchor, constant: 16),
            previewPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -16)
        ])
        stack.addArrangedSubview(previewContainer)
        return card(stack)
    }

    private func makeLogSection() -> UIView {
        serverLogHeaderLabel.text = SPPWLocalization.tr("server.log_title")
        let stack = sectionStack(headerLabel: serverLogHeaderLabel)
        logsView.isEditable = false
        logsView.isScrollEnabled = true
        logsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logsView.backgroundColor = .secondarySystemGroupedBackground
        logsView.layer.cornerRadius = 10
        logsView.heightAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(logsView)
        return card(stack)
    }

    private func sectionStack(headerLabel: UILabel?) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        if let headerLabel {
            headerLabel.font = .preferredFont(forTextStyle: .headline)
            stack.addArrangedSubview(headerLabel)
        }
        return stack
    }

    private func card(_ content: UIView) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func refreshUI() {
        stateLabel.text = model.isRunning ? SPPWLocalization.tr("state.listening") : SPPWLocalization.tr("state.stopped")
        modeLabel.text = model.mode.localizedTitle
        if let dot = view.viewWithTag(4001) { dot.backgroundColor = model.isRunning ? .systemGreen : .secondaryLabel }
        statsLabel.text = [
            "CONTROL  UDP \(model.isRunning ? model.status.port : UInt16(clamping: model.port))    CLIENTS  \(model.status.connectedClients)",
            "VIDEO    \(model.status.width > 0 ? "\(model.status.width)×\(model.status.height)" : "—")    FPS  \(model.status.fps > 0 ? model.status.fps.description : "—")",
            "FRAMES   \(model.status.framesSent)    RATE  \(String(format: "%.1f", model.status.megabitsPerSecond)) Mb/s"
        ].joined(separator: "\n")

        sourceControl.selectedSegmentIndex = IOSServerModel.Mode.allCases.firstIndex(of: model.mode) ?? 0
        sourceControl.isEnabled = !model.isRunning && !model.isStartingScreenCapture
        fileRow.isHidden = model.mode != .image && model.mode != .video
        assetLabel.text = model.selectedAsset?.lastPathComponent ?? SPPWLocalization.tr("server.no_file_selected")
        let showVideoSeek = model.mode == .video && model.videoDurationSeconds > 0
        videoSeekContainer.isHidden = !showVideoSeek
        if showVideoSeek {
            let maxVal = Float(max(model.videoDurationSeconds, 1))
            if abs(videoSeekSlider.maximumValue - maxVal) > 0.1 {
                videoSeekSlider.maximumValue = maxVal
            }
            if !model.isScrubbingVideo {
                videoSeekSlider.value = Float(min(max(0, model.videoCurrentTimeSeconds), model.videoDurationSeconds))
            }
            let displayCurrent = model.isScrubbingVideo ? Double(videoSeekSlider.value) : model.videoCurrentTimeSeconds
            videoTimeLabel.text = "\(IOSServerModel.formatPlaybackTime(displayCurrent)) / \(IOSServerModel.formatPlaybackTime(model.videoDurationSeconds))"
        }
        chooseAssetButton.isEnabled = !model.isRunning
        if !portField.isFirstResponder { portField.text = String(model.port) }
        portField.isEnabled = !model.isRunning
        updateAudioControls()

        let buttonTitle: String
        if model.isRunning {
            buttonTitle = SPPWLocalization.tr("action.stop_server")
            startButton.tintColor = .systemRed
        } else if model.isStartingScreenCapture {
            buttonTitle = SPPWLocalization.tr("state.waiting_screen_permission")
            startButton.tintColor = .systemBlue
        } else {
            buttonTitle = SPPWLocalization.tr("action.start_server")
            startButton.tintColor = .systemBlue
        }
        startButton.setTitle(buttonTitle, for: .normal)
        startButton.isEnabled = model.isRunning || model.canStart

        helpLabel.text = helpText(for: model.mode)
        previewSwitch.isOn = model.previewEnabled
        let hasPreview = model.previewEnabled && model.previewPixelBuffer != nil
        previewSurfaceView.isHidden = !hasPreview
        previewPlaceholder.isHidden = hasPreview
        if !hasPreview {
            previewSurfaceView.clear()
        }
        if !model.previewEnabled {
            previewPlaceholder.text = SPPWLocalization.tr("server.preview_disabled")
        } else {
            previewPlaceholder.text = model.isRunning
                ? SPPWLocalization.tr("server.preview_waiting_frame")
                : SPPWLocalization.tr("server.preview_start_prompt")
        }

        let currentLogCount = model.logs.count
        let currentLastLogID = model.logs.last?.id
        if currentLogCount != lastRenderedLogCount || currentLastLogID != lastRenderedLastLogID {
            lastRenderedLogCount = currentLogCount
            lastRenderedLastLogID = currentLastLogID
            logsView.text = model.logs.reversed().map { entry in
                let time = entry.timestamp.formatted(date: .omitted, time: .standard)
                return "\(time)  \(entry.isError ? "ERROR  " : "")\(entry.text)"
            }.joined(separator: "\n")
            if !model.logs.isEmpty { logsView.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
        }

        if let message = model.errorMessage, message != shownError, presentedViewController == nil {
            shownError = message
            let alert = UIAlertController(title: SPPWLocalization.tr("server.title"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.model.errorMessage = nil
                self?.shownError = nil
            })
            present(alert, animated: true)
        }
    }

    private func helpText(for mode: IOSServerModel.Mode) -> String {
        switch mode {
        case .card:
            SPPWLocalization.tr("server.help.card")
        case .screen:
            SPPWLocalization.tr("server.help.screen_ios27")
        case .image:
            SPPWLocalization.tr("server.help.image")
        case .video:
            SPPWLocalization.tr("server.help.video")
        }
    }

    @objc private func sourceChanged() {
        let index = max(sourceControl.selectedSegmentIndex, 0)
        model.mode = IOSServerModel.Mode.allCases[index]
    }

    @objc private func portChanged() {
        if let value = Int(portField.text ?? ""), (1...65_534).contains(value) {
            model.port = value
        }
    }

    private func renderPreview(_ pixelBuffer: CVPixelBuffer?) {
        if model.previewEnabled, let pixelBuffer {
            previewSurfaceView.isHidden = false
            previewPlaceholder.isHidden = true
            previewSurfaceView.display(pixelBuffer)
        } else {
            previewSurfaceView.clear()
            previewSurfaceView.isHidden = true
            previewPlaceholder.isHidden = false
        }
    }

    @objc private func videoSliderTouchDown() {
        model.isScrubbingVideo = true
    }

    @objc private func videoSliderValueChanged() {
        let target = Double(videoSeekSlider.value)
        videoTimeLabel.text = "\(IOSServerModel.formatPlaybackTime(target)) / \(IOSServerModel.formatPlaybackTime(model.videoDurationSeconds))"
        if !model.isScrubbingVideo {
            model.seekVideo(to: target)
        }
    }

    @objc private func videoSliderTouchUp() {
        let target = Double(videoSeekSlider.value)
        model.isScrubbingVideo = false
        model.seekVideo(to: target)
    }

    @objc private func videoSeekBackPressed() {
        model.nudgeVideo(by: -15)
    }

    @objc private func videoSeekForwardPressed() {
        model.nudgeVideo(by: 15)
    }

    private func updateAudioControls() {
        audioSourceRow.isHidden = model.mode != .screen
        audioVolumeRow.isHidden = model.mode != .screen && model.mode != .video
        let selected = SPPWAudioSourceCatalog.source(withID: model.audioSourceID, in: model.audioSources)
        audioSourceButton.setTitle(selected.name, for: .normal)
        audioSourceButton.isEnabled = !model.isRunning && !model.isStartingScreenCapture
        let signature = model.audioSources.map(\.id).joined(separator: "|") + "#" + model.audioSourceID
        if signature != lastAudioMenuSignature {
            lastAudioMenuSignature = signature
            let items: [UIMenuElement] = model.audioSources.map { source in
                UIAction(
                    title: source.name,
                    state: source.id == model.audioSourceID ? .on : .off
                ) { [weak self] _ in
                    self?.model.audioSourceID = source.id
                }
            }
            let refresh = UIAction(
                title: SPPWLocalization.tr("audio.refresh_sources"),
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in
                self?.model.refreshAudioSources()
            }
            audioSourceButton.menu = UIMenu(children: [
                UIMenu(options: .displayInline, children: items),
                refresh
            ])
        }
        let volume = model.audioInputVolume
        if !audioVolumeSlider.isTracking {
            audioVolumeSlider.value = Float(volume)
        }
        audioVolumeValueLabel.text = "\(Int((volume * 100).rounded()))%"
        audioVolumeIcon.image = UIImage(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.2")
    }

    @objc private func audioVolumeChanged() {
        model.audioInputVolume = Double(audioVolumeSlider.value)
        audioVolumeValueLabel.text = "\(Int((model.audioInputVolume * 100).rounded()))%"
    }

    @objc private func previewToggled() {
        model.previewEnabled = previewSwitch.isOn
        if !model.previewEnabled {
            previewSurfaceView.clear()
        }
    }

    @objc private func startStopPressed() {
        if model.isRunning { model.stop() } else { model.start() }
        portField.resignFirstResponder()
    }

    @objc private func chooseAsset() {
        let targetMode = model.mode
        guard targetMode == .image || targetMode == .video else { return }
        pendingPickerMode = targetMode

        let title = targetMode == .image
            ? SPPWLocalization.tr("server.picker.select_image")
            : SPPWLocalization.tr("server.picker.select_video")
        let sheet = UIAlertController(
            title: title,
            message: SPPWLocalization.tr("server.picker.choose_source"),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: SPPWLocalization.tr("server.picker.photos_app"), style: .default) { [weak self] _ in
            self?.presentPhotoPicker(for: targetMode)
        })
        sheet.addAction(UIAlertAction(title: SPPWLocalization.tr("server.picker.files_app"), style: .default) { [weak self] _ in
            self?.presentDocumentPicker(for: targetMode)
        })
        sheet.addAction(UIAlertAction(title: SPPWLocalization.tr("action.cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = chooseAssetButton
            popover.sourceRect = chooseAssetButton.bounds
        }
        present(sheet, animated: true)
    }

    private func presentDocumentPicker(for targetMode: IOSServerModel.Mode) {
        let type: UTType = targetMode == .image ? .image : .movie
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func presentPhotoPicker(for targetMode: IOSServerModel.Mode) {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = targetMode == .image ? .images : .videos
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        model.acceptFile(url, for: pendingPickerMode)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let itemProvider = results.first?.itemProvider else { return }
        let targetMode = pendingPickerMode
        let preferredType: UTType = targetMode == .image ? .image : .movie
        let typeIdentifier: String
        if itemProvider.hasItemConformingToTypeIdentifier(preferredType.identifier) {
            typeIdentifier = preferredType.identifier
        } else if let firstMatch = itemProvider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: preferredType) == true
        }) {
            typeIdentifier = firstMatch
        } else if let fallback = itemProvider.registeredTypeIdentifiers.first {
            typeIdentifier = fallback
        } else {
            model.errorMessage = SPPWLocalization.tr("server.error.photos_unsupported")
            return
        }

        let defaultExtension = targetMode == .image ? "jpg" : "mov"
        itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] tempURL, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.model.errorMessage = SPPWLocalization.tr("server.error.photos_import_fmt", error.localizedDescription)
                }
                return
            }
            guard let tempURL else {
                Task { @MainActor [weak self] in
                    self?.model.errorMessage = SPPWLocalization.tr("server.error.photos_unavailable")
                }
                return
            }
            // Copy synchronously BEFORE this closure returns, because iOS
            // deletes `tempURL` immediately afterwards.
            do {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let originalName = tempURL.lastPathComponent
                let fileName: String
                if tempURL.pathExtension.isEmpty {
                    fileName = "\(UUID().uuidString)-\(originalName).\(defaultExtension)"
                } else {
                    fileName = "\(UUID().uuidString)-\(originalName)"
                }
                let destination = documents.appendingPathComponent(fileName)
                try FileManager.default.copyItem(at: tempURL, to: destination)
                Task { @MainActor [weak self] in
                    self?.model.acceptImportedSandboxFile(destination, for: targetMode)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.model.errorMessage = SPPWLocalization.tr("server.error.photos_copy_fmt", error.localizedDescription)
                }
            }
        }
    }
}
