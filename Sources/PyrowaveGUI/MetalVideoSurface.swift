import AVFoundation
import AppKit
import Combine
import CoreMedia
import CoreVideo
import QuartzCore
import SPPWCommon
import SwiftUI

/// A high-performance, low-latency video surface that renders decoded
/// `CVPixelBuffer` frames via `AVSampleBufferDisplayLayer`.
///
/// This is the same hardware-accelerated display path used by VideoToolbox:
/// the pixel buffer is wrapped in a `CMSampleBuffer` and enqueued to the
/// display layer, which handles YCbCr→RGB conversion automatically via the
/// CV attachments on the buffer. No Core Image involvement — no CIContext,
/// no CGImage, no bitmap allocation, no CPU copy.
///
/// To avoid 60–120 Hz SwiftUI `ObservableObject.objectWillChange` view-hierarchy
/// rebuilds on the main thread, live receivers feed frames through
/// `framePublisher` (`PassthroughSubject<CVPixelBuffer?, Never>`), which
/// `SampleBufferVideoView` subscribes to directly without invalidating any
/// SwiftUI views.
struct MetalVideoSurface: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer?
    let framePublisher: AnyPublisher<CVPixelBuffer?, Never>?
    let orientation: SPPWVideoOrientation
    let remoteControlEnabled: Bool
    let onInputEvent: ((SPPWInputEvent) -> Void)?
    let onCaptureFocusChanged: ((Bool) -> Void)?
    /// Reports the first occurrence of each display failure so the receiver
    /// event log can show why a surface is blank instead of failing silently.
    let onDiagnostic: ((String) -> Void)?

    init(
        pixelBuffer: CVPixelBuffer?,
        framePublisher: AnyPublisher<CVPixelBuffer?, Never>? = nil,
        orientation: SPPWVideoOrientation = SPPWVideoOrientation(),
        remoteControlEnabled: Bool = false,
        onInputEvent: ((SPPWInputEvent) -> Void)? = nil,
        onCaptureFocusChanged: ((Bool) -> Void)? = nil,
        onDiagnostic: ((String) -> Void)? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.framePublisher = framePublisher
        self.orientation = orientation
        self.remoteControlEnabled = remoteControlEnabled
        self.onInputEvent = onInputEvent
        self.onCaptureFocusChanged = onCaptureFocusChanged
        self.onDiagnostic = onDiagnostic
    }

    init<P: Publisher>(
        framePublisher: P,
        initialPixelBuffer: CVPixelBuffer? = nil,
        orientation: SPPWVideoOrientation = SPPWVideoOrientation(),
        remoteControlEnabled: Bool = false,
        onInputEvent: ((SPPWInputEvent) -> Void)? = nil,
        onCaptureFocusChanged: ((Bool) -> Void)? = nil,
        onDiagnostic: ((String) -> Void)? = nil
    ) where P.Output == CVPixelBuffer?, P.Failure == Never {
        self.pixelBuffer = initialPixelBuffer
        self.framePublisher = framePublisher.eraseToAnyPublisher()
        self.orientation = orientation
        self.remoteControlEnabled = remoteControlEnabled
        self.onInputEvent = onInputEvent
        self.onCaptureFocusChanged = onCaptureFocusChanged
        self.onDiagnostic = onDiagnostic
    }

    func makeNSView(context: Context) -> SampleBufferVideoView {
        let view = SampleBufferVideoView()
        view.onDiagnostic = onDiagnostic
        view.onInputEvent = onInputEvent
        view.onCaptureFocusChanged = onCaptureFocusChanged
        view.videoOrientation = orientation
        view.remoteControlEnabled = remoteControlEnabled
        if let framePublisher {
            view.subscribe(to: framePublisher)
        }
        if let pixelBuffer {
            view.display(pixelBuffer)
        }
        return view
    }

    func updateNSView(_ nsView: SampleBufferVideoView, context: Context) {
        nsView.onDiagnostic = onDiagnostic
        nsView.onInputEvent = onInputEvent
        nsView.onCaptureFocusChanged = onCaptureFocusChanged
        if nsView.videoOrientation != orientation {
            nsView.videoOrientation = orientation
        }
        if nsView.remoteControlEnabled != remoteControlEnabled {
            nsView.remoteControlEnabled = remoteControlEnabled
        }
        if let framePublisher {
            nsView.subscribeIfNeeded(to: framePublisher)
        } else if let pixelBuffer {
            nsView.display(pixelBuffer)
        }
    }
}

/// NSView hosting an `AVSampleBufferDisplayLayer` as a sublayer (macOS),
/// with optional mouse/keyboard remote-control event capture.
final class SampleBufferVideoView: NSView {
    var onDiagnostic: ((String) -> Void)?
    var onInputEvent: ((SPPWInputEvent) -> Void)?
    var onCaptureFocusChanged: ((Bool) -> Void)?
    var videoOrientation = SPPWVideoOrientation() {
        didSet {
            syncLayerGeometry()
        }
    }
    var remoteControlEnabled = false {
        didSet {
            guard remoteControlEnabled != oldValue else { return }
            updateTrackingAreas()
            if !remoteControlEnabled {
                releaseRemoteInputs(resignFocus: true)
            }
        }
    }

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var frameSubscription: AnyCancellable?
    private var hasActivePublisherSubscription = false
    private var lastDiagnostic = ""
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatDimensions: (width: Int, height: Int, pixelFormat: OSType)?
    private var lastDisplayedPixelBuffer: CVPixelBuffer?
    private var lastVideoSize: CGSize = .zero

    // Remote input capture state
    private var pointerTrackingArea: NSTrackingArea?
    private var lastPointerMoveNanos: UInt64 = 0
    private var activeButtons: Set<UInt8> = []
    private var commandPressedKeys: Set<UInt16> = []
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    private var hasKeyboardFocus = false
    nonisolated(unsafe) private var windowResignObserver: NSObjectProtocol?
    nonisolated(unsafe) private var appResignObserver: NSObjectProtocol?

    private static let hoverMoveIntervalNanos: UInt64 = 8_000_000 // ~125 Hz
    private static let dragMoveIntervalNanos: UInt64 = 4_000_000  // ~250 Hz

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit creates the root backing layer when wantsLayer is set. We
        // must NOT replace it with AVSampleBufferDisplayLayer — add a
        // sublayer instead (the documented macOS pattern).
        wantsLayer = true
        if layer == nil { layer = CALayer() }
        setupDisplayLayer()
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseRemoteInputs(resignFocus: true)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = windowResignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appResignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func subscribe(to publisher: AnyPublisher<CVPixelBuffer?, Never>) {
        hasActivePublisherSubscription = true
        frameSubscription = publisher
            .sink { [weak self] pixelBuffer in
                guard let self else { return }
                if let pixelBuffer {
                    self.display(pixelBuffer)
                } else {
                    self.clear()
                }
            }
    }

    func subscribeIfNeeded(to publisher: AnyPublisher<CVPixelBuffer?, Never>) {
        guard !hasActivePublisherSubscription else { return }
        subscribe(to: publisher)
    }

    func clear() {
        lastDisplayedPixelBuffer = nil
        lastVideoSize = .zero
        displayLayer?.flushAndRemoveImage()
    }

    private func setupDisplayLayer() {
        let videoLayer = AVSampleBufferDisplayLayer()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.isOpaque = true
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoLayer.contentsScale = effectiveScale
        videoLayer.frame = bounds
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer?.addSublayer(videoLayer)
        displayLayer = videoLayer
    }

    private var effectiveScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // AppKit does not guarantee layout() runs when SwiftUI sets the frame,
    // so keep the layer geometry in sync from every relevant hook.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let observer = windowResignObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignObserver = nil
        }
        if newWindow == nil {
            releaseRemoteInputs(resignFocus: true)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayerGeometry()
        updateTrackingAreas()
        if let window {
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releaseRemoteInputs(resignFocus: true)
                }
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerGeometry()
    }

    override func layout() {
        super.layout()
        syncLayerGeometry()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = pointerTrackingArea {
            removeTrackingArea(existing)
            pointerTrackingArea = nil
        }
        guard remoteControlEnabled else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    // MARK: - Remote control responder & event capture

    override var acceptsFirstResponder: Bool {
        remoteControlEnabled
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        remoteControlEnabled
    }

    override func becomeFirstResponder() -> Bool {
        guard remoteControlEnabled else { return false }
        lastModifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        setKeyboardFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseRemoteInputs(resignFocus: false)
        setKeyboardFocus(false)
        return true
    }

    private var isKeyboardCaptured: Bool {
        remoteControlEnabled && window?.firstResponder === self
    }

    private func setKeyboardFocus(_ focused: Bool) {
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
        let callback = onCaptureFocusChanged
        DispatchQueue.main.async {
            callback?(focused)
        }
    }

    private func releaseRemoteInputs(resignFocus: Bool) {
        let shouldNotifyServer = !activeButtons.isEmpty || !commandPressedKeys.isEmpty || hasKeyboardFocus
        activeButtons.removeAll()
        commandPressedKeys.removeAll()
        lastModifierFlags = []
        if shouldNotifyServer {
            onInputEvent?(.releaseAll)
        }
        if resignFocus, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        setKeyboardFocus(false)
    }

    private func mappedPoint(for event: NSEvent, clampOutside: Bool) -> SPPWInputCoordinateMapper.Result? {
        guard lastVideoSize.width > 0, lastVideoSize.height > 0 else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        return SPPWInputCoordinateMapper.mapAppKitPoint(
            viewX: Double(localPoint.x),
            viewY: Double(localPoint.y),
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height),
            videoWidth: Double(lastVideoSize.width),
            videoHeight: Double(lastVideoSize.height),
            orientation: videoOrientation,
            clampOutside: clampOutside
        )
    }

    private static func sanitizedModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        UInt32(truncatingIfNeeded: flags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    private static func isUngrabHotkey(_ event: NSEvent) -> Bool {
        // Ctrl + Option + Esc releases keyboard/mouse capture locally without forwarding Esc.
        guard event.keyCode == 53 else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods.contains(.control) && mods.contains(.option)
    }

    override func mouseMoved(with event: NSEvent) {
        guard remoteControlEnabled else {
            super.mouseMoved(with: event)
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastPointerMoveNanos >= Self.hoverMoveIntervalNanos else { return }
        guard let mapped = mappedPoint(for: event, clampOutside: false) else { return }
        lastPointerMoveNanos = now
        onInputEvent?(.pointerMove(normalizedX: mapped.normalizedX, normalizedY: mapped.normalizedY))
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseButton(button: 0, isDown: true, event: event) { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseButton(button: 0, isDown: false, event: event) { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseButton(button: 1, isDown: true, event: event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseButton(button: 1, isDown: false, event: event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        let button = UInt8(clamping: max(2, event.buttonNumber))
        handleMouseButton(button: button, isDown: true, event: event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        let button = UInt8(clamping: max(2, event.buttonNumber))
        handleMouseButton(button: button, isDown: false, event: event) { super.otherMouseUp(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDrag(event: event) { super.mouseDragged(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMouseDrag(event: event) { super.rightMouseDragged(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleMouseDrag(event: event) { super.otherMouseDragged(with: event) }
    }

    private func handleMouseButton(button: UInt8, isDown: Bool, event: NSEvent, fallback: () -> Void) {
        guard remoteControlEnabled else {
            fallback()
            return
        }
        guard let mapped = mappedPoint(for: event, clampOutside: !isDown) else {
            if !isDown {
                activeButtons.remove(button)
            }
            return
        }
        if isDown {
            if let window, window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
            activeButtons.insert(button)
        } else {
            activeButtons.remove(button)
        }
        lastPointerMoveNanos = DispatchTime.now().uptimeNanoseconds
        onInputEvent?(.mouseButton(
            button: button,
            isDown: isDown,
            normalizedX: mapped.normalizedX,
            normalizedY: mapped.normalizedY
        ))
    }

    private func handleMouseDrag(event: NSEvent, fallback: () -> Void) {
        guard remoteControlEnabled else {
            fallback()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastPointerMoveNanos >= Self.dragMoveIntervalNanos else { return }
        guard let mapped = mappedPoint(for: event, clampOutside: true) else { return }
        lastPointerMoveNanos = now
        onInputEvent?(.pointerMove(normalizedX: mapped.normalizedX, normalizedY: mapped.normalizedY))
    }

    override func scrollWheel(with event: NSEvent) {
        guard remoteControlEnabled else {
            super.scrollWheel(with: event)
            return
        }
        guard mappedPoint(for: event, clampOutside: false) != nil else { return }
        let scale: Double = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let dx = Float(event.scrollingDeltaX * scale)
        let dy = Float(event.scrollingDeltaY * scale)
        guard dx != 0 || dy != 0 else { return }
        onInputEvent?(.scroll(deltaX: dx, deltaY: dy))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyboardCaptured else {
            return super.performKeyEquivalent(with: event)
        }
        if Self.isUngrabHotkey(event) {
            releaseRemoteInputs(resignFocus: true)
            return true
        }
        forwardKeyDown(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isKeyboardCaptured else {
            super.keyDown(with: event)
            return
        }
        if Self.isUngrabHotkey(event) {
            releaseRemoteInputs(resignFocus: true)
            return
        }
        forwardKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        guard isKeyboardCaptured else {
            super.keyUp(with: event)
            return
        }
        commandPressedKeys.remove(event.keyCode)
        onInputEvent?(.key(
            keyCode: event.keyCode,
            isDown: false,
            modifiers: Self.sanitizedModifiers(event.modifierFlags)
        ))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isKeyboardCaptured else {
            super.flagsChanged(with: event)
            return
        }
        let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let sanitized = Self.sanitizedModifiers(current)

        // AppKit does not deliver keyUp for non-modifier keys pressed while Command
        // is held; flush them synthetically when Command is released.
        if lastModifierFlags.contains(.command) && !current.contains(.command) && !commandPressedKeys.isEmpty {
            let pending = commandPressedKeys.sorted()
            commandPressedKeys.removeAll()
            for keyCode in pending {
                onInputEvent?(.key(keyCode: keyCode, isDown: false, modifiers: sanitized))
            }
        }

        let isDown: Bool
        if let flag = SPPWMacInputController.modifierFlag(forKeyCode: event.keyCode) {
            isDown = (UInt64(sanitized) & flag.rawValue) != 0
        } else {
            isDown = current.rawValue > lastModifierFlags.rawValue
        }
        lastModifierFlags = current
        onInputEvent?(.key(keyCode: event.keyCode, isDown: isDown, modifiers: sanitized))
    }

    private func forwardKeyDown(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            commandPressedKeys.insert(event.keyCode)
        }
        onInputEvent?(.key(
            keyCode: event.keyCode,
            isDown: true,
            modifiers: Self.sanitizedModifiers(mods)
        ))
    }

    private func syncLayerGeometry() {
        guard let displayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let layerSize = videoOrientation.swapsDimensions
            ? CGSize(width: b.height, height: b.width)
            : b.size
        displayLayer.bounds = CGRect(origin: .zero, size: layerSize)
        displayLayer.position = CGPoint(x: b.midX, y: b.midY)
        // AppKit layer coordinate system has +Y upwards, so clockwise rotation is negative angle.
        var transform = CGAffineTransform(rotationAngle: CGFloat(-videoOrientation.rotationAngleRadians))
        transform = transform.scaledBy(
            x: CGFloat(videoOrientation.scaleX),
            y: CGFloat(videoOrientation.scaleY)
        )
        displayLayer.setAffineTransform(transform)
        displayLayer.contentsScale = effectiveScale
        CATransaction.commit()
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        if let last = lastDisplayedPixelBuffer,
           last === pixelBuffer,
           displayLayer?.status != .failed {
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if width > 0 && height > 0 {
            let newSize = CGSize(width: width, height: height)
            if lastVideoSize != newSize {
                lastVideoSize = newSize
            }
        }

        let formatDescription: CMVideoFormatDescription
        if let cached = cachedFormatDescription,
           let dims = cachedFormatDimensions,
           dims.width == width, dims.height == height, dims.pixelFormat == pixelFormat {
            formatDescription = cached
        } else {
            var created: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            )
            guard formatStatus == noErr, let created else {
                report("CMVideoFormatDescriptionCreateForImageBuffer failed (\(formatStatus))")
                return
            }
            cachedFormatDescription = created
            cachedFormatDimensions = (width, height, pixelFormat)
            formatDescription = created
        }

        // All-invalid timing plus DisplayImmediately is the proven live-stream
        // pattern: no controlTimebase is needed and a synthetic PTS cannot be
        // judged "late" by the macOS renderer.
        var timing = CMSampleTimingInfo.invalid
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            report("CMSampleBufferCreateReadyWithImageBuffer failed (\(sampleStatus))")
            return
        }

        // Set DisplayImmediately at buffer level (matches the iOS reference)
        // AND in the per-sample attachments array (what the macOS renderer
        // actually consults). Without the latter, macOS can accept the
        // enqueue but never present a frame — a silent black screen.
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        } else {
            report("sample attachments array unavailable; using buffer-level attachment only")
        }

        guard let layer = displayLayer else { return }

        // A failed renderer never recovers with flush() alone — it must be
        // torn down and rebuilt (AVFoundation error -11847).
        if layer.status == .failed {
            report("renderer failed (\(String(describing: layer.error))); rebuilding")
            rebuildDisplayLayer()
        }
        guard let layer = displayLayer else { return }
        if !layer.isReadyForMoreMediaData {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
        if layer.status == .failed {
            lastDisplayedPixelBuffer = nil
            report("enqueue failed (\(String(describing: layer.error)))")
        } else {
            lastDisplayedPixelBuffer = pixelBuffer
        }
    }

    private func rebuildDisplayLayer() {
        lastDisplayedPixelBuffer = nil
        let old = displayLayer
        old?.stopRequestingMediaData()
        old?.removeFromSuperlayer()
        displayLayer = nil
        setupDisplayLayer()
    }

    /// Only the first occurrence of each distinct message is forwarded, so a
    /// persistent failure cannot flood the event log at 60 fps.
    private func report(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        let handler = onDiagnostic
        DispatchQueue.main.async { handler?(message) }
    }
}
