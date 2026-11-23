import CoreImage
import CoreVideo
import Foundation
import Metal

/// Normalizes captured frames into clean NV12 IOSurface buffers for the Metal encoder
/// (in-app capture, ScreenCaptureKit and the broadcast upload extension).
final class IOSNV12Converter: @unchecked Sendable {
    private let context: CIContext? = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) }
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    func normalizeToNV12(_ source: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(source)
        let srcHeight = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        // Ensure the buffer is a genuine 2-plane IOSurface with exact even Y and UV
        // dimensions before passing it directly; ReplayKit buffers with odd dimensions
        // or padded plane heights must be normalized into a clean NV12 IOSurface.
        if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
           srcWidth >= 2, srcHeight >= 2,
           srcWidth.isMultiple(of: 2),
           srcHeight.isMultiple(of: 2),
           let surfaceRef = CVPixelBufferGetIOSurface(source) {
            let surface = surfaceRef.takeUnretainedValue()
            if IOSurfaceGetPlaneCount(surface) == 2,
               IOSurfaceGetWidthOfPlane(surface, 0) == srcWidth,
               IOSurfaceGetHeightOfPlane(surface, 0) == srcHeight,
               IOSurfaceGetWidthOfPlane(surface, 1) == srcWidth / 2,
               IOSurfaceGetHeightOfPlane(surface, 1) == srcHeight / 2 {
                return source
            }
        }

        let width = (srcWidth > 0 ? srcWidth : targetWidth) & ~1
        let height = (srcHeight > 0 ? srcHeight : targetHeight) & ~1
        guard width >= 2, height >= 2, let context else { return nil }

        guard let destination = allocateBuffer(width: width, height: height) else { return nil }

        var input = CIImage(cvPixelBuffer: source)
        let extent = input.extent
        if Int(extent.width) != width || Int(extent.height) != height,
           extent.width > 0, extent.height > 0 {
            input = input.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / extent.width,
                y: CGFloat(height) / extent.height
            ))
        }
        context.render(
            input,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return destination
    }

    private func allocateBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if pool == nil || poolWidth != width || poolHeight != height {
            pool = nil
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 4
            ]
            let bufferAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var newPool: CVPixelBufferPool?
            if CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttrs as CFDictionary,
                bufferAttrs as CFDictionary,
                &newPool
            ) == kCVReturnSuccess {
                pool = newPool
                poolWidth = width
                poolHeight = height
            }
        }

        if let pool {
            var pixelBuffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
               let pixelBuffer {
                return pixelBuffer
            }
        }

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &destination
        ) == kCVReturnSuccess else { return nil }
        return destination
    }
}
