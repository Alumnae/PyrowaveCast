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
    /// Reports the first occurrence of each display failure so the receiver
    /// event log can show why a surface is blank instead of failing silently.
    let onDiagnostic: ((String) -> Void)?

    init(
        pixelBuffer: CVPixelBuffer?,
        framePublisher: AnyPublisher<CVPixelBuffer?, Never>? = nil,
        orientation: SPPWVideoOrientation = SPPWVideoOrientation(),
        onDiagnostic: ((String) -> Void)? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.framePublisher = framePublisher
        self.orientation = orientation
        self.onDiagnostic = onDiagnostic
    }

    init<P: Publisher>(
        framePublisher: P,
        initialPixelBuffer: CVPixelBuffer? = nil,
        orientation: SPPWVideoOrientation = SPPWVideoOrientation(),
        onDiagnostic: ((String) -> Void)? = nil
    ) where P.Output == CVPixelBuffer?, P.Failure == Never {
        self.pixelBuffer = initialPixelBuffer
        self.framePublisher = framePublisher.eraseToAnyPublisher()
        self.orientation = orientation
        self.onDiagnostic = onDiagnostic
    }

    func makeNSView(context: Context) -> SampleBufferVideoView {
        let view = SampleBufferVideoView()
        view.onDiagnostic = onDiagnostic
        view.videoOrientation = orientation
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
        if nsView.videoOrientation != orientation {
            nsView.videoOrientation = orientation
        }
        if let framePublisher {
            nsView.subscribeIfNeeded(to: framePublisher)
        } else if let pixelBuffer {
            nsView.display(pixelBuffer)
        }
    }
}

/// NSView hosting an `AVSampleBufferDisplayLayer` as a sublayer (macOS).
final class SampleBufferVideoView: NSView {
    var onDiagnostic: ((String) -> Void)?
    var videoOrientation = SPPWVideoOrientation() {
        didSet {
            syncLayerGeometry()
        }
    }

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var frameSubscription: AnyCancellable?
    private var hasActivePublisherSubscription = false
    private var lastDiagnostic = ""
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatDimensions: (width: Int, height: Int, pixelFormat: OSType)?
    private var lastDisplayedPixelBuffer: CVPixelBuffer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit creates the root backing layer when wantsLayer is set. We
        // must NOT replace it with AVSampleBufferDisplayLayer — add a
        // sublayer instead (the documented macOS pattern).
        wantsLayer = true
        if layer == nil { layer = CALayer() }
        setupDisplayLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayerGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerGeometry()
    }

    override func layout() {
        super.layout()
        syncLayerGeometry()
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
