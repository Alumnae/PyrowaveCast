import CoreVideo
import Foundation

struct IOSPreviewBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

actor IOSPreviewDecoder {
    private var session: PyrowaveDecoderSession?
    private var geometry: (width: Int, height: Int)?
    private var decoding = false
    private var lastDecodeNanos: UInt64 = 0
    private let minimumIntervalNanos: UInt64 = 100_000_000

    func decode(_ bitstream: Data, width: Int, height: Int) async throws -> IOSPreviewBuffer? {
        guard !decoding else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastDecodeNanos >= minimumIntervalNanos else { return nil }
        decoding = true
        lastDecodeNanos = now
        defer { decoding = false }

        if session == nil || geometry?.width != width || geometry?.height != height {
            let descriptor = try PyrowaveSessionDescriptor(
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                videoSignal: VideoSignalMetadata(yCbCrRange: .full)
            )
            session = try PyrowaveDecoderSession(descriptor: descriptor, minimumOutputBufferCount: 2)
            geometry = (width, height)
        }
        guard let session else { return nil }
        let output = try await session.decode(EncodedFrame(data: bitstream))
        return IOSPreviewBuffer(pixelBuffer: output.pixelBuffer)
    }

    func reset() {
        session = nil
        geometry = nil
    }
}
