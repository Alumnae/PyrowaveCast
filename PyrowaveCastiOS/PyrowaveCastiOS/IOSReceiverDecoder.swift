import CoreVideo
import Foundation

struct IOSDecodedReceiverFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let frameID: UInt32
    let decodeMilliseconds: Double
    let ageMilliseconds: Double
    let skippedWhileBusy: Int
    let recoveredWithFEC: Bool
    let isPartialHF: Bool
    /// Server capture instant (`SPPWCaptureClock`), used for audio/video sync.
    let senderTimestampNanoseconds: UInt64
}

/// Decodes PyroWave bitstream frames on a background actor using a 1-slot
/// latest-frame replacement queue (`pending`) and drain loop.
///
/// Previously, `decode(_:)` returned `.busy` and immediately dropped any frame
/// that arrived while a decode was still finishing — if frame N+1 arrived 0.5 ms
/// before frame N finished, frame N+1 was lost completely and the display froze
/// until frame N+2 arrived (~33 ms later). Holding a 1-slot `pending` frame
/// guarantees the newest frame is decoded immediately after the current decode
/// finishes without building a multi-frame latency backlog.
actor IOSReceiverDecoder {
    typealias OutputHandler = @MainActor @Sendable (IOSDecodedReceiverFrame) -> Void
    typealias ErrorHandler = @MainActor @Sendable (UInt32, String) -> Void

    private var pending: IOSReceiverCompleteFrame?
    private var draining = false
    private var skippedCount = 0
    private var session: PyrowaveDecoderSession?
    private var size: (width: Int, height: Int)?
    /// NV12 for 4:2:0 streams, BGRA for 4:4:4 ones.
    private var sessionPixelFormat: OSType?
    private var generation: UInt64 = 0
    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler

    init(outputHandler: @escaping OutputHandler, errorHandler: @escaping ErrorHandler) {
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
    }

    func submit(_ frame: IOSReceiverCompleteFrame) {
        if pending != nil {
            skippedCount += 1
        }
        pending = frame
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    func reset() {
        generation &+= 1
        pending = nil
        skippedCount = 0
        session = nil
        size = nil
    }

    private func drain() async {
        while let frame = pending {
            pending = nil
            let skipped = skippedCount
            skippedCount = 0
            let currentGeneration = generation
            do {
                let pixelFormat = PyrowaveSessionDescriptor.preferredPixelFormat(forBitstream: frame.data)
                if session == nil || size?.width != frame.width || size?.height != frame.height
                    || sessionPixelFormat != pixelFormat {
                    let descriptor = try PyrowaveSessionDescriptor(
                        width: frame.width,
                        height: frame.height,
                        pixelFormat: pixelFormat,
                        videoSignal: VideoSignalMetadata(yCbCrRange: .full)
                    )
                    // Pre-warm 4 output buffers so triple-buffered display +
                    // in-flight Metal decode never exhausts the CVPixelBufferPool.
                    session = try PyrowaveDecoderSession(descriptor: descriptor, minimumOutputBufferCount: 4)
                    size = (frame.width, frame.height)
                    sessionPixelFormat = pixelFormat
                }
                guard let session else { continue }
                let start = DispatchTime.now()
                let result = try await session.decode(
                    EncodedFrame(data: frame.data),
                    allowPartialFrame: frame.isPartialHF
                )
                guard currentGeneration == generation else { continue }

                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                let ageDuration = frame.receivedAt.duration(to: PyrowaveClock.now)
                let ageMs = Double(ageDuration.components.seconds) * 1000
                    + Double(ageDuration.components.attoseconds) / 1_000_000_000_000_000
                await outputHandler(IOSDecodedReceiverFrame(
                    pixelBuffer: result.pixelBuffer,
                    frameID: frame.frameID,
                    decodeMilliseconds: elapsed,
                    ageMilliseconds: ageMs,
                    skippedWhileBusy: skipped,
                    recoveredWithFEC: frame.recoveredWithFEC,
                    isPartialHF: frame.isPartialHF,
                    senderTimestampNanoseconds: frame.senderTimestampNanoseconds
                ))
            } catch {
                // Reset session on fatal errors so the next frame retries cleanly.
                session = nil
                size = nil
                await errorHandler(frame.frameID, String(describing: error))
            }
        }
        draining = false
    }
}
