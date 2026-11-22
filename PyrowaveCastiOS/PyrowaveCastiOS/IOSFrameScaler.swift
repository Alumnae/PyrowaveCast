import CoreVideo
import VideoToolbox

/// Scales captured frames to the client-chosen stream size on the GPU (VideoToolbox pixel
/// transfer), keeping the source pixel format (NV12) and IOSurface backing so the PyroWave
/// encoder still reads them zero-copy. Used by the iOS server when the client asks for a
/// level below native (`SPPWResolutionLadder`).
final class IOSFrameScaler: @unchecked Sendable {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?

    /// Returns `source` scaled to `size`, or `nil` if the transfer failed.
    func scale(_ source: CVPixelBuffer, to size: (width: Int, height: Int)) -> CVPixelBuffer? {
        if session == nil {
            var created: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
                  let created else { return nil }
            VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            session = created
        }
        let format = CVPixelBufferGetPixelFormatType(source)
        if poolKey?.width != size.width || poolKey?.height != size.height || poolKey?.format != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var newPool: CVPixelBufferPool?
            let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary
            guard CVPixelBufferPoolCreate(nil, poolAttributes, attributes as CFDictionary, &newPool) == kCVReturnSuccess,
                  let newPool else { return nil }
            pool = newPool
            poolKey = (size.width, size.height, format)
        }
        guard let session, let pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination,
              VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else {
            return nil
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    deinit {
        if let session {
            VTPixelTransferSessionInvalidate(session)
        }
    }
}
