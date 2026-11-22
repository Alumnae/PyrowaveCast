import Foundation
import Network
#if canImport(SPPWCommon)
import SPPWCommon
#endif

// MARK: - SPPW/1 Wire Protocol

public enum WireMessageKind: UInt8, Sendable {
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

public struct WireHeader: Sendable {
    static let magic: UInt32 = 0x5350_5057 // "SPPW"
    static let version: UInt8 = 1
    static let byteCount = 40

    let kind: WireMessageKind
    let flags: UInt16
    let streamID: UInt32
    let frameID: UInt32
    let width: UInt16
    let height: UInt16
    let fragmentIndex: UInt16
    let fragmentCount: UInt16
    let frameByteCount: UInt32
    let senderTimestampNanoseconds: UInt64
    let payloadChecksum: UInt32
}

// MARK: - Binary helpers

extension Data {
    func uint16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
    func uint32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
        UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
    func uint64BE(at offset: Int) -> UInt64 {
        UInt64(uint32BE(at: offset)) << 32 | UInt64(uint32BE(at: offset + 4))
    }

    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func appendBE(_ value: UInt64) {
        appendBE(UInt32(truncatingIfNeeded: value >> 32))
        appendBE(UInt32(truncatingIfNeeded: value))
    }

}

func parseWireHeader(_ data: Data) -> WireHeader? {
    guard data.count >= WireHeader.byteCount,
          data.uint32BE(at: 0) == WireHeader.magic,
          data[4] == WireHeader.version,
          let kind = WireMessageKind(rawValue: data[5]) else { return nil }
    return WireHeader(
        kind: kind,
        flags: data.uint16BE(at: 6),
        streamID: data.uint32BE(at: 8),
        frameID: data.uint32BE(at: 12),
        width: data.uint16BE(at: 16),
        height: data.uint16BE(at: 18),
        fragmentIndex: data.uint16BE(at: 20),
        fragmentCount: data.uint16BE(at: 22),
        frameByteCount: data.uint32BE(at: 24),
        senderTimestampNanoseconds: data.uint64BE(at: 28),
        payloadChecksum: data.uint32BE(at: 36)
    )
}

public enum WireControlFlags {
    /// Set by the server on `serverHello` and `streamConfiguration` ACK when
    /// the server enforces its own screen resolution (Screen Capture mode).
    public static let serverControlledResolution: UInt16 = 1 << 0
}

func makeWireDatagram(
    kind: WireMessageKind,
    streamID: UInt32,
    flags: UInt16 = 0,
    frameID: UInt32 = 0,
    width: UInt16 = 0,
    height: UInt16 = 0,
    fragmentIndex: UInt16 = 0,
    fragmentCount: UInt16 = 1,
    frameByteCount: UInt32 = 0,
    payload: Data = Data()
) -> Data {
    var result = Data(capacity: WireHeader.byteCount + payload.count)
    result.appendBE(WireHeader.magic)
    result.append(WireHeader.version)
    result.append(kind.rawValue)
    result.appendBE(flags)
    result.appendBE(streamID)
    result.appendBE(frameID)
    result.appendBE(width)
    result.appendBE(height)
    result.appendBE(fragmentIndex)
    result.appendBE(fragmentCount)
    result.appendBE(frameByteCount)
    result.appendBE(DispatchTime.now().uptimeNanoseconds)
    // SPPW/1 no longer checksums payloads (UDP already has a checksum and FEC
    // repairs losses); the header field is kept for layout compatibility and is always 0.
    result.appendBE(UInt32(0))
    result.append(payload)
    return result
}

/// Builds an SPPW/1 `.frameFragment` datagram directly from a range of the
/// encoded frame bitstream without allocating an intermediate `subdata` copy.
@inline(__always)
func makeWireFragmentDatagram(
    streamID: UInt32,
    frameID: UInt32,
    flags: UInt16 = 0,
    width: UInt16,
    height: UInt16,
    fragmentIndex: UInt16,
    fragmentCount: UInt16,
    frameByteCount: UInt32,
    timestampNanoseconds: UInt64,
    bitstream: Data,
    range: Range<Int>
) -> Data {
    let payloadCount = range.count
    var result = Data(capacity: WireHeader.byteCount + payloadCount)
    result.appendBE(WireHeader.magic)
    result.append(WireHeader.version)
    result.append(WireMessageKind.frameFragment.rawValue)
    result.appendBE(flags)
    result.appendBE(streamID)
    result.appendBE(frameID)
    result.appendBE(width)
    result.appendBE(height)
    result.appendBE(fragmentIndex)
    result.appendBE(fragmentCount)
    result.appendBE(frameByteCount)
    result.appendBE(timestampNanoseconds)
    result.appendBE(UInt32(0)) // payloadChecksum: unused, always 0
    result.append(bitstream[range])

    return result
}

/// Builds an SPPW/1 `.fecParity` (`kind == 8`) datagram carrying an 8-byte
/// `SPPWFECBlockHeader` followed by the GF(2^8) Reed-Solomon parity shard.
@inline(__always)
func makeWireFECParityDatagram(
    streamID: UInt32,
    frameID: UInt32,
    flags: UInt16,
    width: UInt16,
    height: UInt16,
    parityIndex: UInt16,
    totalDataFragments: UInt16,
    frameByteCount: UInt32,
    timestampNanoseconds: UInt64,
    blockHeader: SPPWFECBlockHeader,
    parityShard: Data
) -> Data {
    let payloadCount = SPPWFECBlockHeader.byteCount + parityShard.count
    var result = Data(capacity: WireHeader.byteCount + payloadCount)
    result.appendBE(WireHeader.magic)
    result.append(WireHeader.version)
    result.append(WireMessageKind.fecParity.rawValue)
    result.appendBE(flags)
    result.appendBE(streamID)
    result.appendBE(frameID)
    result.appendBE(width)
    result.appendBE(height)
    result.appendBE(parityIndex)
    result.appendBE(totalDataFragments)
    result.appendBE(frameByteCount)
    result.appendBE(timestampNanoseconds)
    result.appendBE(UInt32(0)) // payloadChecksum: unused, always 0
    blockHeader.encode(into: &result)
    result.append(parityShard)

    return result
}

/// Builds an SPPW/1 `.audioFrame` (`kind == 9`) datagram carrying one 5 ms PCM16 packet.
public func makeWireAudioDatagram(
    streamID: UInt32,
    sequence: UInt32 = 0,
    timestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
    audioPayload: Data
) -> Data {
    var result = Data(capacity: WireHeader.byteCount + audioPayload.count)
    result.appendBE(WireHeader.magic)
    result.append(WireHeader.version)
    result.append(WireMessageKind.audioFrame.rawValue)
    result.appendBE(UInt16(0))
    result.appendBE(streamID)
    result.appendBE(sequence)
    result.appendBE(UInt16(0))
    result.appendBE(UInt16(0))
    result.appendBE(UInt16(0))
    result.appendBE(UInt16(1))
    result.appendBE(UInt32(clamping: audioPayload.count))
    result.appendBE(timestampNanoseconds)
    result.appendBE(UInt32(0))
    result.append(audioPayload)
    return result
}

/// Fragments an encoded PyroWave frame and interleaves asymmetric LL/HF
/// Reed-Solomon GF(2^8) parity shards right behind each protected block.
///
/// Order on the wire:
/// 1. LL data fragments (flagged `.llCritical`) immediately followed by LL parity
///    shards so the base image is protected and delivered first.
/// 2. Each HF block's data fragments followed by that block's parity shards.
public func buildPacedFrameDatagrams(
    streamID: UInt32,
    frameID: UInt32,
    width: UInt16,
    height: UInt16,
    timestampNanoseconds: UInt64,
    bitstream: Data,
    payloadLimit: Int,
    fecPercent: Int
) -> [Data] {
    let totalBytes = bitstream.count
    guard totalBytes > 0, payloadLimit > 0 else { return [] }
    let fragmentTotal = (totalBytes + payloadLimit - 1) / payloadLimit
    guard fragmentTotal <= 16_384 else { return [] }

    let boundary = SPPWPyrowaveSubbandInspector.inspectLLBoundary(bitstream: bitstream)
    let llFragmentCount = boundary?.llFragmentCount(payloadLimit: payloadLimit, totalFragments: fragmentTotal)
        ?? min(max(1, fragmentTotal / 12), fragmentTotal)

    let fecGroups = SPPWFECPlanner.makePlan(
        totalDataFragments: fragmentTotal,
        llFragmentCount: llFragmentCount,
        fecPercent: fecPercent
    )
    let hasFEC = !fecGroups.isEmpty
    let totalParity = fecGroups.reduce(0) { $0 + $1.parityCount }

    var datagrams: [Data] = []
    datagrams.reserveCapacity(fragmentTotal + totalParity)

    let fragmentCount16 = UInt16(fragmentTotal)
    let frameByteCount32 = UInt32(totalBytes)

    if !hasFEC {
        for index in 0..<fragmentTotal {
            let lower = index * payloadLimit
            let upper = min(lower + payloadLimit, totalBytes)
            let flags: UInt16 = index < llFragmentCount ? SPPWFragmentFlags.llCritical : 0
            datagrams.append(makeWireFragmentDatagram(
                streamID: streamID,
                frameID: frameID,
                flags: flags,
                width: width,
                height: height,
                fragmentIndex: UInt16(index),
                fragmentCount: fragmentCount16,
                frameByteCount: frameByteCount32,
                timestampNanoseconds: timestampNanoseconds,
                bitstream: bitstream,
                range: lower..<upper
            ))
        }
        return datagrams
    }

    // Emit each FEC group's data fragments immediately followed by its RS parity shards.
    for group in fecGroups {
        let blockStart = group.startFragment
        let blockEnd = blockStart + group.dataCount
        for index in blockStart..<blockEnd {
            let lower = index * payloadLimit
            let upper = min(lower + payloadLimit, totalBytes)
            var flags: UInt16 = SPPWFragmentFlags.fecProtected
            if group.isLLGroup || index < llFragmentCount {
                flags |= SPPWFragmentFlags.llCritical
            }
            datagrams.append(makeWireFragmentDatagram(
                streamID: streamID,
                frameID: frameID,
                flags: flags,
                width: width,
                height: height,
                fragmentIndex: UInt16(index),
                fragmentCount: fragmentCount16,
                frameByteCount: frameByteCount32,
                timestampNanoseconds: timestampNanoseconds,
                bitstream: bitstream,
                range: lower..<upper
            ))
        }

        // Compute the fixed shard size for this block (fits within payloadLimit - 8
        // when block has 1 short fragment, or uses exact shard payload length).
        // Note: all non-final data fragments have length `payloadLimit`.
        let blockStartByte = blockStart * payloadLimit
        let shardSize = group.dataCount == 1
            ? min(payloadLimit, totalBytes - blockStartByte)
            : payloadLimit
        let parities = SPPWReedSolomonGF256.encodeParity(
            bitstream: bitstream,
            blockStartOffset: blockStartByte,
            dataCount: group.dataCount,
            parityCount: group.parityCount,
            shardSize: shardSize
        )
        let blockHeader = SPPWFECBlockHeader(
            blockStartFragment: UInt16(blockStart),
            blockDataCount: UInt16(group.dataCount),
            blockParityCount: UInt16(group.parityCount),
            shardPayloadSize: UInt16(shardSize)
        )
        let parityFlags: UInt16 = SPPWFragmentFlags.fecProtected | (group.isLLGroup ? SPPWFragmentFlags.llCritical : 0)
        for (pIdx, shard) in parities.enumerated() {
            datagrams.append(makeWireFECParityDatagram(
                streamID: streamID,
                frameID: frameID,
                flags: parityFlags,
                width: width,
                height: height,
                parityIndex: UInt16(pIdx),
                totalDataFragments: fragmentCount16,
                frameByteCount: frameByteCount32,
                timestampNanoseconds: timestampNanoseconds,
                blockHeader: blockHeader,
                parityShard: shard
            ))
        }
    }

    return datagrams
}

/// Overload alias with `timestampNanoseconds` as trailing parameter.
public func buildPacedFrameDatagrams(
    streamID: UInt32,
    frameID: UInt32,
    width: UInt16,
    height: UInt16,
    bitstream: Data,
    payloadLimit: Int,
    fecPercent: Int,
    timestampNanoseconds: UInt64
) -> [Data] {
    buildPacedFrameDatagrams(
        streamID: streamID,
        frameID: frameID,
        width: width,
        height: height,
        timestampNanoseconds: timestampNanoseconds,
        bitstream: bitstream,
        payloadLimit: payloadLimit,
        fecPercent: fecPercent
    )
}

// MARK: - Client configuration

public struct ClientConfiguration: Sendable {
    public var width: Int = 0
    public var height: Int = 0
    public var fps: Int = 60
    public var automaticBitrate: Bool = true
    public var latencyMode: UInt8 = 1
    public var maxBitrate: Int = 80_000_000
    public var quality: Double = 0.5
    public var fecPercent: Int = 10
    public var mtu: Int = 1200
    public var frameTimeoutMs: Int = 12
    public var maxBufferedFrames: Int = 0
    public var colorRange: UInt8 = 0
}

public func parseClientConfig(_ payload: Data) -> ClientConfiguration? {
    guard payload.count >= 22 else { return nil }
    var config = ClientConfiguration()
    var offset = 0
    config.width = Int(payload.uint16BE(at: offset)); offset += 2
    config.height = Int(payload.uint16BE(at: offset)); offset += 2
    config.fps = Int(payload.uint16BE(at: offset)); offset += 2
    config.automaticBitrate = payload[offset] != 0; offset += 1
    config.latencyMode = payload[offset]; offset += 1
    config.maxBitrate = Int(payload.uint32BE(at: offset)); offset += 4
    config.quality = Double(payload.uint16BE(at: offset)) / 10_000.0; offset += 2
    config.fecPercent = Int(payload.uint16BE(at: offset)); offset += 2
    config.mtu = Int(payload.uint16BE(at: offset)); offset += 2
    config.frameTimeoutMs = Int(payload.uint16BE(at: offset)); offset += 2
    config.maxBufferedFrames = Int(payload[offset]); offset += 1
    config.colorRange = payload[offset]; offset += 1
    return config
}

public extension ClientConfiguration {
    /// Clamps the requested settings to values the server can actually serve.
    ///
    /// The client is free to ask for anything, so a malformed or hostile
    /// configuration must not be able to allocate an absurd frame size or
    /// stall the encoder.
    func sanitised() -> ClientConfiguration {
        var config = self
        config.width = config.width > 0 ? min(config.width, 3840) : 0
        config.height = config.height > 0 ? min(config.height, 2160) : 0
        // 4:2:0 needs even dimensions.
        config.width -= config.width % 2
        config.height -= config.height % 2
        config.fps = min(max(config.fps, 1), 120)
        config.mtu = min(max(config.mtu, 256), 9_000)
        config.quality = min(max(config.quality, 0.01), 1.0)
        config.maxBitrate = min(max(config.maxBitrate, 1_000_000), 1_000_000_000)
        config.fecPercent = min(max(config.fecPercent, 0), 100)
        return config
    }
}

struct ClientSession: Sendable {
    let streamID: UInt32
    var peer: SPPWUDPPeerAddress
    var peerAddress: String
    var config: ClientConfiguration
    var lastSeen: UInt64 = DispatchTime.now().uptimeNanoseconds
}

// MARK: - Shared server helpers

/// The largest stream size with the aspect ratio of `width`×`height` that fits
/// 3840×2160, with even sides (4:2:0 needs them). Screen capture streams at
/// this size, so the server rather than the client decides the resolution.
func clampedEvenStreamResolution(width: Int, height: Int) -> (width: Int, height: Int) {
    let sourceWidth = max(width, 320)
    let sourceHeight = max(height, 240)
    let scale = min(1.0, 3840.0 / Double(sourceWidth), 2160.0 / Double(sourceHeight))
    let scaledWidth = Int((Double(sourceWidth) * scale).rounded(.down)) & ~1
    let scaledHeight = Int((Double(sourceHeight) * scale).rounded(.down)) & ~1
    return (max(scaledWidth, 320), max(scaledHeight, 240))
}

/// The active non-loopback IPv4 LAN address (`en0`/`en1` preferred, excluding virtual/tunnel interfaces),
/// so Bonjour records and the UI carry a directly routable LAN address.
func preferredLocalIPv4Address() -> String? {
    SPPWNetworkInterface.preferredLocalIPv4Address()
}
