import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif

/// UIView hosting a rebuildable `AVSampleBufferDisplayLayer` sublayer for iOS.
///
/// Mirrors the macOS `SampleBufferVideoView`:
/// - Uses a sublayer rather than `layerClass` so the display layer can be torn
///   down and rebuilt cleanly if AVFoundation enters `.failed` (for example
///   after app backgrounding / error -11847), where `flush()` alone never
///   recovers.
/// - Sets `kCMSampleAttachmentKey_DisplayImmediately` both on the sample buffer
///   AND inside `CMSampleBufferGetSampleAttachmentsArray`, which is required
///   for immediate presentation when `CMSampleTimingInfo.invalid` is used.
final class IOSVideoSurfaceView: UIView {
    var onDiagnostic: ((String) -> Void)?
    var videoOrientation = SPPWVideoOrientation() {
        didSet {
            syncLayerGeometry()
        }
    }

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var lastDiagnostic = ""
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatDimensions: (width: Int, height: Int, pixelFormat: OSType)?
    private var lastDisplayedPixelBuffer: CVPixelBuffer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        setupDisplayLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupDisplayLayer() {
        let videoLayer = AVSampleBufferDisplayLayer()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.isOpaque = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        videoLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        videoLayer.frame = bounds
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.insertSublayer(videoLayer, at: 0)
        displayLayer = videoLayer
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLayerGeometry()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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
        // UIKit coordinate system has +Y downwards, so clockwise rotation is positive angle.
        var transform = CGAffineTransform(rotationAngle: CGFloat(videoOrientation.rotationAngleRadians))
        transform = transform.scaledBy(
            x: CGFloat(videoOrientation.scaleX),
            y: CGFloat(videoOrientation.scaleY)
        )
        displayLayer.setAffineTransform(transform)
        displayLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.commit()
    }

    func clear() {
        lastDisplayedPixelBuffer = nil
        displayLayer?.flushAndRemoveImage()
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
        }

        if displayLayer == nil {
            setupDisplayLayer()
        }
        guard var activeLayer = displayLayer else { return }

        if activeLayer.status == .failed {
            report("AVSampleBufferDisplayLayer failed (\(String(describing: activeLayer.error))); rebuilding")
            rebuildDisplayLayer()
            guard let rebuilt = displayLayer else { return }
            activeLayer = rebuilt
        }
        if !activeLayer.isReadyForMoreMediaData {
            activeLayer.flush()
        }
        activeLayer.enqueue(sampleBuffer)
        if activeLayer.status == .failed {
            lastDisplayedPixelBuffer = nil
            report("AVSampleBufferDisplayLayer enqueue failed (\(String(describing: activeLayer.error)))")
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
        syncLayerGeometry()
    }

    private func report(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        let handler = onDiagnostic
        DispatchQueue.main.async { handler?(message) }
    }
}
