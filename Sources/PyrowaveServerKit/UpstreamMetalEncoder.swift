import Foundation
import CoreVideo
import Metal
import IOSurface
#if canImport(CPyrowaveMetal)
import CPyrowaveMetal
#endif

/// Wraps the vendored upstream PyroWave Metal encoder
/// (https://github.com/Themaister/pyrowave, MIT licensed).
///
/// The upstream exposes a C API that consumes IOSurface backed input directly,
/// which lets frames captured by ScreenCaptureKit be encoded on the GPU without
/// a CPU round trip.
final class UpstreamMetalEncoder: @unchecked Sendable {
    enum EncoderError: Error, CustomStringConvertible {
        case deviceCreationFailed(String)
        case encoderCreationFailed(String)
        case encodeFailed(String)
        case noIOSurface
        case packetizeFailed(String)

        var description: String {
            switch self {
            case .deviceCreationFailed(let detail):
                return "Could not create the Metal device: \(detail)"
            case .encoderCreationFailed(let detail):
                return "Could not create the PyroWave encoder: \(detail)"
            case .encodeFailed(let detail):
                return "PyroWave encode failed: \(detail)"
            case .noIOSurface:
                return "The captured frame is not backed by an IOSurface."
            case .packetizeFailed(let detail):
                return "PyroWave packetization failed: \(detail)"
            }
        }
    }

    private var device: OpaquePointer?
    private var encoder: OpaquePointer?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderChroma = PYROWAVE_CHROMA_SUBSAMPLING_420
    /// Reused bitstream output buffer. The encoder previously allocated and
    /// zeroed a fresh `[UInt8]` of `maximumBitstreamBytes + 65_536` on every
    /// frame — at 180 Mb/s / 60 fps that is ~26 MB/s of pointless allocation
    /// and memset work. This buffer grows lazily and is reused across frames.
    private var bitstreamBuffer: [UInt8] = []

    init() throws {
        var createdDevice: OpaquePointer?
        let result = pyrowave_create_default_device(&createdDevice)
        guard result == PYROWAVE_SUCCESS, let createdDevice else {
            throw EncoderError.deviceCreationFailed(Self.describe(result))
        }
        device = createdDevice
    }

    deinit {
        if let encoder {
            pyrowave_encoder_destroy(encoder)
        }
        if let device {
            pyrowave_device_destroy(device)
        }
    }

    /// Encodes a CVPixelBuffer and returns the contiguous bitstream together
    /// with the packet slices that make it up.
    func encode(
        pixelBuffer: CVPixelBuffer,
        maximumBitstreamBytes: Int,
        packetBoundary: Int
    ) throws -> (bitstream: Data, packets: [pyrowave_packet]) {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw EncoderError.encodeFailed("Frame must have even dimensions, got \(width)x\(height)")
        }

        // 4:4:4 is selected by the capture format: a biplanar surface whose chroma
        // plane is full resolution ('444f' / 'xf44') feeds a 4:4:4 encoder, anything
        // else (NV12 / P010) keeps 4:2:0. The chroma mode travels in the PyroWave
        // sequence header, so receivers pick it up without any SPPW/1 change.
        let chroma = Self.chromaSubsampling(of: pixelBuffer, width: width, height: height)

        if encoder == nil || encoderWidth != width || encoderHeight != height || encoderChroma != chroma {
            if let stale = encoder {
                pyrowave_encoder_destroy(stale)
            }
            encoder = nil

            var info = pyrowave_encoder_create_info()
            info.device = device
            info.width = Int32(width)
            info.height = Int32(height)
            info.chroma = chroma

            var newEncoder: OpaquePointer?
            let createResult = pyrowave_encoder_create(&info, &newEncoder)
            guard createResult == PYROWAVE_SUCCESS, let newEncoder else {
                throw EncoderError.encoderCreationFailed(Self.describe(createResult))
            }
            encoder = newEncoder
            encoderWidth = width
            encoderHeight = height
            encoderChroma = chroma
        }
        guard let activeEncoder = encoder else {
            throw EncoderError.encoderCreationFailed("encoder was not created")
        }

        var rateControl = pyrowave_rate_control()
        rateControl.maximum_bitstream_size = maximumBitstreamBytes

        let encodeResult: pyrowave_result
        if let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) {
            let surface = surfaceRef.takeUnretainedValue()
            let chromaDivisor = chroma == PYROWAVE_CHROMA_SUBSAMPLING_444 ? 1 : 2
            let matchesBiplanarLayout = IOSurfaceGetPlaneCount(surface) == 2
                && IOSurfaceGetWidthOfPlane(surface, 0) == width
                && IOSurfaceGetHeightOfPlane(surface, 0) == height
                && IOSurfaceGetWidthOfPlane(surface, 1) == width / chromaDivisor
                && IOSurfaceGetHeightOfPlane(surface, 1) == height / chromaDivisor
            if matchesBiplanarLayout {
                // Direct zero-copy IOSurface lookup via CoreVideo without
                // allocating a transient CVMetalTexture on every frame.
                var gpuInput = pyrowave_gpu_input()
                gpuInput.planes.0 = UnsafeMutableRawPointer(mutating: Unmanaged.passUnretained(surface).toOpaque())
                gpuInput.planes.1 = nil
                gpuInput.planes.2 = nil
                encodeResult = pyrowave_encoder_encode_gpu(activeEncoder, &gpuInput, &rateControl)
            } else {
                encodeResult = try encodeCPU(
                    activeEncoder: activeEncoder,
                    pixelBuffer: pixelBuffer,
                    width: width,
                    height: height,
                    rateControl: &rateControl
                )
            }
        } else {
            encodeResult = try encodeCPU(
                activeEncoder: activeEncoder,
                pixelBuffer: pixelBuffer,
                width: width,
                height: height,
                rateControl: &rateControl
            )
        }
        guard encodeResult == PYROWAVE_SUCCESS else {
            throw EncoderError.encodeFailed(Self.describe(encodeResult))
        }

        // Packetizing blocks until the GPU work has completed.
        var packetCount = 0
        let countResult = pyrowave_encoder_compute_num_packets(
            activeEncoder,
            packetBoundary,
            &packetCount
        )
        guard countResult == PYROWAVE_SUCCESS else {
            throw EncoderError.packetizeFailed(Self.describe(countResult))
        }

        var packets = [pyrowave_packet](
            repeating: pyrowave_packet(offset: 0, size: 0),
            count: max(packetCount, 1)
        )
        var outPacketCount = 0

        // Grow the reusable buffer if this frame needs more room. The buffer
        // is not zeroed — `pyrowave_encoder_packetize` writes exactly
        // `totalBytes` into it and we slice that range below.
        let requiredCapacity = maximumBitstreamBytes + 65_536
        if bitstreamBuffer.count < requiredCapacity {
            bitstreamBuffer.reserveCapacity(requiredCapacity)
            bitstreamBuffer.append(contentsOf: [UInt8](repeating: 0, count: requiredCapacity - bitstreamBuffer.count))
        }

        let packetizeResult = pyrowave_encoder_packetize(
            activeEncoder,
            &packets,
            packetBoundary,
            &outPacketCount,
            &bitstreamBuffer,
            bitstreamBuffer.count
        )
        guard packetizeResult == PYROWAVE_SUCCESS else {
            throw EncoderError.packetizeFailed(Self.describe(packetizeResult))
        }

        // The upstream packets are contiguous slices of the bitstream, so the
        // frame size is the sum of the packet sizes.
        let totalBytes = packets.prefix(outPacketCount).reduce(0) { $0 + $1.size }
        let bitstream = Data(bitstreamBuffer[0..<min(totalBytes, bitstreamBuffer.count)])

        return (bitstream, Array(packets.prefix(outPacketCount)))
    }

    private func encodeCPU(
        activeEncoder: OpaquePointer,
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        rateControl: inout pyrowave_rate_control
    ) throws -> pyrowave_result {
        // The CPU upload path only understands 8-bit NV12; 4:4:4 capture is always
        // IOSurface backed, so it never needs this fallback.
        guard encoderChroma == PYROWAVE_CHROMA_SUBSAMPLING_420 else {
            throw EncoderError.encodeFailed("4:4:4 frames must be IOSurface backed biplanar buffers")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw EncoderError.noIOSurface
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        var cpuInput = pyrowave_cpu_buffer()
        cpuInput.data.0 = yBase
        cpuInput.data.1 = uvBase
        cpuInput.data.2 = nil
        cpuInput.row_stride_in_bytes.0 = yStride
        cpuInput.row_stride_in_bytes.1 = uvStride
        cpuInput.row_stride_in_bytes.2 = 0
        cpuInput.plane_size_in_bytes.0 = yStride * yHeight
        cpuInput.plane_size_in_bytes.1 = uvStride * uvHeight
        cpuInput.plane_size_in_bytes.2 = 0
        cpuInput.width = Int32(width)
        cpuInput.height = Int32(height)
        cpuInput.format = PYROWAVE_CPU_BUFFER_FORMAT_NV12
        return pyrowave_encoder_encode_cpu(activeEncoder, &cpuInput, &rateControl)
    }

    /// 4:4:4 when the second plane of a biplanar buffer is full resolution.
    static func chromaSubsampling(of pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> pyrowave_chroma_subsampling {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) == height else {
            return PYROWAVE_CHROMA_SUBSAMPLING_420
        }
        return PYROWAVE_CHROMA_SUBSAMPLING_444
    }

    private static func describe(_ result: pyrowave_result) -> String {
        guard let text = pyrowave_result_to_string(result) else { return "unknown error" }
        return String(cString: text)
    }
}
