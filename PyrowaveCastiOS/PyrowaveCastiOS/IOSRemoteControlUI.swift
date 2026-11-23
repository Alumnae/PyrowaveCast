import Combine
import GameController
import QuartzCore
import UIKit
import UniformTypeIdentifiers
#if canImport(SPPWCommon)
import SPPWCommon
#endif

// MARK: - Remote control UI (fullscreen receiver)

/// Colours shared by the dock and the special keys sheet; they match the fullscreen HUD capsules.
enum IOSRemoteStyle {
    static let dockBackground = UIColor(white: 0.11, alpha: 0.94)
    static let buttonBackground = UIColor(white: 0.24, alpha: 0.92)
    static let groupBackground = UIColor(white: 0.11, alpha: 1)
    static let tileBackground = UIColor(white: 0.18, alpha: 1)
    static let sheetBackground = UIColor(white: 0.04, alpha: 0.94)
    static let caption = UIColor(white: 0.56, alpha: 1)
    static let accent = UIColor.systemBlue
}

// MARK: Special key presentation

extension SPPWSpecialKey {
    /// SF Symbol for the tile, or `nil` for text keys.
    var symbolName: String? {
        switch self {
        case .tab: return "arrow.right.to.line"
        case .delete: return "delete.backward"
        case .forwardDelete: return "delete.forward"
        case .returnKey: return "return"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .cut: return "scissors"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .selectAll: return "selection.pin.in.out"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .spotlight: return "magnifyingglass"
        case .appSwitcher: return "square.on.square"
        case .minimize: return "minus"
        case .closeWindow: return "xmark"
        case .quit: return "power"
        case .missionControl: return "rectangle.3.group"
        case .showDesktop: return "menubar.dock.rectangle"
        default: return nil
        }
    }

    /// Short text for keys drawn as text, and the caption under editing keys.
    var shortLabel: String {
        switch self {
        case .escape: return "esc"
        case .tab: return "tab"
        case .returnKey: return "return"
        case .delete: return "delete"
        case .forwardDelete: return "⌦"
        case .pageUp: return "PgUp"
        case .pageDown: return "PgDn"
        case .home: return "Home"
        case .end: return "End"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        default: return ""
        }
    }

    /// Localized name shown on long press (shortcuts).
    var displayName: String {
        switch self {
        case .cut: return SPPWLocalization.tr("key.cut")
        case .copy: return SPPWLocalization.tr("key.copy")
        case .paste: return SPPWLocalization.tr("key.paste")
        case .selectAll: return SPPWLocalization.tr("key.select_all")
        case .undo: return SPPWLocalization.tr("key.undo")
        case .redo: return SPPWLocalization.tr("key.redo")
        case .spotlight: return SPPWLocalization.tr("key.spotlight")
        case .appSwitcher: return SPPWLocalization.tr("key.app_switcher")
        case .minimize: return SPPWLocalization.tr("key.minimize")
        case .closeWindow: return SPPWLocalization.tr("key.close_window")
        case .quit: return SPPWLocalization.tr("key.quit")
        case .missionControl: return SPPWLocalization.tr("key.mission_control")
        case .showDesktop: return SPPWLocalization.tr("key.show_desktop")
        case .forwardDelete: return SPPWLocalization.tr("key.forward_delete")
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        default: return shortLabel
        }
    }

    /// Held tiles repeat (navigation and deletion), like a real keyboard.
    var repeatsWhenHeld: Bool {
        switch self {
        case .up, .down, .left, .right, .delete, .forwardDelete, .pageUp, .pageDown: return true
        default: return false
        }
    }
}

// MARK: - Dock

/// Floating input dock: touch mode, keyboard, special keys, clipboard, sticky ⇧⌃⌥⌘,
/// right-click toggle and collapse. Horizontally scrollable on narrow screens.
@MainActor
final class IOSRemoteInputDock: UIView {
    enum Action {
        case toggleMode
        case toggleKeyboard
        case toggleSpecialKeys
        case toggleRightClick
        case collapse
        case modifierTap(SPPWKeyModifiers)
        case modifierLock(SPPWKeyModifiers)
    }

    var onAction: ((Action) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let modeButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let specialKeysButton = UIButton(type: .system)
    private let rightClickButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private var modifierButtons: [(SPPWKeyModifiers, UIButton, UIView)] = []
    private var lastModifierTap: [UInt32: CFTimeInterval] = [:]
    private static let doubleTapInterval: CFTimeInterval = 0.35
    static let height: CGFloat = 44

    init(pasteControl: UIView) {
        super.init(frame: .zero)
        backgroundColor = IOSRemoteStyle.dockBackground
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        scrollView.addSubview(stack)

        configure(modeButton, symbol: "cursorarrow.motionlines", label: "remote.dock.mode") { [weak self] in
            self?.onAction?(.toggleMode)
        }
        configure(keyboardButton, symbol: "keyboard", label: "remote.dock.keyboard") { [weak self] in
            self?.onAction?(.toggleKeyboard)
        }
        configure(specialKeysButton, symbol: "command", label: "remote.dock.special_keys") { [weak self] in
            self?.onAction?(.toggleSpecialKeys)
        }
        configure(rightClickButton, symbol: "computermouse", label: "remote.dock.right_click", title: "R", width: 48) { [weak self] in
            self?.onAction?(.toggleRightClick)
        }
        configure(collapseButton, symbol: "chevron.down", label: "remote.dock.hide") { [weak self] in
            self?.onAction?(.collapse)
        }

        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pasteControl.widthAnchor.constraint(equalToConstant: 36),
            pasteControl.heightAnchor.constraint(equalToConstant: 32)
        ])

        stack.addArrangedSubview(modeButton)
        stack.addArrangedSubview(keyboardButton)
        stack.addArrangedSubview(specialKeysButton)
        stack.addArrangedSubview(pasteControl)
        stack.addArrangedSubview(Self.separator())
        let modifiers: [(SPPWKeyModifiers, String, String)] = [
            (.shift, "⇧", "Shift"), (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.command, "⌘", "Command")
        ]
        for (modifier, glyph, name) in modifiers {
            let button = UIButton(type: .system)
            let dot = UIView()
            makeModifierButton(button, dot: dot, glyph: glyph, name: name, modifier: modifier)
            modifierButtons.append((modifier, button, dot))
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(Self.separator())
        stack.addArrangedSubview(rightClickButton)
        stack.addArrangedSubview(collapseButton)

        let fitWidth = scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 12)
        fitWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fitWidth,
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.contentLayoutGuide.heightAnchor),
            scrollView.contentLayoutGuide.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        mode: IOSRemoteInputMode,
        keyboardActive: Bool,
        specialKeysVisible: Bool,
        modifiers: SPPWStickyModifiers,
        rightClickArmed: Bool
    ) {
        setSymbol(modeButton, mode == .trackpad ? "cursorarrow.motionlines" : "hand.point.up.left")
        style(modeButton, filled: true)
        style(keyboardButton, filled: keyboardActive)
        style(specialKeysButton, filled: specialKeysVisible)
        style(rightClickButton, filled: rightClickArmed)
        style(collapseButton, filled: false)
        for (modifier, button, dot) in modifierButtons {
            switch modifiers.state(of: modifier) {
            case .off:
                style(button, filled: false)
                dot.isHidden = true
            case .oneShot:
                style(button, outlined: true)
                dot.isHidden = true
            case .locked:
                style(button, filled: true)
                dot.isHidden = false
            }
        }
        modeButton.accessibilityValue = mode == .trackpad
            ? SPPWLocalization.tr("remote.mode.trackpad")
            : SPPWLocalization.tr("remote.mode.direct")
    }

    // MARK: Building

    private func configure(
        _ button: UIButton,
        symbol: String,
        label: String,
        title: String? = nil,
        width: CGFloat = 38,
        action: @escaping () -> Void
    ) {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        if let title {
            config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 12, weight: .semibold)]))
            config.imagePadding = 2
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        button.configuration = config
        button.accessibilityLabel = SPPWLocalization.tr(label)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
        style(button, filled: false)
    }

    private func makeModifierButton(_ button: UIButton, dot: UIView, glyph: String, name: String, modifier: SPPWKeyModifiers) {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.attributedTitle = AttributedString(glyph, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .medium)]))
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        button.configuration = config
        button.accessibilityLabel = name
        button.translatesAutoresizingMaskIntoConstraints = false
        button.clipsToBounds = false
        button.addAction(UIAction { [weak self] _ in self?.modifierTapped(modifier) }, for: .touchUpInside)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 4
        dot.layer.borderColor = IOSRemoteStyle.accent.cgColor
        dot.layer.borderWidth = 1.5
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1)
        ])
        style(button, filled: false)
    }

    /// Tap toggles a one-shot modifier; a second tap within 0.35 s locks it.
    private func modifierTapped(_ modifier: SPPWKeyModifiers) {
        let now = CACurrentMediaTime()
        if let last = lastModifierTap[modifier.rawValue], now - last < Self.doubleTapInterval {
            lastModifierTap[modifier.rawValue] = nil
            onAction?(.modifierLock(modifier))
        } else {
            lastModifierTap[modifier.rawValue] = now
            onAction?(.modifierTap(modifier))
        }
    }

    private func setSymbol(_ button: UIButton, _ symbol: String) {
        button.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    }

    private func style(_ button: UIButton, filled: Bool) {
        button.configuration?.baseBackgroundColor = filled ? IOSRemoteStyle.accent : IOSRemoteStyle.buttonBackground
        button.configuration?.baseForegroundColor = .white
        button.configuration?.background.strokeWidth = 0
    }

    private func style(_ button: UIButton, outlined: Bool) {
        button.configuration?.baseBackgroundColor = .clear
        button.configuration?.baseForegroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        button.configuration?.background.strokeColor = IOSRemoteStyle.accent
        button.configuration?.background.strokeWidth = outlined ? 1.5 : 0
    }

    private static func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(white: 0.3, alpha: 1)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 20)
        ])
        return line
    }
}

// MARK: - Special keys sheet

/// Grouped special keys: function key strip, Mac shortcuts, editing and navigation cluster.
/// Long press on a shortcut shows its name; held navigation/deletion keys repeat.
@MainActor
final class IOSSpecialKeysPanel: UIView {
    var onKey: ((SPPWSpecialKey) -> Void)?
    var onShowName: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let groupsStack = UIStackView()
    private var groupTitleLabels: [(UILabel, String)] = []
    private var repeatTimer: Timer?
    private var heightToContent: NSLayoutConstraint?
    private var scrollBottom: NSLayoutConstraint!
    /// Bottom safe-area inset supplied by the owner: the panel lives in a container that
    /// rotates with the video, where UIKit's own safe area is not reliable.
    var bottomSafeInset: CGFloat = 0 {
        didSet { scrollBottom?.constant = -bottomSafeInset }
    }

    private static let shortcutKeys: [SPPWSpecialKey] = [
        .cut, .copy, .paste, .selectAll,
        .undo, .redo, .spotlight, .appSwitcher,
        .minimize, .closeWindow, .quit, .missionControl,
        .showDesktop
    ]
    private static let editingKeys: [SPPWSpecialKey] = [
        .tab, .delete, .returnKey,
        .pageUp, .up, .pageDown,
        .left, .down, .right,
        .home, .forwardDelete, .end
    ]
    private static let functionKeys: [SPPWSpecialKey] = [
        .escape, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = IOSRemoteStyle.sheetBackground
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 8
        scrollView.addSubview(content)

        content.addArrangedSubview(makeGroup(titleKey: "remote.keys.function", body: makeFunctionStrip()))
        groupsStack.axis = .horizontal
        groupsStack.spacing = 8
        groupsStack.alignment = .top
        groupsStack.distribution = .fill
        let shortcuts = makeGroup(titleKey: "remote.keys.shortcuts", body: makeGrid(Self.shortcutKeys, columns: 4))
        let editing = makeGroup(titleKey: "remote.keys.editing", body: makeGrid(Self.editingKeys, columns: 3))
        groupsStack.addArrangedSubview(shortcuts)
        groupsStack.addArrangedSubview(editing)
        shortcuts.widthAnchor.constraint(equalTo: editing.widthAnchor, multiplier: 1.25).isActive = true
        content.addArrangedSubview(groupsStack)

        scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomSafeInset)
        let toContent = scrollView.heightAnchor.constraint(equalTo: content.heightAnchor, constant: 20)
        toContent.priority = .defaultHigh
        heightToContent = toContent
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Keys stay above the home indicator; the sheet background extends under it.
            scrollBottom,
            toContent,
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        // Side by side when there is room (landscape, iPad), stacked on a narrow iPhone.
        let axis: NSLayoutConstraint.Axis = bounds.width >= 560 ? .horizontal : .vertical
        if groupsStack.axis != axis {
            groupsStack.axis = axis
            groupsStack.alignment = axis == .horizontal ? .top : .fill
        }
        super.layoutSubviews()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeat() }
    }

    func refreshTexts() {
        for (label, key) in groupTitleLabels { label.text = SPPWLocalization.tr(key) }
    }

    // MARK: Building

    private func makeGroup(titleKey: String, body: UIView) -> UIView {
        let group = UIView()
        group.backgroundColor = IOSRemoteStyle.groupBackground
        group.layer.cornerRadius = 14
        group.layer.cornerCurve = .continuous
        let title = UILabel()
        title.text = SPPWLocalization.tr(titleKey)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = IOSRemoteStyle.caption
        groupTitleLabels.append((title, titleKey))
        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: group.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -10)
        ])
        return group
    }

    private func makeFunctionStrip() -> UIView {
        let strip = UIScrollView()
        strip.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)
        for key in Self.functionKeys {
            var config = UIButton.Configuration.filled()
            config.cornerStyle = .capsule
            config.baseBackgroundColor = IOSRemoteStyle.tileBackground
            config.baseForegroundColor = .white
            config.attributedTitle = AttributedString(key.shortLabel, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .medium)]))
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.press(key) })
            button.accessibilityLabel = key.displayName
            row.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor),
            strip.heightAnchor.constraint(equalToConstant: 34)
        ])
        return strip
    }

    private func makeGrid(_ keys: [SPPWSpecialKey], columns: Int) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 6
        var index = 0
        while index < keys.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
            for column in 0..<columns {
                let keyIndex = index + column
                if keyIndex < keys.count {
                    row.addArrangedSubview(makeTile(keys[keyIndex]))
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            grid.addArrangedSubview(row)
            index += columns
        }
        return grid
    }

    private func makeTile(_ key: SPPWSpecialKey) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = IOSRemoteStyle.tileBackground
        config.baseForegroundColor = .white
        config.background.cornerRadius = 10
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        if let symbol = key.symbolName {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        }
        let caption = key.shortcutCaption ?? (key.symbolName != nil ? key.shortLabel : "")
        let mainText = key.symbolName == nil ? key.shortLabel : caption
        if !mainText.isEmpty {
            let isCaption = key.symbolName != nil
            config.attributedTitle = AttributedString(mainText, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: isCaption ? 11 : 13, weight: isCaption ? .regular : .medium),
                .foregroundColor: isCaption ? IOSRemoteStyle.caption : UIColor.white
            ]))
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = key.displayName
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(tileHeld(_:)))
        hold.minimumPressDuration = key.repeatsWhenHeld ? 0.4 : 0.45
        button.addGestureRecognizer(hold)
        button.tag = SPPWSpecialKey.allCases.firstIndex(of: key) ?? 0
        return button
    }

    private func press(_ key: SPPWSpecialKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        onKey?(key)
    }

    @objc private func tileHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard let view = recognizer.view, SPPWSpecialKey.allCases.indices.contains(view.tag) else { return }
        let key = SPPWSpecialKey.allCases[view.tag]
        switch recognizer.state {
        case .began:
            if key.repeatsWhenHeld {
                press(key)
                stopRepeat()
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKey?(key) }
                }
            } else {
                UISelectionFeedbackGenerator().selectionChanged()
                onShowName?(key.displayName + (key.shortcutCaption.map { "  " + $0 } ?? ""))
            }
        case .ended, .cancelled, .failed:
            stopRepeat()
        default:
            break
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

// MARK: - System keyboard field (IME aware)

/// Invisible text field that brings up the system keyboard and turns what is typed into
/// remote keystrokes.
///
/// IME composition (Pinyin, Kana, accents) stays inside the field while `markedTextRange` is
/// set; only committed text is reported (`onText`), then the field is cleared again. Backspace
/// on the empty field is reported as a delete key. Hardware keys that are not text (arrows,
/// Esc, F-keys) or carry ⌘/⌃/⌥ are reported as key codes, unless a composition is active.
@MainActor
final class IOSRemoteKeyboardField: UITextField, UITextFieldDelegate {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onComposition: ((String?) -> Void)?
    var onHardwareKey: ((UIKey, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        returnKeyType = .default
        textColor = .clear
        tintColor = .clear
        backgroundColor = .clear
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func deleteBackward() {
        if (text ?? "").isEmpty && markedTextRange == nil {
            onDeleteBackward?()
        } else {
            super.deleteBackward()
            textChanged()
        }
    }

    @objc private func textChanged() {
        if let marked = markedTextRange {
            onComposition?(text(in: marked))
            return
        }
        onComposition?(nil)
        let committed = text ?? ""
        guard !committed.isEmpty else { return }
        text = ""
        onText?(committed)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onText?("\n")
        return false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = forwardHardwareKeys(presses, isDown: true)
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = forwardHardwareKeys(presses, isDown: false)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = forwardHardwareKeys(presses, isDown: false)
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    /// Sends non-text keys and shortcuts as key codes; returns the presses left for the text system.
    private func forwardHardwareKeys(_ presses: Set<UIPress>, isDown: Bool) -> Set<UIPress> {
        guard markedTextRange == nil else { return presses }
        var remaining = Set<UIPress>()
        for press in presses {
            if let key = press.key, IOSHardwareKeys.bypassesTextInput(key) {
                onHardwareKey?(key, isDown)
            } else {
                remaining.insert(press)
            }
        }
        return remaining
    }
}

// MARK: - Hardware keyboard

@MainActor
enum IOSHardwareKeys {
    static func modifiers(_ flags: UIKeyModifierFlags) -> SPPWKeyModifiers {
        var result = SPPWKeyModifiers()
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }

    static func macKeyCode(_ key: UIKey) -> UInt16? {
        let usage = key.keyCode.rawValue
        guard usage >= 0, usage <= Int(UInt16.max) else { return nil }
        return SPPWMacKeyCode.fromHIDUsage(UInt16(usage))
    }

    /// Keys the text system must not see while typing into the remote keyboard field:
    /// navigation, Esc, Tab, F-keys and anything with ⌘/⌃/⌥ (shortcuts).
    static func bypassesTextInput(_ key: UIKey) -> Bool {
        guard let code = macKeyCode(key) else { return false }
        if !modifiers(key.modifierFlags).isDisjoint(with: SPPWKeyModifiers.shortcutModifiers) {
            return SPPWMacKeyCode.modifier(forKeyCode: code) == nil
        }
        let navigation: Set<UInt16> = [
            SPPWMacKeyCode.escape, SPPWMacKeyCode.tab, SPPWMacKeyCode.upArrow, SPPWMacKeyCode.downArrow,
            SPPWMacKeyCode.leftArrow, SPPWMacKeyCode.rightArrow, SPPWMacKeyCode.home, SPPWMacKeyCode.end,
            SPPWMacKeyCode.pageUp, SPPWMacKeyCode.pageDown, SPPWMacKeyCode.forwardDelete, SPPWMacKeyCode.help
        ]
        return navigation.contains(code) || SPPWMacKeyCode.functionKeys.contains(code)
    }
}

/// Client-side auto-repeat for held hardware keys (synthetic events never repeat on the Mac):
/// after 0.4 s the key-down is resent 30 times a second; the server marks them as auto-repeat.
@MainActor
final class IOSKeyRepeater {
    private var timer: Timer?
    private var startTimer: Timer?
    private var heldKeyCode: UInt16?
    var send: ((SPPWInputEvent) -> Void)?

    func keyDown(keyCode: UInt16, modifiers: SPPWKeyModifiers) {
        stop()
        guard SPPWMacKeyCode.modifier(forKeyCode: keyCode) == nil else { return }
        heldKeyCode = keyCode
        let event = SPPWInputEvent.key(keyCode: keyCode, isDown: true, modifiers: modifiers.rawValue)
        startTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.heldKeyCode == keyCode else { return }
                self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.send?(event) }
                }
            }
        }
    }

    func keyUp(keyCode: UInt16) {
        if heldKeyCode == keyCode { stop() }
    }

    func stop() {
        startTimer?.invalidate()
        startTimer = nil
        timer?.invalidate()
        timer = nil
        heldKeyCode = nil
    }
}

// MARK: - Touch surface (trackpad / direct touch)

/// Full-screen layer above the video that turns touches into pointer input.
///
/// Trackpad: one-finger drag moves (accelerated), tap clicks (right click when armed),
/// two-finger tap right-clicks, two-finger drag scrolls (with momentum), press-and-hold then
/// drag holds the button, three-finger tap shows/hides the controls.
/// Direct touch: the finger is the pointer (normalized `.touch` events through the video's
/// aspect-fit and orientation). Indirect pointers (iPad mouse/trackpad) are left to `GCMouse`.
@MainActor
final class IOSTouchInputView: UIView, UIGestureRecognizerDelegate {
    weak var model: IOSReceiverModel?
    /// Returns `true` (and disarms) when the next tap should be a right click.
    var consumeRightClickArm: (() -> Bool)?
    var onToggleControls: (() -> Void)?
    /// Local magnifier (1×–2×) of the video; touches are mapped through it.
    var zoom = SPPWViewZoom()
    var onZoomChanged: ((SPPWViewZoom) -> Void)?

    var mode: IOSRemoteInputMode = .trackpad {
        didSet { updateRecognizers() }
    }

    private let movePan = UIPanGestureRecognizer()
    private let scrollPan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let threeFingerTap = UITapGestureRecognizer()
    private let holdDrag = UILongPressGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    /// Cumulative scale of the current pinch and whether it became a zoom (≥ 6 %).
    private var pinchScaleTotal: CGFloat = 1
    private var pinchEngaged = false
    private var lastPinchLocation: CGPoint = .zero

    private var lastMoveTranslation: CGPoint = .zero
    private var lastMoveTime: CFTimeInterval = 0
    private var lastScrollTranslation: CGPoint = .zero
    private var lastHoldLocation: CGPoint = .zero
    private var lastHoldTime: CFTimeInterval = 0
    private var isHoldDragging = false
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var directTouch: UITouch?

    /// Mac pixels per iOS point of two-finger travel.
    private static let scrollScale: CGFloat = 1.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        let directOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        movePan.addTarget(self, action: #selector(handleMove(_:)))
        movePan.minimumNumberOfTouches = 1
        movePan.maximumNumberOfTouches = 1
        scrollPan.addTarget(self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        tap.addTarget(self, action: #selector(handleTap))
        twoFingerTap.addTarget(self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        threeFingerTap.addTarget(self, action: #selector(handleThreeFingerTap))
        threeFingerTap.numberOfTouchesRequired = 3
        holdDrag.addTarget(self, action: #selector(handleHoldDrag(_:)))
        holdDrag.minimumPressDuration = 0.45
        holdDrag.allowableMovement = 10
        pinch.addTarget(self, action: #selector(handlePinch(_:)))

        movePan.require(toFail: holdDrag)
        tap.require(toFail: twoFingerTap)
        twoFingerTap.require(toFail: threeFingerTap)

        for recognizer in [movePan, scrollPan, tap, twoFingerTap, threeFingerTap, holdDrag, pinch] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = directOnly
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        updateRecognizers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two fingers scroll the Mac until they clearly pinch, then the same gesture zooms.
        let pair: Set<ObjectIdentifier> = [ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)]
        return pair == [ObjectIdentifier(pinch), ObjectIdentifier(scrollPan)]
    }

    private func updateRecognizers() {
        let trackpad = mode == .trackpad
        for recognizer in [movePan, scrollPan, tap, twoFingerTap, holdDrag] as [UIGestureRecognizer] {
            recognizer.isEnabled = trackpad
        }
        threeFingerTap.isEnabled = true
        pinch.isEnabled = true
        stopMomentum()
        if isHoldDragging {
            isHoldDragging = false
            model?.sendInputEvent(.buttonAtCursor(button: 0, isDown: false))
        }
    }

    // MARK: Trackpad

    @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let now = CACurrentMediaTime()
        switch recognizer.state {
        case .began:
            stopMomentum()
            lastMoveTranslation = translation
            lastMoveTime = now
        case .changed:
            sendPointerDelta(dx: translation.x - lastMoveTranslation.x, dy: translation.y - lastMoveTranslation.y, elapsed: now - lastMoveTime)
            lastMoveTranslation = translation
            lastMoveTime = now
        default:
            break
        }
    }

    private func sendPointerDelta(dx: CGFloat, dy: CGFloat, elapsed: CFTimeInterval) {
        guard dx != 0 || dy != 0, let model else { return }
        // Swipes follow the picture as shown: rotated/mirrored video, and slower while zoomed.
        let video = model.videoOrientation.videoDelta(screenDX: Double(dx), screenDY: Double(dy))
        let scaled = SPPWPointerAcceleration.scaled(
            deltaX: video.dx / zoom.scale,
            deltaY: video.dy / zoom.scale,
            elapsedSeconds: max(elapsed, 0.004),
            speed: model.pointerSpeed
        )
        model.moveLocalPointer(videoDX: scaled.dx, videoDY: scaled.dy)
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began:
            stopMomentum()
            lastScrollTranslation = translation
        case .changed:
            if !pinchEngaged {
                sendScroll(dx: translation.x - lastScrollTranslation.x, dy: translation.y - lastScrollTranslation.y)
            }
            lastScrollTranslation = translation
        case .ended:
            if !pinchEngaged {
                startMomentum(velocity: recognizer.velocity(in: self))
            }
        default:
            break
        }
    }

    /// Natural scrolling: content follows the fingers (fingers down → wheel up).
    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        guard let model, dx != 0 || dy != 0 else { return }
        let sign: CGFloat = model.naturalScrolling ? 1 : -1
        let video = model.videoOrientation.videoDelta(screenDX: Double(dx), screenDY: Double(dy))
        model.sendInputEvent(.scroll(
            deltaX: Float(CGFloat(video.dx) * Self.scrollScale * sign),
            deltaY: Float(CGFloat(video.dy) * Self.scrollScale * sign)
        ))
    }

    private func startMomentum(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 200 else { return }
        momentumVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumStep(_ link: CADisplayLink) {
        let dt = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
        momentumVelocity.x *= 0.94
        momentumVelocity.y *= 0.94
        guard hypot(momentumVelocity.x, momentumVelocity.y) > 30 else {
            stopMomentum()
            return
        }
        sendScroll(dx: momentumVelocity.x * dt, dy: momentumVelocity.y * dt)
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    // MARK: Zoom

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            pinchScaleTotal = 1
            pinchEngaged = false
            lastPinchLocation = location
            recognizer.scale = 1
        case .changed:
            let factor = recognizer.scale
            recognizer.scale = 1
            pinchScaleTotal *= factor
            if !pinchEngaged {
                guard abs(pinchScaleTotal - 1) >= 0.06 else {
                    lastPinchLocation = location
                    return
                }
                pinchEngaged = true
                stopMomentum()
                // The first finger was pressing on the Mac: lift it before zooming.
                if mode == .directTouch, let touch = directTouch {
                    directTouch = nil
                    sendDirect(touch, phase: .cancelled)
                    sendDirect(touch, phase: .cancelled)
                }
                // Apply the scale accumulated before engaging in one step.
                applyZoom(by: pinchScaleTotal, at: location, panBy: .zero)
            } else {
                applyZoom(
                    by: factor,
                    at: location,
                    panBy: CGPoint(x: location.x - lastPinchLocation.x, y: location.y - lastPinchLocation.y)
                )
            }
            lastPinchLocation = location
        default:
            pinchEngaged = false
            pinchScaleTotal = 1
        }
    }

    private func applyZoom(by factor: CGFloat, at anchor: CGPoint, panBy delta: CGPoint) {
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        guard width > 0, height > 0 else { return }
        zoom.pan(dx: Double(delta.x), dy: Double(delta.y), viewWidth: width, viewHeight: height)
        zoom.zoom(by: Double(factor), anchorX: Double(anchor.x), anchorY: Double(anchor.y), viewWidth: width, viewHeight: height)
        onZoomChanged?(zoom)
    }

    @objc private func handleTap() {
        let right = consumeRightClickArm?() ?? false
        model?.syncLocalPointerToRemote()
        model?.sendInputEvent(.clickAtCursor(button: right ? 1 : 0))
    }

    @objc private func handleTwoFingerTap() {
        model?.syncLocalPointerToRemote()
        model?.sendInputEvent(.clickAtCursor(button: 1))
    }

    @objc private func handleThreeFingerTap() {
        onToggleControls?()
    }

    @objc private func handleHoldDrag(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        let now = CACurrentMediaTime()
        switch recognizer.state {
        case .began:
            stopMomentum()
            isHoldDragging = true
            lastHoldLocation = location
            lastHoldTime = now
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let right = consumeRightClickArm?() ?? false
            model?.syncLocalPointerToRemote()
            model?.sendInputEvent(.buttonAtCursor(button: right ? 1 : 0, isDown: true))
            holdButton = right ? 1 : 0
        case .changed:
            sendPointerDelta(dx: location.x - lastHoldLocation.x, dy: location.y - lastHoldLocation.y, elapsed: now - lastHoldTime)
            lastHoldLocation = location
            lastHoldTime = now
        case .ended, .cancelled, .failed:
            guard isHoldDragging else { return }
            isHoldDragging = false
            model?.sendInputEvent(.buttonAtCursor(button: holdButton, isDown: false))
        default:
            break
        }
    }

    private var holdButton: UInt8 = 0

    // MARK: Direct touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        guard mode == .directTouch, directTouch == nil,
              let touch = touches.first(where: { $0.type == .direct }) else { return }
        directTouch = touch
        sendDirect(touch, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard mode == .directTouch, let touch = directTouch, touches.contains(touch) else { return }
        sendDirect(touch, phase: .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finishDirect(touches, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        finishDirect(touches, phase: .cancelled)
    }

    private func finishDirect(_ touches: Set<UITouch>, phase: SPPWTouchPhase) {
        guard let touch = directTouch, touches.contains(touch) else { return }
        directTouch = nil
        guard mode == .directTouch else { return }
        // Sent twice: a lost release would leave the Mac's button held (the server dedupes).
        sendDirect(touch, phase: phase)
        sendDirect(touch, phase: phase)
    }

    private func sendDirect(_ touch: UITouch, phase: SPPWTouchPhase) {
        guard let model else { return }
        let location = touch.location(in: self)
        // Undo the local magnifier first: the finger points at the zoomed picture.
        let point = zoom.contentPoint(
            viewX: Double(location.x),
            viewY: Double(location.y),
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height)
        )
        let stats = model.statistics
        guard stats.frameWidth > 0, stats.frameHeight > 0,
              let mapped = SPPWInputCoordinateMapper.mapUIKitPoint(
                viewX: point.x,
                viewY: point.y,
                viewWidth: Double(bounds.width),
                viewHeight: Double(bounds.height),
                videoWidth: Double(stats.frameWidth),
                videoHeight: Double(stats.frameHeight),
                orientation: model.videoOrientation,
                clampOutside: true
              ) else { return }
        model.sendTouch(phase: phase.rawValue, normalizedX: mapped.normalizedX, normalizedY: mapped.normalizedY)
        model.placeLocalPointer(normalizedX: Double(mapped.normalizedX), normalizedY: Double(mapped.normalizedY))
    }
}

// MARK: - Receiver-drawn pointer

/// Arrow drawn by the receiver at `IOSReceiverModel.localPointer` (tip at the view's origin).
/// Never takes touches.
final class IOSLocalPointerView: UIView {
    static let size = CGSize(width: 18, height: 26)

    override class var layerClass: AnyClass { CAShapeLayer.self }

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: frame.origin, size: Self.size))
        isUserInteractionEnabled = false
        let shape = layer as! CAShapeLayer
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: 1, y: 21))
        path.addLine(to: CGPoint(x: 6, y: 16.5))
        path.addLine(to: CGPoint(x: 9.5, y: 24.5))
        path.addLine(to: CGPoint(x: 12.5, y: 23.2))
        path.addLine(to: CGPoint(x: 9.2, y: 15.4))
        path.addLine(to: CGPoint(x: 15.5, y: 15.4))
        path.close()
        shape.path = path.cgPath
        shape.fillColor = UIColor.white.cgColor
        shape.strokeColor = UIColor.black.cgColor
        shape.lineWidth = 1.2
        shape.lineJoin = .round
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.35
        shape.shadowRadius = 1.5
        shape.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Places the tip at `point` (in the superview's coordinates).
    func place(tipAt point: CGPoint) {
        frame = CGRect(origin: CGPoint(x: point.x - 1, y: point.y - 1), size: Self.size)
    }
}

// MARK: - iPad mouse / trackpad (GameController)

/// Relative mouse input from `GCMouse` (iPad mice and trackpads). While a mouse is connected the
/// fullscreen view asks for pointer lock, so the iPad pointer hides and every motion goes to the Mac.
@MainActor
final class IOSHardwareMouseInput {
    weak var model: IOSReceiverModel?
    var onConnectionChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastMoveTime: CFTimeInterval = 0

    var isConnected: Bool { !GCMouse.mice().isEmpty }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                GCMouse.mice().forEach(self.attach)
                self.onConnectionChange?(true)
            }
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onConnectionChange?(self.isConnected)
            }
        })
        GCMouse.mice().forEach(attach)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { self?.moved(dx: dx, dy: dy) }
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.button(0, pressed) }
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.button(1, pressed) }
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.button(2, pressed) }
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.scrolled(x: x, y: y) }
        }
    }

    private func moved(dx: Float, dy: Float) {
        guard let model else { return }
        let now = CACurrentMediaTime()
        let elapsed = lastMoveTime > 0 ? min(now - lastMoveTime, 0.05) : 0.008
        lastMoveTime = now
        // GCMouse reports +Y up; the Mac's display space grows downwards. Motion follows
        // the picture as shown when the video is rotated or mirrored.
        let video = model.videoOrientation.videoDelta(screenDX: Double(dx) * 0.6, screenDY: Double(-dy) * 0.6)
        let scaled = SPPWPointerAcceleration.scaled(
            deltaX: video.dx,
            deltaY: video.dy,
            elapsedSeconds: max(elapsed, 0.004),
            speed: model.pointerSpeed
        )
        model.moveLocalPointer(videoDX: scaled.dx, videoDY: scaled.dy)
    }

    private func button(_ index: UInt8, _ pressed: Bool) {
        if pressed { model?.syncLocalPointerToRemote() }
        model?.sendInputEvent(.buttonAtCursor(button: index, isDown: pressed))
    }

    private func scrolled(x: Float, y: Float) {
        guard x != 0 || y != 0, let model else { return }
        let video = model.videoOrientation.videoDelta(screenDX: Double(x * 10), screenDY: Double(y * 10))
        model.sendInputEvent(.scroll(deltaX: Float(video.dx), deltaY: Float(video.dy)))
    }
}

// MARK: - Settings card

/// "Remote control" card of the receiver settings: touch mode, pointer speed,
/// natural scrolling and clipboard sync.
@MainActor
final class IOSRemoteControlSettingsCard: UIView {
    private let model: IOSReceiverModel
    private let headerLabel = UILabel()
    private let modeTitle = UILabel()
    private let modeControl = UISegmentedControl(items: ["", ""])
    private let speedTitle = UILabel()
    private let speedSlider = UISlider()
    private let naturalTitle = UILabel()
    private let naturalSwitch = UISwitch()
    private let clipboardTitle = UILabel()
    private let clipboardSwitch = UISwitch()
    private let footer = UILabel()

    init(model: IOSReceiverModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16

        let icon = UIImageView(image: UIImage(systemName: "desktopcomputer"))
        icon.tintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .preferredFont(forTextStyle: .headline)
        let header = UIStackView(arrangedSubviews: [icon, headerLabel])
        header.spacing = 8
        header.alignment = .center

        for label in [modeTitle, speedTitle, naturalTitle, clipboardTitle] {
            label.font = .preferredFont(forTextStyle: .subheadline)
        }
        modeControl.selectedSegmentIndex = model.remoteInputMode == .trackpad ? 0 : 1
        modeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.model.remoteInputMode = self.modeControl.selectedSegmentIndex == 0 ? .trackpad : .directTouch
        }, for: .valueChanged)

        speedSlider.minimumValue = 1
        speedSlider.maximumValue = 10
        speedSlider.value = Float(model.pointerSpeed)
        speedSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.model.pointerSpeed = Double(self.speedSlider.value.rounded())
        }, for: .valueChanged)

        naturalSwitch.isOn = model.naturalScrolling
        naturalSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.model.naturalScrolling = self.naturalSwitch.isOn
        }, for: .valueChanged)

        clipboardSwitch.isOn = model.clipboardSyncEnabled
        clipboardSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.model.clipboardSyncEnabled = self.clipboardSwitch.isOn
        }, for: .valueChanged)

        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.numberOfLines = 0

        let speedRow = Self.row(speedTitle, speedSlider)
        speedSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let stack = UIStackView(arrangedSubviews: [
            header,
            modeTitle,
            modeControl,
            speedRow,
            Self.row(naturalTitle, naturalSwitch),
            Self.row(clipboardTitle, clipboardSwitch),
            footer
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(6, after: modeTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        refreshTexts()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshTexts() {
        headerLabel.text = SPPWLocalization.tr("remote.title")
        modeTitle.text = SPPWLocalization.tr("remote.touch_mode")
        modeControl.setTitle(SPPWLocalization.tr("remote.mode.trackpad"), forSegmentAt: 0)
        modeControl.setTitle(SPPWLocalization.tr("remote.mode.direct"), forSegmentAt: 1)
        speedTitle.text = SPPWLocalization.tr("remote.pointer_speed")
        naturalTitle.text = SPPWLocalization.tr("remote.natural_scroll")
        clipboardTitle.text = SPPWLocalization.tr("remote.clipboard_sync")
        footer.text = SPPWLocalization.tr("remote.clipboard_footer")
    }

    func syncFromModel() {
        modeControl.selectedSegmentIndex = model.remoteInputMode == .trackpad ? 0 : 1
        speedSlider.value = Float(model.pointerSpeed)
        naturalSwitch.isOn = model.naturalScrolling
        clipboardSwitch.isOn = model.clipboardSyncEnabled
    }

    private static func row(_ label: UILabel, _ control: UIView) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [label, UIView(), control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }
}

// MARK: - Small views

/// Container that only takes touches landing on its subviews (the fullscreen HUD), so the
/// trackpad surface underneath receives everything else.
final class IOSPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Capsule label with horizontal padding (hints, IME composition).
final class IOSPaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}
