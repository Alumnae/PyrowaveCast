import CoreImage
import CoreVideo
import Foundation
import Metal
import PyrowaveKit

/// A decoded frame ready for display.
///
/// Carries the raw `CVPixelBuffer` instead of a pre-rendered `CGImage`.
/// The old path called `CIContext.createCGImage` on every frame, which runs
/// a full CoreImage tiling/render pass and allocates a bitmap — pure CPU/GPU
/// overhead that adds latency. The display layer now consumes the pixel
/// buffer directly through a Metal-backed render destination.
struct MacDecodedReceiverFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let frameID: UInt32
    let decodeMilliseconds: Double
    let ageMilliseconds: Double
    let recoveredWithFEC: Bool
    let isPartialHF: Bool
    /// Server capture instant (`SPPWCaptureClock`), used for audio/video sync.
    let senderTimestampNanoseconds: UInt64
    /// A newer frame was already waiting when this decode finished. Only superseded
    /// frames are dropped for being late: the newest frame is always shown, so a slow
    /// first decode (session setup at 4K+) or a still screen never leaves the view empty.
    let isSuperseded: Bool
}

actor LatestFrameDecoder {
    typealias OutputHandler = @MainActor @Sendable (MacDecodedReceiverFrame) -> Void
    typealias ErrorHandler = @MainActor @Sendable (String) -> Void

    private var pending: ReceiverCompleteFrame?
    private var draining = false
    private var session: PyrowaveDecoderSession?
    private var sessionSize: (Int, Int)?
    /// NV12 for 4:2:0 streams, BGRA for 4:4:4 ones.
    private var sessionPixelFormat: OSType?
    private var generation: UInt64 = 0
    private var droppedFrames = 0
    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler

    init(outputHandler: @escaping OutputHandler, errorHandler: @escaping ErrorHandler) {
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
    }

    func submit(_ frame: ReceiverCompleteFrame) {
        if pending != nil { droppedFrames += 1 }
        pending = frame
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    func reset() {
        generation &+= 1
        pending = nil
        session = nil
        sessionSize = nil
        sessionPixelFormat = nil
        droppedFrames = 0
    }

    private func drain() async {
        while let frame = pending {
            pending = nil
            let currentGeneration = generation
            do {
                let pixelFormat = PyrowaveSessionDescriptor.preferredPixelFormat(forBitstream: frame.data)
                if session == nil || sessionSize?.0 != frame.width || sessionSize?.1 != frame.height
                    || sessionPixelFormat != pixelFormat {
                    let descriptor = try PyrowaveSessionDescriptor(
                        width: frame.width,
                        height: frame.height,
                        pixelFormat: pixelFormat,
                        videoSignal: VideoSignalMetadata(yCbCrRange: .full)
                    )
                    // Pre-warm 4 output buffers so triple-buffered display
                    // (AVSampleBufferDisplayLayer + currentPixelBuffer + in-flight
                    // Metal decode) never causes mid-stream IOSurface allocations.
                    session = try PyrowaveDecoderSession(descriptor: descriptor, minimumOutputBufferCount: 4)
                    sessionSize = (frame.width, frame.height)
                    sessionPixelFormat = pixelFormat
                }
                guard let session else { continue }
                let start = ContinuousClock.now
                let decoded = try await session.decode(
                    EncodedFrame(data: frame.data),
                    allowPartialFrame: frame.isPartialHF
                )
                guard currentGeneration == generation else { continue }

                let decodeTime = start.duration(to: .now)
                let decodeMilliseconds = Double(decodeTime.components.seconds) * 1_000
                    + Double(decodeTime.components.attoseconds) / 1_000_000_000_000_000
                let age = frame.receivedAt.duration(to: .now)
                let ageMilliseconds = Double(age.components.seconds) * 1_000
                    + Double(age.components.attoseconds) / 1_000_000_000_000_000
                await outputHandler(MacDecodedReceiverFrame(
                    pixelBuffer: decoded.pixelBuffer,
                    frameID: frame.frameID,
                    decodeMilliseconds: decodeMilliseconds,
                    ageMilliseconds: ageMilliseconds,
                    recoveredWithFEC: frame.recoveredWithFEC,
                    isPartialHF: frame.isPartialHF,
                    senderTimestampNanoseconds: frame.senderTimestampNanoseconds,
                    isSuperseded: pending != nil
                ))
            } catch {
                await errorHandler("PyroWave decode failed: \(error)")
            }
        }
        draining = false
    }
}
