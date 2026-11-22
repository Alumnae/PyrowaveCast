import Foundation
#if canImport(SPPWCommon)
import SPPWCommon
#endif

// MARK: - Receiver wire protocol (mirrors macOS ReceiverProtocol.swift)

enum IOSReceiverMessageKind: UInt8 {
    case clientHello = 1
    case serverHello = 2
    case frameFragment = 3
    case input = 4
    case streamConfiguration = 5
    case ping = 6
    case pong = 7
    case fecParity = 8
    case audioFrame = 9
    /// Clipboard sync, both directions (`SPPWClipboardMessage`).
    case clipboard = 10
}

struct IOSReceiverWireHeader {
    static let magic: UInt32 = 0x5350_5057
    static let version: UInt8 = 1
    static let byteCount = 40

    let kind: IOSReceiverMessageKind
    let flags: UInt16
    let streamID: UInt32
    let frameID: UInt32
    let width: UInt16
    let height: UInt16
    let fragmentIndex: UInt16
    let fragmentCount: UInt16
    let frameByteCount: UInt32
    let timestampNanoseconds: UInt64
    let payloadChecksum: UInt32

    init?(_ data: Data) {
        guard let sppwHeader = SPPWDatagramHeader(data),
              let kind = IOSReceiverMessageKind(rawValue: sppwHeader.kind.rawValue) else {
            return nil
        }
        self.kind = kind
        self.flags = sppwHeader.flags
        self.streamID = sppwHeader.streamID
        self.frameID = sppwHeader.frameID
        self.width = sppwHeader.width
        self.height = sppwHeader.height
        self.fragmentIndex = sppwHeader.fragmentIndex
        self.fragmentCount = sppwHeader.fragmentCount
        self.frameByteCount = sppwHeader.frameByteCount
        self.timestampNanoseconds = sppwHeader.timestampNanoseconds
        self.payloadChecksum = sppwHeader.payloadChecksum
    }

    var sppwHeader: SPPWDatagramHeader? {
        guard let sppwKind = SPPWMessageKind(rawValue: kind.rawValue) else { return nil }
        return SPPWDatagramHeader(
            kind: sppwKind,
            flags: flags,
            streamID: streamID,
            frameID: frameID,
            width: width,
            height: height,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            frameByteCount: frameByteCount,
            timestampNanoseconds: timestampNanoseconds,
            payloadChecksum: payloadChecksum
        )
    }

    static func control(
        _ kind: IOSReceiverMessageKind,
        streamID: UInt32 = 0,
        payload: Data = Data(),
        flags: UInt16 = 0
    ) -> Data {
        var packet = Data(capacity: byteCount + payload.count)
        packet.iosAppendBE(magic)
        packet.append(version)
        packet.append(kind.rawValue)
        packet.iosAppendBE(flags)
        packet.iosAppendBE(streamID)
        packet.iosAppendBE(UInt32(0))
        packet.iosAppendBE(UInt16(0))
        packet.iosAppendBE(UInt16(0))
        packet.iosAppendBE(UInt16(0))
        packet.iosAppendBE(UInt16(1))
        packet.iosAppendBE(UInt32(clamping: payload.count))
        packet.iosAppendBE(DispatchTime.now().uptimeNanoseconds)
        packet.iosAppendBE(UInt32(0))
        packet.append(payload)
        return packet
    }
}

struct IOSReceiverCompleteFrame: Sendable {
    let frameID: UInt32
    let width: Int
    let height: Int
    let data: Data
    let receivedAt: PyrowaveClock.Instant
    let senderTimestampNanoseconds: UInt64
    let recoveredWithFEC: Bool
    let isPartialHF: Bool

    init(_ assembled: SPPWAssembledFrame) {
        self.frameID = assembled.frameID
        self.width = assembled.width
        self.height = assembled.height
        self.data = assembled.data
        self.receivedAt = PyrowaveClock.Instant(uptimeNanoseconds: assembled.receivedAtNanoseconds)
        self.senderTimestampNanoseconds = assembled.senderTimestampNanoseconds
        self.recoveredWithFEC = assembled.recoveredWithFEC
        self.isPartialHF = assembled.isPartialHF
    }
}

struct IOSReceiverFrameAssembler {
    private var core = SPPWFrameAssembler()

    var expiredFrames: Int { core.expiredFrames }
    var llDroppedFrames: Int { core.llDroppedFrames }
    var fecRecoveredPackets: Int { core.fecRecoveredPackets }
    var fecRecoveredFrames: Int { core.fecRecoveredFrames }
    var partialHFFrames: Int { core.partialHFFrames }
    var malformedDatagrams: Int { core.malformedDatagrams }

    mutating func ingest(
        _ data: Data,
        parsedHeader: IOSReceiverWireHeader? = nil,
        timeoutMilliseconds: Int = 35,
        allowPartialHFDecode: Bool = true
    ) -> IOSReceiverCompleteFrame? {
        guard let assembled = core.ingest(
            data,
            parsedHeader: parsedHeader?.sppwHeader,
            timeoutMilliseconds: timeoutMilliseconds,
            allowPartialHFDecode: allowPartialHFDecode
        ) else {
            return nil
        }
        return IOSReceiverCompleteFrame(assembled)
    }

    mutating func reset() {
        core.reset()
    }
}

struct IOSReceiverWireSettings: Sendable {
    var width: UInt16 = 1920
    var height: UInt16 = 1080
    var fps: UInt16 = 60
    var automaticBitrate = true
    var latencyMode: UInt8 = 1
    var bitrate: UInt32 = 180_000_000
    var quality: UInt16 = 8_200
    var fec: UInt16 = 18
    var mtu: UInt16 = 1200
    var frameTimeout: UInt16 = 35
    var bufferedFrames: UInt8 = 1
    var colorRange: UInt8 = 0

    var payload: Data {
        var data = Data(capacity: 24)
        data.iosAppendBE(width)
        data.iosAppendBE(height)
        data.iosAppendBE(fps)
        data.append(automaticBitrate ? 1 : 0)
        data.append(latencyMode)
        data.iosAppendBE(bitrate)
        data.iosAppendBE(quality)
        data.iosAppendBE(fec)
        data.iosAppendBE(mtu)
        data.iosAppendBE(frameTimeout)
        data.append(bufferedFrames)
        data.append(colorRange)
        data.append(0)
        data.append(0)
        return data
    }
}

// MARK: - Binary helpers

private extension Data {
    mutating func iosAppendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func iosAppendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func iosAppendBE(_ value: UInt64) {
        iosAppendBE(UInt32(truncatingIfNeeded: value >> 32))
        iosAppendBE(UInt32(truncatingIfNeeded: value))
    }
}
