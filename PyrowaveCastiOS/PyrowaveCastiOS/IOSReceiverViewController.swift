import Combine
import CoreVideo
import UIKit
import UniformTypeIdentifiers
#if canImport(SPPWCommon)
import SPPWCommon
#endif

/// Main iOS Receiver screen inspired by LocalSend:
/// - Clean, uncluttered main dashboard focused on Live Video Preview, quick Orientation toolbar,
///   Nearby Devices discovery (Bonjour), Favorites, and manual IP connection.
/// - All advanced stream request parameters (Resolution, FPS, Quality, Bitrate/ABR, FEC,
///   Wi-Fi Latency mode, CRC verification, Language, and Diagnostic Logs) are moved into
///   a dedicated Settings view accessible via the top-right gear button (`IOSSettingsViewController`).
final class IOSReceiverViewController: UIViewController {
    private let model: IOSReceiverModel
    private let serverModel: IOSServerModel?
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    // Status Banner Card (LocalSend-style pill/hero header)
    private let stateLabel = UILabel()
    private let statsSummaryLabel = UILabel()
    private let activeProfileBadge = UILabel()
    private let settingsQuickBtn = UIButton(type: .system)

    // Video Preview + Quick Orientation Bar
    private let liveStreamTitleLabel = UILabel()
    private let videoSurfaceView = IOSVideoSurfaceView()
    private let previewPlaceholder = UILabel()
    private let fullscreenButton = UIButton(type: .system)
    private let orientationSummaryLabel = UILabel()
    private let rotateButton = UIButton(type: .system)
    private let flipButton = UIButton(type: .system)
    private weak var fullscreenController: IOSFullscreenVideoViewController?

    // Nearby Devices & Favorites & Quick Connect
    private let discoveryTitleLabel = UILabel()
    private let favoritesTitleLabel = UILabel()
    private let manualConnectTitleLabel = UILabel()
    private let hostField = UITextField()
    private let portField = UITextField()
    private let favoriteStarButton = UIButton(type: .system)
    private let addFavoriteNamedButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let discoveredListStack = UIStackView()
    private let favoritesListStack = UIStackView()

    private var lastDiscoveredSnapshot: [IOSReceiverModel.DiscoveredServer] = []
    private var lastFavoritesSnapshot: [IOSReceiverModel.FavoriteServer] = []
    private var lastConnectedSnapshot: Bool?

    init(model: IOSReceiverModel, serverModel: IOSServerModel? = nil) {
        self.model = model
        self.serverModel = serverModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SPPWLocalization.tr("tab.receiver")
        navigationController?.navigationBar.prefersLargeTitles = false
        view.backgroundColor = .systemGroupedBackground

        let gearButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape.fill"),
            style: .plain,
            target: self,
            action: #selector(openSettingsPressed)
        )
        gearButton.accessibilityLabel = SPPWLocalization.tr("tab.settings")
        navigationItem.rightBarButtonItem = gearButton

        buildInterface()
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshUI() }
            }
            .store(in: &cancellables)
        model.pixelBufferSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffer in
                self?.renderInlineVideo(buffer)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SPPWLocalization.didChangeLanguageNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastConnectedSnapshot = nil
                self.refreshUI()
            }
            .store(in: &cancellables)
        refreshUI()
        renderInlineVideo(model.currentPixelBuffer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !model.isConnected {
            model.startDiscovery()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.stopDiscovery()
    }

    private func buildInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
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
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20)
        ])

        contentStack.addArrangedSubview(makeStatusHeroCard())
        contentStack.addArrangedSubview(makePreviewAndOrientationCard())
        contentStack.addArrangedSubview(makeNearbyDevicesCard())
        contentStack.addArrangedSubview(makeFavoritesCard())
        contentStack.addArrangedSubview(makeManualConnectCard())
    }

    // MARK: - Sections (LocalSend-inspired clean cards)

    private func makeStatusHeroCard() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 10

        let indicator = UIView()
        indicator.tag = 5001
        indicator.backgroundColor = .secondaryLabel
        indicator.layer.cornerRadius = 6
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 12),
            indicator.heightAnchor.constraint(equalToConstant: 12)
        ])

        stateLabel.font = .preferredFont(forTextStyle: .headline)

        activeProfileBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        activeProfileBadge.textColor = .systemBlue
        activeProfileBadge.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        activeProfileBadge.layer.cornerRadius = 8
        activeProfileBadge.clipsToBounds = true

        settingsQuickBtn.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsQuickBtn.setTitle(" " + SPPWLocalization.tr("tab.settings"), for: .normal)
        settingsQuickBtn.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        settingsQuickBtn.addTarget(self, action: #selector(openSettingsPressed), for: .touchUpInside)

        topRow.addArrangedSubview(indicator)
        topRow.addArrangedSubview(stateLabel)
        topRow.addArrangedSubview(UIView())
        topRow.addArrangedSubview(activeProfileBadge)
        topRow.addArrangedSubview(settingsQuickBtn)
        stack.addArrangedSubview(topRow)

        statsSummaryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statsSummaryLabel.numberOfLines = 2
        statsSummaryLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(statsSummaryLabel)

        return card(stack)
    }

    private func makePreviewAndOrientationCard() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8

        liveStreamTitleLabel.text = SPPWLocalization.tr("receiver.live_stream")
        liveStreamTitleLabel.font = .preferredFont(forTextStyle: .headline)

        orientationSummaryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        orientationSummaryLabel.textColor = .secondaryLabel

        var fsConfig = UIButton.Configuration.tinted()
        fsConfig.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        fsConfig.title = SPPWLocalization.tr("action.fullscreen")
        fsConfig.imagePadding = 5
        fsConfig.buttonSize = .small
        fsConfig.cornerStyle = .capsule
        fullscreenButton.configuration = fsConfig
        fullscreenButton.addTarget(self, action: #selector(openFullscreenPressed), for: .touchUpInside)

        headerRow.addArrangedSubview(liveStreamTitleLabel)
        headerRow.addArrangedSubview(orientationSummaryLabel)
        headerRow.addArrangedSubview(UIView())
        headerRow.addArrangedSubview(fullscreenButton)
        stack.addArrangedSubview(headerRow)

        let container = UIView()
        container.backgroundColor = .black
        container.layer.cornerRadius = 14
        container.clipsToBounds = true
        container.heightAnchor.constraint(equalToConstant: 230).isActive = true
        videoSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        videoSurfaceView.videoOrientation = model.videoOrientation
        videoSurfaceView.onDiagnostic = { [weak self] message in
            self?.model.noteDisplayError(message)
        }
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(openFullscreenPressed))
        container.addGestureRecognizer(tapGesture)
        container.isUserInteractionEnabled = true

        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewPlaceholder.textColor = .secondaryLabel
        previewPlaceholder.font = .preferredFont(forTextStyle: .caption1)
        previewPlaceholder.textAlignment = .center
        previewPlaceholder.numberOfLines = 2
        container.addSubview(videoSurfaceView)
        container.addSubview(previewPlaceholder)
        NSLayoutConstraint.activate([
            videoSurfaceView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            videoSurfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            videoSurfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            videoSurfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            previewPlaceholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            previewPlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            previewPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ])
        stack.addArrangedSubview(container)

        // Compact Video Orientation Control Bar (Ruota 90° CW & Flip H)
        let orientBar = UIStackView()
        orientBar.axis = .horizontal
        orientBar.distribution = .fillEqually
        orientBar.spacing = 8

        configureOrientationButton(rotateButton, title: SPPWLocalization.tr("orientation.rotate"), symbol: "rotate.right")
        rotateButton.addAction(UIAction { [weak self] _ in
            self?.model.rotateVideo()
        }, for: .touchUpInside)

        configureOrientationButton(flipButton, title: SPPWLocalization.tr("orientation.flip"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        flipButton.addAction(UIAction { [weak self] _ in
            self?.model.toggleFlip()
        }, for: .touchUpInside)

        orientBar.addArrangedSubview(rotateButton)
        orientBar.addArrangedSubview(flipButton)
        stack.addArrangedSubview(orientBar)

        return card(stack)
    }

    private func makeOrientationActionButton(title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .system)
        configureOrientationButton(btn, title: title, symbol: symbol)
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }

    private func configureOrientationButton(_ btn: UIButton, title: String, symbol: String, highlighted: Bool = false) {
        var config = highlighted ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 3
        config.buttonSize = .mini
        config.cornerStyle = .medium
        btn.configuration = config
    }

    private func makeNearbyDevicesCard() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let discoveryHeader = UIStackView()
        discoveryHeader.axis = .horizontal
        discoveryHeader.alignment = .center
        discoveryHeader.spacing = 8

        let icon = UIImageView(image: UIImage(systemName: "wifi.circle.fill"))
        icon.tintColor = .systemGreen
        icon.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])

        discoveryTitleLabel.text = SPPWLocalization.tr("discovery.nearby")
        discoveryTitleLabel.font = .preferredFont(forTextStyle: .headline)

        let refreshDiscoveryButton = UIButton(type: .system)
        refreshDiscoveryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshDiscoveryButton.addTarget(self, action: #selector(refreshDiscoveryPressed), for: .touchUpInside)

        discoveryHeader.addArrangedSubview(icon)
        discoveryHeader.addArrangedSubview(discoveryTitleLabel)
        discoveryHeader.addArrangedSubview(UIView())
        discoveryHeader.addArrangedSubview(refreshDiscoveryButton)
        stack.addArrangedSubview(discoveryHeader)

        discoveredListStack.axis = .vertical
        discoveredListStack.spacing = 8
        stack.addArrangedSubview(discoveredListStack)

        return card(stack)
    }

    private func makeFavoritesCard() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8

        let icon = UIImageView(image: UIImage(systemName: "star.circle.fill"))
        icon.tintColor = .systemYellow
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])

        favoritesTitleLabel.text = SPPWLocalization.tr("favorites.title")
        favoritesTitleLabel.font = .preferredFont(forTextStyle: .headline)

        header.addArrangedSubview(icon)
        header.addArrangedSubview(favoritesTitleLabel)
        header.addArrangedSubview(UIView())
        stack.addArrangedSubview(header)

        favoritesListStack.axis = .vertical
        favoritesListStack.spacing = 8
        stack.addArrangedSubview(favoritesListStack)

        return card(stack)
    }

    private func makeManualConnectCard() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        manualConnectTitleLabel.text = SPPWLocalization.tr("receiver.direct_ip_port")
        manualConnectTitleLabel.font = .preferredFont(forTextStyle: .headline)
        stack.addArrangedSubview(manualConnectTitleLabel)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        hostField.borderStyle = .roundedRect
        hostField.placeholder = "192.168.1.20"
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.keyboardType = .numbersAndPunctuation
        hostField.addKeyboardDismissBar()
        hostField.text = model.host
        hostField.addTarget(self, action: #selector(hostChanged), for: .editingChanged)

        portField.borderStyle = .roundedRect
        portField.keyboardType = .numberPad
        portField.addKeyboardDismissBar()
        portField.textAlignment = .center
        portField.placeholder = "9888"
        portField.text = model.portText
        portField.widthAnchor.constraint(equalToConstant: 78).isActive = true
        portField.addTarget(self, action: #selector(portChanged), for: .editingChanged)

        favoriteStarButton.setImage(UIImage(systemName: "star"), for: .normal)
        favoriteStarButton.addTarget(self, action: #selector(toggleFavoritePressed), for: .touchUpInside)
        favoriteStarButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        addFavoriteNamedButton.setImage(UIImage(systemName: "plus.circle"), for: .normal)
        addFavoriteNamedButton.addTarget(self, action: #selector(addNamedFavoritePressed), for: .touchUpInside)
        addFavoriteNamedButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        row.addArrangedSubview(hostField)
        row.addArrangedSubview(portField)
        row.addArrangedSubview(favoriteStarButton)
        row.addArrangedSubview(addFavoriteNamedButton)
        stack.addArrangedSubview(row)

        var btnConfig = UIButton.Configuration.filled()
        btnConfig.cornerStyle = .medium
        btnConfig.buttonSize = .large
        connectButton.configuration = btnConfig
        connectButton.addTarget(self, action: #selector(connectPressed), for: .touchUpInside)
        stack.addArrangedSubview(connectButton)

        return card(stack)
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

    // MARK: - Refresh UI

    private func refreshUI() {
        title = SPPWLocalization.tr("tab.receiver")
        navigationItem.rightBarButtonItem?.accessibilityLabel = SPPWLocalization.tr("tab.settings")
        settingsQuickBtn.setTitle(" " + SPPWLocalization.tr("tab.settings"), for: .normal)
        liveStreamTitleLabel.text = SPPWLocalization.tr("receiver.live_stream")
        discoveryTitleLabel.text = SPPWLocalization.tr("discovery.nearby")
        favoritesTitleLabel.text = SPPWLocalization.tr("favorites.title")
        manualConnectTitleLabel.text = SPPWLocalization.tr("receiver.direct_ip_port")

        var fsConfig = fullscreenButton.configuration ?? .tinted()
        fsConfig.title = SPPWLocalization.tr("action.fullscreen")
        fullscreenButton.configuration = fsConfig

        stateLabel.text = model.state.label
        if let dot = view.viewWithTag(5001) {
            switch model.state {
            case .streaming: dot.backgroundColor = .systemGreen
            case .connecting, .waiting, .reconnecting: dot.backgroundColor = .systemOrange
            case .disconnected, .failed: dot.backgroundColor = .secondaryLabel
            }
        }

        let targetMbps = model.automaticBitrate
            ? (model.activeAutoBitrateMbps > 0 ? "Auto \(Int(model.activeAutoBitrateMbps))M" : "Auto")
            : "\(Int(model.bitrateMbps))M"
        activeProfileBadge.text = "  \(model.width)×\(model.height) · \(model.fps)fps · \(targetMbps)  "

        let s = model.statistics
        let resText = s.frameWidth > 0 ? "\(s.frameWidth)×\(s.frameHeight)" : "—"
        statsSummaryLabel.text = [
            "VIDEO \(resText)  ·  RATE \(String(format: "%.1f", s.receivedMbps)) Mb/s  ·  DECODE \(String(format: "%.1f", s.decodeMilliseconds)) ms",
            "FRAMES \(s.decodedFrames)  ·  FEC \(s.fecRecoveredFrames)  ·  PARTIAL-HF \(s.partialHFFrames)  ·  JITTER \(String(format: "%.1f", s.jitterMilliseconds)) ms"
        ].joined(separator: "\n")

        // Sync video orientation state
        if videoSurfaceView.videoOrientation != model.videoOrientation {
            videoSurfaceView.videoOrientation = model.videoOrientation
        }
        fullscreenController?.syncVideoOrientation(model.videoOrientation)
        orientationSummaryLabel.text = model.videoOrientation.summaryLabel
        configureOrientationButton(
            rotateButton,
            title: SPPWLocalization.tr("orientation.rotate"),
            symbol: "rotate.right",
            highlighted: model.videoOrientation.quarterTurnsClockwise != 0
        )
        configureOrientationButton(
            flipButton,
            title: SPPWLocalization.tr("orientation.flip"),
            symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            highlighted: model.videoOrientation.isFlippedHorizontally
        )

        let connected = model.isConnected
        var btnConfig = connectButton.configuration ?? .filled()
        btnConfig.title = connected ? SPPWLocalization.tr("action.disconnect") : SPPWLocalization.tr("action.connect")
        btnConfig.image = UIImage(systemName: connected ? "xmark.circle.fill" : "dot.radiowaves.left.and.right")
        btnConfig.imagePadding = 8
        btnConfig.baseBackgroundColor = connected ? .systemRed : .systemBlue
        connectButton.configuration = btnConfig

        hostField.isEnabled = !connected
        portField.isEnabled = !connected
        if !hostField.isFirstResponder { hostField.text = model.host }
        if !portField.isFirstResponder { portField.text = model.portText }
        favoriteStarButton.setImage(
            UIImage(systemName: model.isCurrentHostFavorite ? "star.fill" : "star"),
            for: .normal
        )
        favoriteStarButton.tintColor = model.isCurrentHostFavorite ? .systemYellow : .secondaryLabel

        if lastDiscoveredSnapshot != model.discoveredServers ||
           lastFavoritesSnapshot != model.favorites ||
           lastConnectedSnapshot != connected {
            lastDiscoveredSnapshot = model.discoveredServers
            lastFavoritesSnapshot = model.favorites
            lastConnectedSnapshot = connected
            rebuildDiscoveryAndFavoritesLists()
        }

        let hasVideo = model.hasVideoFrame
        videoSurfaceView.isHidden = !hasVideo
        previewPlaceholder.isHidden = hasVideo
        if case .reconnecting = model.state {
            previewPlaceholder.text = model.state.label
        } else {
            previewPlaceholder.text = connected
                ? SPPWLocalization.tr("receiver.waiting_video")
                : SPPWLocalization.tr("receiver.tap_connect_or_nearby")
        }
    }

    @objc private func openSettingsPressed() {
        let settingsVC = IOSSettingsViewController(receiverModel: model, serverModel: serverModel)
        let nav = UINavigationController(rootViewController: settingsVC)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    @objc private func hostChanged() {
        model.host = hostField.text ?? ""
    }

    @objc private func portChanged() {
        model.portText = portField.text ?? ""
    }

    @objc private func connectPressed() {
        if model.isConnected {
            model.disconnect()
        } else {
            model.connect()
        }
        view.endEditing(true)
    }

    @objc private func toggleFavoritePressed() {
        model.toggleCurrentFavorite()
    }

    @objc private func refreshDiscoveryPressed() {
        model.startDiscovery()
    }

    @objc private func addNamedFavoritePressed() {
        let alert = UIAlertController(
            title: SPPWLocalization.tr("favorites.save_title"),
            message: "\(model.host):\(model.portText)",
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] tf in
            tf.placeholder = SPPWLocalization.tr("favorites.server_name_placeholder")
            tf.text = self?.model.host
        }
        alert.addAction(UIAlertAction(title: SPPWLocalization.tr("action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SPPWLocalization.tr("action.save"), style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text
            self?.model.addFavorite(name: name)
        })
        present(alert, animated: true)
    }

    private func rebuildDiscoveryAndFavoritesLists() {
        for sub in discoveredListStack.arrangedSubviews {
            discoveredListStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        if model.discoveredServers.isEmpty {
            let empty = UILabel()
            empty.text = SPPWLocalization.tr("discovery.empty")
            empty.font = .preferredFont(forTextStyle: .caption1)
            empty.textColor = .secondaryLabel
            empty.numberOfLines = 0
            discoveredListStack.addArrangedSubview(empty)
        } else {
            for server in model.discoveredServers {
                let row = makeDeviceTile(
                    name: server.name,
                    address: "\(server.host):\(server.port)",
                    symbol: "desktopcomputer",
                    tint: .systemGreen,
                    onUse: { [weak self] in
                        self?.model.selectDiscovered(server, connectImmediately: false)
                    },
                    onConnect: { [weak self] in
                        self?.model.selectDiscovered(server, connectImmediately: true)
                    },
                    trailingActionIcon: "star",
                    trailingTint: .secondaryLabel,
                    onTrailing: { [weak self] in
                        guard let self else { return }
                        self.model.host = server.host
                        self.model.portText = String(server.port)
                        self.model.addFavorite(name: server.name)
                    }
                )
                discoveredListStack.addArrangedSubview(row)
            }
        }

        for sub in favoritesListStack.arrangedSubviews {
            favoritesListStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        if model.favorites.isEmpty {
            let empty = UILabel()
            empty.text = SPPWLocalization.tr("favorites.empty")
            empty.font = .preferredFont(forTextStyle: .caption1)
            empty.textColor = .secondaryLabel
            favoritesListStack.addArrangedSubview(empty)
        } else {
            for fav in model.favorites {
                let row = makeDeviceTile(
                    name: fav.name,
                    address: "\(fav.host):\(fav.port)",
                    symbol: "star.fill",
                    tint: .systemYellow,
                    onUse: { [weak self] in
                        self?.model.selectFavorite(fav, connectImmediately: false)
                    },
                    onConnect: { [weak self] in
                        self?.model.selectFavorite(fav, connectImmediately: true)
                    },
                    trailingActionIcon: "trash",
                    trailingTint: .systemRed,
                    onTrailing: { [weak self] in
                        self?.model.removeFavorite(fav)
                    }
                )
                favoritesListStack.addArrangedSubview(row)
            }
        }
    }

    private func makeDeviceTile(
        name: String,
        address: String,
        symbol: String,
        tint: UIColor,
        onUse: @escaping () -> Void,
        onConnect: @escaping () -> Void,
        trailingActionIcon: String,
        trailingTint: UIColor,
        onTrailing: @escaping () -> Void
    ) -> UIView {
        let tile = UIView()
        tile.backgroundColor = .tertiarySystemGroupedBackground
        tile.layer.cornerRadius = 12

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: tile.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -10)
        ])

        let avatar = UIImageView(image: UIImage(systemName: symbol))
        avatar.tintColor = tint
        avatar.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 24),
            avatar.heightAnchor.constraint(equalToConstant: 24)
        ])

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.lineBreakMode = .byTruncatingTail
        let addressLabel = UILabel()
        addressLabel.text = address
        addressLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addressLabel.textColor = .secondaryLabel
        addressLabel.lineBreakMode = .byTruncatingMiddle
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(addressLabel)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var useConfig = UIButton.Configuration.tinted()
        useConfig.title = SPPWLocalization.tr("action.use")
        useConfig.buttonSize = .small
        useConfig.cornerStyle = .capsule
        let useBtn = UIButton(configuration: useConfig, primaryAction: UIAction { _ in onUse() })

        var connectConfig = UIButton.Configuration.filled()
        connectConfig.title = SPPWLocalization.tr("action.connect")
        connectConfig.buttonSize = .small
        connectConfig.cornerStyle = .capsule
        let connectBtn = UIButton(configuration: connectConfig, primaryAction: UIAction { _ in onConnect() })

        let trailingBtn = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: trailingActionIcon)) { _ in onTrailing() }
        )
        trailingBtn.tintColor = trailingTint

        row.addArrangedSubview(avatar)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(UIView())
        row.addArrangedSubview(useBtn)
        row.addArrangedSubview(connectBtn)
        row.addArrangedSubview(trailingBtn)
        return tile
    }

    private func renderInlineVideo(_ pixelBuffer: CVPixelBuffer?) {
        if let pixelBuffer {
            videoSurfaceView.isHidden = false
            previewPlaceholder.isHidden = true
            if fullscreenController == nil {
                videoSurfaceView.display(pixelBuffer)
            }
        } else {
            videoSurfaceView.clear()
            videoSurfaceView.isHidden = true
            previewPlaceholder.isHidden = false
        }
    }

    @objc private func openFullscreenPressed() {
        guard fullscreenController == nil, presentedViewController == nil else { return }
        let fs = IOSFullscreenVideoViewController(model: model) { [weak self] in
            guard let self else { return }
            self.fullscreenController = nil
            self.renderInlineVideo(self.model.currentPixelBuffer)
        }
        fullscreenController = fs
        present(fs, animated: true)
    }
}

// MARK: - Dedicated Full-Screen Video Player with Orientation HUD

final class IOSFullscreenVideoViewController: UIViewController {
    private let model: IOSReceiverModel
    private let onDismiss: () -> Void
    private var cancellables = Set<AnyCancellable>()

    private let videoSurfaceView = IOSVideoSurfaceView()
    private let placeholderLabel = UILabel()
    private let hudContainer = IOSPassthroughView()
    /// Holds every on-screen control and turns with the video (rotate button), so the
    /// controls read the right way when the picture is watched sideways. Frame-managed in
    /// `layoutControlsOverlay()`; the mirror flip never applies to it.
    private let controlsOverlay = IOSPassthroughView()
    /// Safe area inside `controlsOverlay`, rotated from the screen's insets.
    private let overlaySafe = UILayoutGuide()
    private var overlaySafeConstraints: [NSLayoutConstraint] = []
    /// Invisible view pinned to the keyboard's top edge: the overlay ends above the keyboard.
    private let keyboardProbe = UIView()
    private let zoomButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let orientationToolbar = UIStackView()
    private let statsBadge = UILabel()
    private var hudVisible = true
    private var hudHideTask: Task<Void, Never>?

    // Remote control (keyboard, mouse, clipboard → Mac)
    private let touchInputView = IOSTouchInputView()
    /// Receiver-drawn pointer at the Mac's click position (the Mac cursor is left out of the video).
    private let pointerView = IOSLocalPointerView()
    private lazy var pasteControl: UIPasteControl = {
        var config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.cornerStyle = .capsule
        config.baseBackgroundColor = IOSRemoteStyle.buttonBackground
        config.baseForegroundColor = .white
        let control = UIPasteControl(configuration: config)
        control.target = self
        return control
    }()
    private lazy var dock = IOSRemoteInputDock(pasteControl: pasteControl)
    private let showControlsButton = UIButton(type: .system)
    private let specialKeysPanel = IOSSpecialKeysPanel()
    private let keyboardField = IOSRemoteKeyboardField()
    private let compositionLabel = IOSPaddedLabel()
    private let hintLabel = IOSPaddedLabel()
    private let mouseInput = IOSHardwareMouseInput()
    private let keyRepeater = IOSKeyRepeater()
    private var rightClickArmed = false
    private var specialKeysVisible = false
    private var dockBottomToKeyboard: NSLayoutConstraint?
    private var dockBottomToPanel: NSLayoutConstraint?
    private var hintHideTask: Task<Void, Never>?

    init(model: IOSReceiverModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    /// With an iPad mouse/trackpad connected the pointer is locked so all motion goes to the Mac.
    override var prefersPointerLocked: Bool { mouseInput.isConnected }
    /// First responder for hardware keyboards when the on-screen keyboard is not up.
    override var canBecomeFirstResponder: Bool { true }
    /// Keep system edge gestures from stealing trackpad drags near the screen edges.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        videoSurfaceView.videoOrientation = model.videoOrientation
        videoSurfaceView.onDiagnostic = { [weak self] message in
            self?.model.noteDisplayError(message)
        }
        view.addSubview(videoSurfaceView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .preferredFont(forTextStyle: .callout)
        placeholderLabel.textAlignment = .center
        placeholderLabel.text = SPPWLocalization.tr("receiver.waiting_video")
        view.addSubview(placeholderLabel)

        touchInputView.translatesAutoresizingMaskIntoConstraints = false
        touchInputView.model = model
        touchInputView.mode = model.remoteInputMode
        touchInputView.consumeRightClickArm = { [weak self] in
            guard let self, self.rightClickArmed else { return false }
            self.rightClickArmed = false
            self.refreshDock()
            return true
        }
        touchInputView.onToggleControls = { [weak self] in
            guard let self else { return }
            self.setControlsVisible(!self.hudVisible)
        }
        touchInputView.onZoomChanged = { [weak self] zoom in
            self?.applyZoom(zoom)
        }
        view.addSubview(touchInputView)
        pointerView.isHidden = true
        touchInputView.addSubview(pointerView)

        keyboardProbe.translatesAutoresizingMaskIntoConstraints = false
        keyboardProbe.isHidden = true
        keyboardProbe.isUserInteractionEnabled = false
        view.addSubview(keyboardProbe)

        controlsOverlay.backgroundColor = .clear
        controlsOverlay.translatesAutoresizingMaskIntoConstraints = true
        controlsOverlay.frame = view.bounds
        view.addSubview(controlsOverlay)
        controlsOverlay.addLayoutGuide(overlaySafe)
        overlaySafeConstraints = [
            overlaySafe.topAnchor.constraint(equalTo: controlsOverlay.topAnchor),
            overlaySafe.leadingAnchor.constraint(equalTo: controlsOverlay.leadingAnchor),
            controlsOverlay.bottomAnchor.constraint(equalTo: overlaySafe.bottomAnchor),
            controlsOverlay.trailingAnchor.constraint(equalTo: overlaySafe.trailingAnchor)
        ]
        NSLayoutConstraint.activate(overlaySafeConstraints)

        hudContainer.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.backgroundColor = .clear
        controlsOverlay.addSubview(hudContainer)

        var closeConfig = UIButton.Configuration.filled()
        closeConfig.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")
        closeConfig.title = SPPWLocalization.tr("action.exit_fullscreen")
        closeConfig.imagePadding = 6
        closeConfig.cornerStyle = .capsule
        closeConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
        closeConfig.baseForegroundColor = .white
        closeConfig.buttonSize = .medium
        closeButton.configuration = closeConfig
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closePressed), for: .touchUpInside)
        hudContainer.addSubview(closeButton)

        // Floating Orientation Toolbar in Fullscreen HUD (Ruota & Flip)
        orientationToolbar.axis = .horizontal
        orientationToolbar.spacing = 8
        orientationToolbar.alignment = .center
        orientationToolbar.translatesAutoresizingMaskIntoConstraints = false
        orientationToolbar.addArrangedSubview(makeHUDButton(symbol: "rotate.right", title: SPPWLocalization.tr("orientation.rotate")) { [weak self] in
            self?.model.rotateVideo()
        })
        orientationToolbar.addArrangedSubview(makeHUDButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: SPPWLocalization.tr("orientation.flip")) { [weak self] in
            self?.model.toggleFlip()
        })
        var zoomConfig = UIButton.Configuration.filled()
        zoomConfig.image = UIImage(systemName: "minus.magnifyingglass")
        zoomConfig.imagePadding = 4
        zoomConfig.cornerStyle = .capsule
        zoomConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
        zoomConfig.baseForegroundColor = .white
        zoomConfig.buttonSize = .small
        zoomButton.configuration = zoomConfig
        zoomButton.accessibilityHint = SPPWLocalization.tr("zoom.reset_help")
        zoomButton.isHidden = true
        zoomButton.addAction(UIAction { [weak self] _ in self?.resetZoom() }, for: .touchUpInside)
        orientationToolbar.addArrangedSubview(zoomButton)
        hudContainer.addSubview(orientationToolbar)

        statsBadge.translatesAutoresizingMaskIntoConstraints = false
        statsBadge.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        statsBadge.textColor = .white
        statsBadge.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statsBadge.layer.cornerRadius = 12
        statsBadge.clipsToBounds = true
        statsBadge.textAlignment = .center
        hudContainer.addSubview(statsBadge)

        NSLayoutConstraint.activate([
            videoSurfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            videoSurfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoSurfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoSurfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            keyboardProbe.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            keyboardProbe.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardProbe.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardProbe.widthAnchor.constraint(equalToConstant: 1),

            hudContainer.topAnchor.constraint(equalTo: controlsOverlay.topAnchor),
            hudContainer.leadingAnchor.constraint(equalTo: controlsOverlay.leadingAnchor),
            hudContainer.trailingAnchor.constraint(equalTo: controlsOverlay.trailingAnchor),
            hudContainer.bottomAnchor.constraint(equalTo: controlsOverlay.bottomAnchor),

            orientationToolbar.topAnchor.constraint(equalTo: overlaySafe.topAnchor, constant: 12),
            orientationToolbar.leadingAnchor.constraint(equalTo: overlaySafe.leadingAnchor, constant: 16),

            closeButton.topAnchor.constraint(equalTo: overlaySafe.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: overlaySafe.trailingAnchor, constant: -16),

            statsBadge.leadingAnchor.constraint(equalTo: overlaySafe.leadingAnchor, constant: 16),
            statsBadge.bottomAnchor.constraint(equalTo: overlaySafe.bottomAnchor, constant: -16),
            statsBadge.heightAnchor.constraint(equalToConstant: 28)
        ])

        NSLayoutConstraint.activate([
            touchInputView.topAnchor.constraint(equalTo: view.topAnchor),
            touchInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchInputView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            touchInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // The HUD container covers the screen; touches outside its controls reach the touch surface.
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier, UTType.text.identifier, UTType.image.identifier
        ])
        buildRemoteControls()

        model.pixelBufferSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffer in
                self?.render(buffer)
            }
            .store(in: &cancellables)

        model.$videoOrientation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] orient in
                self?.syncVideoOrientation(orient)
            }
            .store(in: &cancellables)

        model.$statistics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatsBadge()
                self?.updateLocalPointer()
            }
            .store(in: &cancellables)

        model.localPointerSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLocalPointer() }
            .store(in: &cancellables)

        model.$stickyModifiers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDock() }
            .store(in: &cancellables)

        model.$remoteInputMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.touchInputView.mode = mode
                self.refreshDock()
                self.syncRemoteCursorVisibility(mode: mode)
            }
            .store(in: &cancellables)

        render(model.currentPixelBuffer)
        refreshStatsBadge()
        refreshDock()
        showHint()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        mouseInput.model = model
        mouseInput.onConnectionChange = { [weak self] _ in
            self?.setNeedsUpdateOfPrefersPointerLocked()
            self?.syncRemoteCursorVisibility()
        }
        mouseInput.start()
        setNeedsUpdateOfPrefersPointerLocked()
        syncRemoteCursorVisibility()
        becomeFirstResponder()
    }

    /// The receiver draws its own pointer (`pointerView`) in every mode, at the exact
    /// position it sends to the Mac, so the Mac leaves its delayed cursor out of the video.
    private func syncRemoteCursorVisibility(mode: IOSRemoteInputMode? = nil) {
        model.setRemoteCursorHidden(true)
    }

    /// Places the local pointer over the picture (aspect fit, rotation, mirror and zoom) and
    /// tells the model the displayed video size that relative motion is measured against.
    private func updateLocalPointer() {
        let bounds = touchInputView.bounds
        let stats = model.statistics
        let orientation = model.videoOrientation
        guard bounds.width > 0, bounds.height > 0, stats.frameWidth > 0, stats.frameHeight > 0,
              model.currentPixelBuffer != nil,
              let size = SPPWLocalPointer.displayedVideoSize(
                viewWidth: Double(bounds.width),
                viewHeight: Double(bounds.height),
                videoWidth: Double(stats.frameWidth),
                videoHeight: Double(stats.frameHeight),
                orientation: orientation
              ),
              let content = SPPWInputCoordinateMapper.uiKitViewPoint(
                normalizedX: model.localPointer.normalizedX,
                normalizedY: model.localPointer.normalizedY,
                viewWidth: Double(bounds.width),
                viewHeight: Double(bounds.height),
                videoWidth: Double(stats.frameWidth),
                videoHeight: Double(stats.frameHeight),
                orientation: orientation
              ) else {
            pointerView.isHidden = true
            return
        }
        model.pointerViewport = size
        let point = touchInputView.zoom.viewPoint(
            contentX: content.x,
            contentY: content.y,
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height)
        )
        pointerView.place(tipAt: CGPoint(x: point.x, y: point.y))
        pointerView.isHidden = false
    }

    // MARK: Remote control

    private func buildRemoteControls() {
        keyboardField.translatesAutoresizingMaskIntoConstraints = false
        keyboardField.onText = { [weak self] text in self?.model.sendTypedText(text) }
        keyboardField.onDeleteBackward = { [weak self] in self?.model.sendDeleteBackward() }
        keyboardField.onComposition = { [weak self] marked in self?.showComposition(marked) }
        keyboardField.onHardwareKey = { [weak self] key, isDown in self?.handleHardwareKey(key, isDown: isDown) }
        view.addSubview(keyboardField)

        specialKeysPanel.translatesAutoresizingMaskIntoConstraints = false
        specialKeysPanel.isHidden = true
        specialKeysPanel.onKey = { [weak self] key in self?.model.sendSpecialKey(key) }
        specialKeysPanel.onShowName = { [weak self] name in self?.showHint(name) }
        controlsOverlay.addSubview(specialKeysPanel)

        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.onAction = { [weak self] action in self?.handleDockAction(action) }
        hudContainer.addSubview(dock)

        var showConfig = UIButton.Configuration.filled()
        showConfig.image = UIImage(systemName: "chevron.up")
        showConfig.cornerStyle = .capsule
        showConfig.baseBackgroundColor = IOSRemoteStyle.dockBackground
        showConfig.baseForegroundColor = .white
        showControlsButton.configuration = showConfig
        showControlsButton.accessibilityLabel = SPPWLocalization.tr("remote.dock.show")
        showControlsButton.translatesAutoresizingMaskIntoConstraints = false
        showControlsButton.alpha = 0
        showControlsButton.isHidden = true
        showControlsButton.addAction(UIAction { [weak self] _ in self?.setControlsVisible(true) }, for: .touchUpInside)
        controlsOverlay.addSubview(showControlsButton)

        for label in [compositionLabel, hintLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.backgroundColor = IOSRemoteStyle.dockBackground
            label.textColor = UIColor(white: 0.85, alpha: 1)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textAlignment = .center
            label.numberOfLines = 2
            label.layer.cornerRadius = 14
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            label.alpha = 0
            label.isUserInteractionEnabled = false
            controlsOverlay.addSubview(label)
        }
        compositionLabel.font = .systemFont(ofSize: 17, weight: .regular)
        compositionLabel.textColor = .white

        // The system keyboard can also be dismissed by its own hide key.
        NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.showComposition(nil)
                if !self.keyboardField.isFirstResponder { self.becomeFirstResponder() }
                self.refreshDock()
            }
            .store(in: &cancellables)

        // The overlay already ends at the keyboard, so its safe bottom is the keyboard's top.
        let keyboardTop = overlaySafe.bottomAnchor
        let safe = overlaySafe
        let toKeyboard = dock.bottomAnchor.constraint(equalTo: keyboardTop, constant: -12)
        let toPanel = dock.bottomAnchor.constraint(equalTo: specialKeysPanel.topAnchor, constant: -8)
        dockBottomToKeyboard = toKeyboard
        dockBottomToPanel = toPanel
        NSLayoutConstraint.activate([
            keyboardField.widthAnchor.constraint(equalToConstant: 1),
            keyboardField.heightAnchor.constraint(equalToConstant: 1),
            keyboardField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardField.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            specialKeysPanel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            specialKeysPanel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            specialKeysPanel.bottomAnchor.constraint(equalTo: controlsOverlay.bottomAnchor),
            specialKeysPanel.heightAnchor.constraint(lessThanOrEqualTo: controlsOverlay.heightAnchor, multiplier: 0.6),

            toKeyboard,
            dock.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 12),
            dock.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -12),

            showControlsButton.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            showControlsButton.bottomAnchor.constraint(equalTo: keyboardTop, constant: -12),
            showControlsButton.widthAnchor.constraint(equalToConstant: 44),
            showControlsButton.heightAnchor.constraint(equalToConstant: 30),

            compositionLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            compositionLabel.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -8),
            compositionLabel.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -32),

            hintLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -10),
            hintLabel.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -32)
        ])
    }

    private func handleDockAction(_ action: IOSRemoteInputDock.Action) {
        switch action {
        case .toggleMode:
            model.remoteInputMode = model.remoteInputMode == .trackpad ? .directTouch : .trackpad
            showHint()
        case .toggleKeyboard:
            if keyboardField.isFirstResponder {
                keyboardField.resignFirstResponder()
                becomeFirstResponder()
            } else {
                setSpecialKeysVisible(false)
                keyboardField.becomeFirstResponder()
            }
        case .toggleSpecialKeys:
            if !specialKeysVisible, keyboardField.isFirstResponder {
                keyboardField.resignFirstResponder()
                becomeFirstResponder()
            }
            setSpecialKeysVisible(!specialKeysVisible)
        case .toggleRightClick:
            rightClickArmed.toggle()
        case .collapse:
            setControlsVisible(false)
        case let .modifierTap(modifier):
            model.stickyModifiers.tap(modifier)
        case let .modifierLock(modifier):
            model.stickyModifiers.lock(modifier)
        }
        refreshDock()
    }

    private func refreshDock() {
        dock.update(
            mode: model.remoteInputMode,
            keyboardActive: keyboardField.isFirstResponder,
            specialKeysVisible: specialKeysVisible,
            modifiers: model.stickyModifiers,
            rightClickArmed: rightClickArmed
        )
    }

    private func setSpecialKeysVisible(_ visible: Bool) {
        guard specialKeysVisible != visible else { return }
        specialKeysVisible = visible
        if visible {
            specialKeysPanel.refreshTexts()
            specialKeysPanel.isHidden = false
            specialKeysPanel.transform = CGAffineTransform(translationX: 0, y: 40)
            specialKeysPanel.alpha = 0
        }
        dockBottomToKeyboard?.isActive = !visible
        dockBottomToPanel?.isActive = visible
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.specialKeysPanel.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 40)
            self.specialKeysPanel.alpha = visible ? 1 : 0
            self.view.layoutIfNeeded()
            self.controlsOverlay.layoutIfNeeded()
        } completion: { _ in
            if !self.specialKeysVisible { self.specialKeysPanel.isHidden = true }
        }
        refreshDock()
    }

    /// Dock, top buttons and stats come and go together (dock chevron, handle, three-finger tap).
    private func setControlsVisible(_ visible: Bool) {
        hudVisible = visible
        if !visible {
            setSpecialKeysVisible(false)
            if keyboardField.isFirstResponder {
                keyboardField.resignFirstResponder()
                becomeFirstResponder()
            }
        }
        showControlsButton.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.hudContainer.alpha = visible ? 1 : 0
            self.showControlsButton.alpha = visible ? 0 : 1
        } completion: { _ in
            self.showControlsButton.isHidden = self.hudVisible
        }
        refreshDock()
    }

    private func showComposition(_ marked: String?) {
        let text = marked ?? ""
        compositionLabel.text = text
        UIView.animate(withDuration: 0.12) {
            self.compositionLabel.alpha = text.isEmpty ? 0 : 1
        }
    }

    /// Gesture hint for the current touch mode, or a key name from the special keys sheet.
    private func showHint(_ text: String? = nil) {
        hintLabel.text = text ?? (model.remoteInputMode == .trackpad
            ? SPPWLocalization.tr("remote.hint.trackpad")
            : SPPWLocalization.tr("remote.hint.direct"))
        hintHideTask?.cancel()
        UIView.animate(withDuration: 0.15) { self.hintLabel.alpha = 1 }
        hintHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: text == nil ? 4_000_000_000 : 1_500_000_000) } catch { return }
            UIView.animate(withDuration: 0.3) { self?.hintLabel.alpha = 0 }
        }
    }

    // MARK: Hardware keyboard

    private func handleHardwareKey(_ key: UIKey, isDown: Bool) {
        guard let keyCode = IOSHardwareKeys.macKeyCode(key) else { return }
        let modifiers = IOSHardwareKeys.modifiers(key.modifierFlags)
        model.sendHardwareKey(keyCode: keyCode, isDown: isDown, modifiers: modifiers)
        if isDown {
            keyRepeater.send = { [weak self] event in self?.model.sendInputEvent(event) }
            keyRepeater.keyDown(keyCode: keyCode, modifiers: modifiers)
        } else {
            keyRepeater.keyUp(keyCode: keyCode)
        }
    }

    /// Without the on-screen keyboard, every hardware key goes to the Mac as a key code, so the
    /// Mac's own keyboard layout and input source apply.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, IOSHardwareKeys.macKeyCode(key) != nil {
                handleHardwareKey(key, isDown: true)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, IOSHardwareKeys.macKeyCode(key) != nil {
                handleHardwareKey(key, isDown: false)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyRepeater.stop()
        pressesEnded(presses, with: event)
    }

    // MARK: Clipboard (iPhone → Mac on an explicit paste)

    override func paste(itemProviders: [NSItemProvider]) {
        Task { @MainActor [weak self] in
            guard let content = await IOSClipboardBridge.content(from: itemProviders) else { return }
            self?.model.sendClipboardToHost(content)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func syncVideoOrientation(_ orientation: SPPWVideoOrientation) {
        if videoSurfaceView.videoOrientation != orientation {
            videoSurfaceView.videoOrientation = orientation
        }
        guard isViewLoaded, controlsOverlay.bounds.width > 0 else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.layoutControlsOverlay()
            self.updateLocalPointer()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutControlsOverlay()
        updateLocalPointer()
        // Size changed (device rotation): keep the zoomed picture covering the screen.
        var zoom = touchInputView.zoom
        zoom.clampOffset(viewWidth: Double(view.bounds.width), viewHeight: Double(view.bounds.height))
        if zoom != touchInputView.zoom {
            touchInputView.zoom = zoom
            applyZoom(zoom)
        }
    }

    /// Places the controls over the area above the keyboard, turned like the video.
    private func layoutControlsOverlay() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let safe = view.safeAreaInsets
        let keyboardTop = keyboardProbe.frame.minY
        // The probe sits at the safe-area bottom while the keyboard is hidden.
        let keyboardVisible = keyboardTop > 0 && keyboardTop < bounds.maxY - safe.bottom - 1
        var area = bounds
        var screenInsets = safe
        if keyboardVisible {
            area.size.height = keyboardTop
            screenInsets.bottom = 0
        }
        let orientation = model.videoOrientation
        let insets = orientation.rotatedInsets(
            top: Double(screenInsets.top),
            left: Double(screenInsets.left),
            bottom: Double(screenInsets.bottom),
            right: Double(screenInsets.right)
        )
        controlsOverlay.transform = .identity
        controlsOverlay.bounds = CGRect(
            origin: .zero,
            size: orientation.swapsDimensions
                ? CGSize(width: area.height, height: area.width)
                : area.size
        )
        controlsOverlay.center = CGPoint(x: area.midX, y: area.midY)
        controlsOverlay.transform = CGAffineTransform(rotationAngle: CGFloat(orientation.rotationAngleRadians))
        overlaySafeConstraints[0].constant = CGFloat(insets.top)
        overlaySafeConstraints[1].constant = CGFloat(insets.left)
        overlaySafeConstraints[2].constant = CGFloat(insets.bottom)
        overlaySafeConstraints[3].constant = CGFloat(insets.right)
        specialKeysPanel.bottomSafeInset = CGFloat(insets.bottom)
        controlsOverlay.layoutIfNeeded()
    }

    // MARK: Zoom

    /// Magnifies the video view (GPU-composited transform, no extra latency).
    private func applyZoom(_ zoom: SPPWViewZoom) {
        videoSurfaceView.transform = CGAffineTransform(translationX: CGFloat(zoom.offsetX), y: CGFloat(zoom.offsetY))
            .scaledBy(x: CGFloat(zoom.scale), y: CGFloat(zoom.scale))
        updateLocalPointer()
        zoomButton.isHidden = !zoom.isZoomed
        if zoom.isZoomed {
            var config = zoomButton.configuration ?? .filled()
            config.title = String(format: "%.1f×", zoom.scale)
            zoomButton.configuration = config
        }
    }

    private func resetZoom() {
        touchInputView.zoom.reset()
        UIView.animate(withDuration: 0.25) {
            self.applyZoom(self.touchInputView.zoom)
            self.orientationToolbar.layoutIfNeeded()
        }
    }

    private func makeHUDButton(symbol: String, title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: symbol)
        config.title = title
        config.imagePadding = 4
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
        config.baseForegroundColor = .white
        config.buttonSize = .small
        return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hudHideTask?.cancel()
        hintHideTask?.cancel()
        keyRepeater.stop()
        mouseInput.stop()
        model.stickyModifiers.reset()
        model.sendInputEvent(.releaseAll)
        model.setRemoteCursorHidden(false)
        if isBeingDismissed {
            onDismiss()
        }
    }

    private func render(_ buffer: CVPixelBuffer?) {
        if (buffer != nil) == pointerView.isHidden {
            updateLocalPointer()
        }
        if let buffer {
            videoSurfaceView.isHidden = false
            placeholderLabel.isHidden = true
            videoSurfaceView.display(buffer)
        } else {
            videoSurfaceView.clear()
            videoSurfaceView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.text = model.isConnected
                ? SPPWLocalization.tr("receiver.waiting_video")
                : SPPWLocalization.tr("state.disconnected")
        }
    }

    private func refreshStatsBadge() {
        let s = model.statistics
        let res = s.frameWidth > 0 ? "\(s.frameWidth)×\(s.frameHeight)" : "—"
        let text = "  LIVE · \(res) · \(model.videoOrientation.summaryLabel) · \(String(format: "%.1f", s.decodeMilliseconds)) ms · \(String(format: "%.1f", s.receivedMbps)) Mb/s  "
        statsBadge.text = text
    }

    @objc private func closePressed() {
        dismiss(animated: true)
    }
}

// MARK: - LocalSend-Inspired Gear / Settings View Controller

/// Dedicated Settings View Controller (`gearshape.fill`) grouping all advanced stream
/// parameters, video orientation, Wi-Fi latency & FEC tuning, language selection, and diagnostic logs.
final class IOSSettingsViewController: UIViewController {
    private let receiverModel: IOSReceiverModel
    private let serverModel: IOSServerModel?
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let languageHeaderLabel = UILabel()
    private let streamRequestHeaderLabel = UILabel()
    private let networkHeaderLabel = UILabel()
    private let diagnosticsHeaderLabel = UILabel()

    private let resolutionTitleLabel = UILabel()
    private let resolutionButton = UIButton(type: .system)
    private let resolutionCurrentLabel = UILabel()
    private var lastResolutionMenuSignature = ""
    private let serverResolutionNoticeLabel = UILabel()
    private let fpsTitleLabel = UILabel()
    private let fpsOptions = [30, 60, 90, 120]
    private let fpsControl = UISegmentedControl(items: ["30 fps", "60 fps", "90 fps", "120 fps"])
    private let qualityTitleLabel = UILabel()
    private let qualitySlider = UISlider()
    private let qualityValueLabel = UILabel()
    private let autoBitrateTitleLabel = UILabel()
    private let autoBitrateSwitch = UISwitch()
    private let bitrateRow = UIStackView()
    private let bitrateTitleLabel = UILabel()
    private let bitrateField = UITextField()
    private let fecTitleLabel = UILabel()
    private let fecStepper = UIStepper()
    private let fecValueLabel = UILabel()
    private let latencyTitleLabel = UILabel()
    private let latencyControl = UISegmentedControl(items: SPPWLatencyMode.allCases.map(\.title))
    private let applySettingsButton = UIButton(type: .system)
    private let languageButton = UIButton(type: .system)
    private let clearDiagnosticsButton = UIButton(type: .system)
    private let logsView = UITextView()
    private var lastRenderedEventCount = -1
    private var lastRenderedLastEvent: String?

    init(receiverModel: IOSReceiverModel, serverModel: IOSServerModel? = nil) {
        self.receiverModel = receiverModel
        self.serverModel = serverModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SPPWLocalization.tr("tab.settings")
        view.backgroundColor = .systemGroupedBackground

        if navigationController?.viewControllers.first === self && presentingViewController != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(donePressed)
            )
        }

        buildSettingsInterface()
        receiverModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSettingsUI() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SPPWLocalization.didChangeLanguageNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSettingsUI()
            }
            .store(in: &cancellables)
        refreshSettingsUI()
    }

    @objc private func donePressed() {
        dismiss(animated: true)
    }

    private func buildSettingsInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 16
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
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])

        contentStack.addArrangedSubview(makeGeneralLanguageSection())
        contentStack.addArrangedSubview(makeStreamParametersSection())
        contentStack.addArrangedSubview(makeNetworkAndFECSection())
        contentStack.addArrangedSubview(remoteControlCard)
        contentStack.addArrangedSubview(makeDiagnosticsSection())
        contentStack.addArrangedSubview(makeVersionFooter())
    }

    private func makeGeneralLanguageSection() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        languageHeaderLabel.text = SPPWLocalization.tr("settings.language")
        let header = makeSectionHeader(
            label: languageHeaderLabel,
            symbol: "globe",
            tint: .systemTeal
        )
        stack.addArrangedSubview(header)

        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: "character.bubble")
        config.imagePadding = 8
        languageButton.configuration = config
        languageButton.showsMenuAsPrimaryAction = true
        rebuildLanguageMenu()
        stack.addArrangedSubview(languageButton)

        return card(stack)
    }

    private func rebuildLanguageMenu() {
        let currentLang = SPPWLocalization.selectedLanguage
        languageButton.setTitle(currentLang.displayName, for: .normal)

        let actions = SPPWAppLanguage.allCases.map { lang in
            UIAction(
                title: lang.displayName,
                state: (lang == currentLang) ? .on : .off
            ) { [weak self] _ in
                SPPWLocalization.selectedLanguage = lang
                self?.rebuildLanguageMenu()
                self?.refreshSettingsUI()
                self?.receiverModel.objectWillChange.send()
                self?.serverModel?.objectWillChange.send()
            }
        }
        languageButton.menu = UIMenu(title: SPPWLocalization.tr("settings.language"), children: actions)
    }

    private func makeStreamParametersSection() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12

        streamRequestHeaderLabel.text = SPPWLocalization.tr("settings.stream_request")
        stack.addArrangedSubview(makeSectionHeader(
            label: streamRequestHeaderLabel,
            symbol: "tv.and.mediabox",
            tint: .systemBlue
        ))

        // Native, automatic, or a short-side level derived from the server's aspect ratio.
        let resolutionRow = UIStackView()
        resolutionRow.axis = .horizontal
        resolutionRow.alignment = .center
        resolutionRow.spacing = 8
        resolutionTitleLabel.text = SPPWLocalization.tr("settings.resolution_preset")
        resolutionTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        resolutionButton.showsMenuAsPrimaryAction = true
        resolutionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        resolutionButton.contentHorizontalAlignment = .trailing
        resolutionRow.addArrangedSubview(resolutionTitleLabel)
        resolutionRow.addArrangedSubview(UIView())
        resolutionRow.addArrangedSubview(resolutionButton)
        stack.addArrangedSubview(resolutionRow)

        resolutionCurrentLabel.font = .preferredFont(forTextStyle: .caption1)
        resolutionCurrentLabel.textColor = .secondaryLabel
        resolutionCurrentLabel.isHidden = true
        stack.addArrangedSubview(resolutionCurrentLabel)

        serverResolutionNoticeLabel.font = .preferredFont(forTextStyle: .caption1)
        serverResolutionNoticeLabel.textColor = .secondaryLabel
        serverResolutionNoticeLabel.numberOfLines = 0
        serverResolutionNoticeLabel.isHidden = true
        stack.addArrangedSubview(serverResolutionNoticeLabel)

        fpsTitleLabel.text = SPPWLocalization.tr("settings.frame_rate")
        fpsTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        stack.addArrangedSubview(fpsTitleLabel)
        fpsControl.selectedSegmentIndex = fpsOptions.firstIndex(of: receiverModel.fps) ?? 1
        fpsControl.addTarget(self, action: #selector(fpsChanged), for: .valueChanged)
        stack.addArrangedSubview(fpsControl)

        let qualityRow = UIStackView()
        qualityRow.axis = .horizontal
        qualityRow.alignment = .center
        qualityRow.spacing = 8
        qualityTitleLabel.text = SPPWLocalization.tr("settings.quality")
        qualityTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        qualitySlider.minimumValue = 0.35
        qualitySlider.maximumValue = 1.0
        qualitySlider.value = Float(receiverModel.quality)
        qualitySlider.addTarget(self, action: #selector(qualityChanged), for: .valueChanged)
        qualityValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        qualityValueLabel.textAlignment = .right
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        qualityValueLabel.text = String(format: "%.2f", receiverModel.quality)
        qualityRow.addArrangedSubview(qualityTitleLabel)
        qualityRow.addArrangedSubview(qualitySlider)
        qualityRow.addArrangedSubview(qualityValueLabel)
        stack.addArrangedSubview(qualityRow)

        let autoBitrateRow = UIStackView()
        autoBitrateRow.axis = .horizontal
        autoBitrateRow.alignment = .center
        autoBitrateRow.spacing = 8
        autoBitrateTitleLabel.text = SPPWLocalization.tr("settings.automatic_bitrate")
        autoBitrateTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        autoBitrateSwitch.isOn = receiverModel.automaticBitrate
        autoBitrateSwitch.addTarget(self, action: #selector(autoBitrateToggled), for: .valueChanged)
        autoBitrateRow.addArrangedSubview(autoBitrateTitleLabel)
        autoBitrateRow.addArrangedSubview(UIView())
        autoBitrateRow.addArrangedSubview(autoBitrateSwitch)
        stack.addArrangedSubview(autoBitrateRow)

        bitrateRow.axis = .horizontal
        bitrateRow.alignment = .center
        bitrateRow.spacing = 8
        bitrateTitleLabel.text = SPPWLocalization.tr("settings.bitrate_mbps")
        bitrateTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        bitrateField.borderStyle = .roundedRect
        bitrateField.keyboardType = .decimalPad
        bitrateField.addKeyboardDismissBar()
        bitrateField.textAlignment = .right
        bitrateField.text = String(format: "%.0f", receiverModel.bitrateMbps)
        bitrateField.widthAnchor.constraint(equalToConstant: 95).isActive = true
        bitrateField.addTarget(self, action: #selector(bitrateChanged), for: .editingChanged)
        bitrateRow.addArrangedSubview(bitrateTitleLabel)
        bitrateRow.addArrangedSubview(UIView())
        bitrateRow.addArrangedSubview(bitrateField)
        bitrateRow.isHidden = receiverModel.automaticBitrate
        stack.addArrangedSubview(bitrateRow)

        var applyConfig = UIButton.Configuration.filled()
        applyConfig.title = SPPWLocalization.tr("action.apply_resync")
        applyConfig.image = UIImage(systemName: "arrow.clockwise")
        applyConfig.imagePadding = 6
        applyConfig.cornerStyle = .medium
        applySettingsButton.configuration = applyConfig
        applySettingsButton.addTarget(self, action: #selector(applySettingsPressed), for: .touchUpInside)
        stack.addArrangedSubview(applySettingsButton)

        return card(stack)
    }

    private func makeNetworkAndFECSection() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12

        networkHeaderLabel.text = SPPWLocalization.tr("settings.wifi_and_fec")
        stack.addArrangedSubview(makeSectionHeader(
            label: networkHeaderLabel,
            symbol: "antenna.radiowaves.left.and.right",
            tint: .systemPurple
        ))

        latencyTitleLabel.text = SPPWLocalization.tr("settings.wifi_jitter_mode")
        latencyTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        stack.addArrangedSubview(latencyTitleLabel)

        if let idx = SPPWLatencyMode.allCases.firstIndex(of: receiverModel.latencyMode) {
            latencyControl.selectedSegmentIndex = idx
        }
        latencyControl.addTarget(self, action: #selector(latencyModeChanged), for: .valueChanged)
        stack.addArrangedSubview(latencyControl)

        let fecRow = UIStackView()
        fecRow.axis = .horizontal
        fecRow.alignment = .center
        fecRow.spacing = 8
        fecTitleLabel.text = SPPWLocalization.tr("settings.fec_parity")
        fecTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        fecStepper.minimumValue = 0
        fecStepper.maximumValue = 50
        fecStepper.stepValue = 2
        fecStepper.value = Double(receiverModel.fecPercent)
        fecStepper.addTarget(self, action: #selector(fecChanged), for: .valueChanged)
        fecValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        fecValueLabel.text = "\(receiverModel.fecPercent)%"
        fecRow.addArrangedSubview(fecTitleLabel)
        fecRow.addArrangedSubview(UIView())
        fecRow.addArrangedSubview(fecValueLabel)
        fecRow.addArrangedSubview(fecStepper)
        stack.addArrangedSubview(fecRow)

        return card(stack)
    }

    private func makeVersionFooter() -> UIView {
        let label = UILabel()
        label.text = "PyrowaveCast " + SPPWBuildVersion.current
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    private func makeDiagnosticsSection() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        diagnosticsHeaderLabel.text = SPPWLocalization.tr("settings.diagnostics")
        header.addArrangedSubview(makeSectionHeader(
            label: diagnosticsHeaderLabel,
            symbol: "terminal.fill",
            tint: .systemOrange
        ))
        header.addArrangedSubview(UIView())
        clearDiagnosticsButton.setImage(UIImage(systemName: "trash"), for: .normal)
        clearDiagnosticsButton.setTitle(" " + SPPWLocalization.tr("action.clear"), for: .normal)
        clearDiagnosticsButton.addAction(UIAction { [weak self] _ in
            self?.receiverModel.clearEvents()
            self?.serverModel?.clearLogs()
        }, for: .touchUpInside)
        header.addArrangedSubview(clearDiagnosticsButton)
        stack.addArrangedSubview(header)

        logsView.isEditable = false
        logsView.isScrollEnabled = true
        logsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logsView.backgroundColor = .tertiarySystemGroupedBackground
        logsView.layer.cornerRadius = 10
        logsView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(logsView)

        return card(stack)
    }

    private func makeSectionHeader(label: UILabel, symbol: String, tint: UIColor) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = tint
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])
        label.font = .preferredFont(forTextStyle: .headline)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
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

    private lazy var remoteControlCard = IOSRemoteControlSettingsCard(model: receiverModel)

    private func refreshSettingsUI() {
        title = SPPWLocalization.tr("tab.settings")
        remoteControlCard.refreshTexts()
        remoteControlCard.syncFromModel()
        languageHeaderLabel.text = SPPWLocalization.tr("settings.language")
        streamRequestHeaderLabel.text = SPPWLocalization.tr("settings.stream_request")
        networkHeaderLabel.text = SPPWLocalization.tr("settings.wifi_and_fec")
        diagnosticsHeaderLabel.text = SPPWLocalization.tr("settings.diagnostics")
        resolutionTitleLabel.text = SPPWLocalization.tr("settings.resolution_preset")
        lastResolutionMenuSignature = "" // rebuild the menu with the new language
        fpsTitleLabel.text = SPPWLocalization.tr("settings.frame_rate")
        qualityTitleLabel.text = SPPWLocalization.tr("settings.quality")
        autoBitrateTitleLabel.text = SPPWLocalization.tr("settings.automatic_bitrate")
        bitrateTitleLabel.text = SPPWLocalization.tr("settings.bitrate_mbps")
        latencyTitleLabel.text = SPPWLocalization.tr("settings.wifi_jitter_mode")
        fecTitleLabel.text = SPPWLocalization.tr("settings.fec_parity")
        clearDiagnosticsButton.setTitle(" " + SPPWLocalization.tr("action.clear"), for: .normal)
        for (idx, mode) in SPPWLatencyMode.allCases.enumerated() where idx < latencyControl.numberOfSegments {
            latencyControl.setTitle(mode.title, forSegmentAt: idx)
        }
        var applyConfig = applySettingsButton.configuration ?? .filled()
        applyConfig.title = SPPWLocalization.tr("action.apply_resync")
        applySettingsButton.configuration = applyConfig

        let connected = receiverModel.isConnected
        updateResolutionControls(connected: connected)

        if connected {
            serverResolutionNoticeLabel.text = SPPWLocalization.tr("settings.agreed_timeout_fmt", receiverModel.agreedTimeoutSeconds)
            serverResolutionNoticeLabel.isHidden = false
        } else {
            serverResolutionNoticeLabel.isHidden = true
        }

        if let fpsIndex = fpsOptions.firstIndex(of: receiverModel.fps), fpsControl.selectedSegmentIndex != fpsIndex {
            fpsControl.selectedSegmentIndex = fpsIndex
        }
        if !qualitySlider.isTracking {
            qualitySlider.value = Float(receiverModel.quality)
        }
        qualityValueLabel.text = String(format: "%.2f", receiverModel.quality)
        autoBitrateSwitch.isOn = receiverModel.automaticBitrate
        bitrateRow.isHidden = receiverModel.automaticBitrate
        if !bitrateField.isFirstResponder {
            bitrateField.text = String(format: "%.0f", receiverModel.bitrateMbps)
        }
        fecStepper.value = Double(receiverModel.fecPercent)
        fecValueLabel.text = "\(receiverModel.fecPercent)%"
        if let latIdx = SPPWLatencyMode.allCases.firstIndex(of: receiverModel.latencyMode),
           latencyControl.selectedSegmentIndex != latIdx {
            latencyControl.selectedSegmentIndex = latIdx
        }

        let eventCount = receiverModel.events.count
        let lastEvent = receiverModel.events.last
        if eventCount != lastRenderedEventCount || lastEvent != lastRenderedLastEvent {
            lastRenderedEventCount = eventCount
            lastRenderedLastEvent = lastEvent
            logsView.text = receiverModel.events.reversed().joined(separator: "\n")
        }
    }

    private func updateResolutionControls(connected: Bool) {
        var options = SPPWResolutionMode.menuOptions(nativeShortSide: receiverModel.nativeShortSide)
        if !options.contains(receiverModel.resolutionMode) {
            options.append(receiverModel.resolutionMode)
        }
        resolutionButton.setTitle(receiverModel.resolutionMode.title, for: .normal)
        let signature = options.map(\.id).joined(separator: "|") + "#" + receiverModel.resolutionMode.id
        if signature != lastResolutionMenuSignature {
            lastResolutionMenuSignature = signature
            resolutionButton.menu = UIMenu(children: options.map { option in
                UIAction(
                    title: option.title,
                    state: option == receiverModel.resolutionMode ? .on : .off
                ) { [weak self] _ in
                    self?.receiverModel.resolutionMode = option
                }
            })
        }
        let frameWidth = receiverModel.statistics.frameWidth
        let frameHeight = receiverModel.statistics.frameHeight
        if connected && frameWidth > 0 && frameHeight > 0 {
            resolutionCurrentLabel.text = SPPWLocalization.tr("settings.resolution_current_fmt", "\(frameWidth)×\(frameHeight)")
            resolutionCurrentLabel.isHidden = false
        } else {
            resolutionCurrentLabel.isHidden = true
        }
    }

    @objc private func fpsChanged() {
        let idx = fpsControl.selectedSegmentIndex
        guard idx >= 0, idx < fpsOptions.count else { return }
        receiverModel.fps = fpsOptions[idx]
    }

    @objc private func qualityChanged() {
        let stepped = (Double(qualitySlider.value) * 100).rounded() / 100
        receiverModel.quality = stepped
        qualityValueLabel.text = String(format: "%.2f", stepped)
    }

    @objc private func autoBitrateToggled() {
        receiverModel.automaticBitrate = autoBitrateSwitch.isOn
        bitrateRow.isHidden = receiverModel.automaticBitrate
    }

    @objc private func bitrateChanged() {
        if let val = Double(bitrateField.text ?? ""), val >= 5, val <= 1000 {
            receiverModel.bitrateMbps = val
        }
    }

    @objc private func latencyModeChanged() {
        let idx = latencyControl.selectedSegmentIndex
        let all = SPPWLatencyMode.allCases
        guard idx >= 0, idx < all.count else { return }
        receiverModel.latencyMode = all[idx]
    }

    @objc private func fecChanged() {
        receiverModel.fecPercent = Int(fecStepper.value)
        fecValueLabel.text = "\(receiverModel.fecPercent)%"
    }

    @objc private func applySettingsPressed() {
        view.endEditing(true)
        receiverModel.applySettings()
    }
}

extension UITextField {
    /// Adds a bar above the keyboard with a button that closes it: number and decimal pads
    /// have no return key, so on the main screens the keyboard could not be put away.
    func addKeyboardDismissBar() {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let close = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            primaryAction: UIAction { [weak self] _ in self?.resignFirstResponder() }
        )
        close.accessibilityLabel = SPPWLocalization.tr("keyboard.dismiss")
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), close]
        bar.sizeToFit()
        inputAccessoryView = bar
    }
}
