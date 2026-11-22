import Dispatch
import Foundation

// MARK: - SPPW/1 Message Kind, Datagram Header & Reassembled Frame

public enum SPPWMessageKind: UInt8, Sendable, Equatable {
    case clientHello = 1
    case serverHello = 2
    case frameFragment = 3
    case input = 4
    case streamConfiguration = 5
    case ping = 6
    case pong = 7
    case fecParity = 8
    case audioFrame = 9
}

public struct SPPWDatagramHeader: Sendable, Equatable {
    public static let magic: UInt32 = 0x5350_5057 // "SPPW"
    public static let version: UInt8 = 1
    public static let byteCount = 40

    public let kind: SPPWMessageKind
    public var kindRawValue: UInt8 { kind.rawValue }
    public let flags: UInt16
    public let streamID: UInt32
    public let frameID: UInt32
    public let width: UInt16
    public let height: UInt16
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let frameByteCount: UInt32
    public let senderTimestampNanoseconds: UInt64
    public let payloadChecksum: UInt32

    public var timestampNanoseconds: UInt64 { senderTimestampNanoseconds }

    public init(
        kind: SPPWMessageKind,
        flags: UInt16,
        streamID: UInt32,
        frameID: UInt32,
        width: UInt16,
        height: UInt16,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        frameByteCount: UInt32,
        senderTimestampNanoseconds: UInt64,
        payloadChecksum: UInt32
    ) {
        self.kind = kind
        self.flags = flags
        self.streamID = streamID
        self.frameID = frameID
        self.width = width
        self.height = height
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.frameByteCount = frameByteCount
        self.senderTimestampNanoseconds = senderTimestampNanoseconds
        self.payloadChecksum = payloadChecksum
    }

    public init(
        kind: SPPWMessageKind,
        flags: UInt16,
        streamID: UInt32,
        frameID: UInt32,
        width: UInt16,
        height: UInt16,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        frameByteCount: UInt32,
        timestampNanoseconds: UInt64,
        payloadChecksum: UInt32
    ) {
        self.init(
            kind: kind,
            flags: flags,
            streamID: streamID,
            frameID: frameID,
            width: width,
            height: height,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            frameByteCount: frameByteCount,
            senderTimestampNanoseconds: timestampNanoseconds,
            payloadChecksum: payloadChecksum
        )
    }

    public init?(parsing data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        let s = data.startIndex

        @inline(__always)
        func u16(_ offset: Int) -> UInt16 {
            (UInt16(data[s + offset]) << 8) | UInt16(data[s + offset + 1])
        }

        @inline(__always)
        func u32(_ offset: Int) -> UInt32 {
            (UInt32(data[s + offset]) << 24) |
            (UInt32(data[s + offset + 1]) << 16) |
            (UInt32(data[s + offset + 2]) << 8) |
            UInt32(data[s + offset + 3])
        }

        @inline(__always)
        func u64(_ offset: Int) -> UInt64 {
            (UInt64(u32(offset)) << 32) | UInt64(u32(offset + 4))
        }

        guard u32(0) == Self.magic,
              data[s + 4] == Self.version,
              let parsedKind = SPPWMessageKind(rawValue: data[s + 5]) else {
            return nil
        }
        self.kind = parsedKind
        self.flags = u16(6)
        self.streamID = u32(8)
        self.frameID = u32(12)
        self.width = u16(16)
        self.height = u16(18)
        self.fragmentIndex = u16(20)
        self.fragmentCount = u16(22)
        self.frameByteCount = u32(24)
        self.senderTimestampNanoseconds = u64(28)
        self.payloadChecksum = u32(36)
    }

    public init?(_ data: Data) {
        self.init(parsing: data)
    }
}

public struct SPPWAssembledFrame: Sendable {
    public let streamID: UInt32
    public let frameID: UInt32
    public let width: Int
    public let height: Int
    public let bitstream: Data
    public let senderTimestampNanoseconds: UInt64
    public let receivedAt: ContinuousClock.Instant
    public let receivedAtNanoseconds: UInt64
    /// Number of erased data fragments reconstructed via GF($2^8$) Reed-Solomon FEC.
    public let fecRecoveredFragments: Int
    /// `true` when the coarse LL subband (`level == 4, band == 0`) was 100% received/recovered
    /// and the frame was salvaged with a valid block-aligned prefix despite missing trailing HF fragments.
    public let isPartialHF: Bool

    public var data: Data { bitstream }
    public var recoveredWithFEC: Bool { fecRecoveredFragments > 0 }
    public var timestampNanoseconds: UInt64 { senderTimestampNanoseconds }

    public init(
        streamID: UInt32,
        frameID: UInt32,
        width: Int,
        height: Int,
        bitstream: Data,
        senderTimestampNanoseconds: UInt64,
        receivedAt: ContinuousClock.Instant = ContinuousClock.now,
        receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        fecRecoveredFragments: Int = 0,
        isPartialHF: Bool = false
    ) {
        self.streamID = streamID
        self.frameID = frameID
        self.width = width
        self.height = height
        self.bitstream = bitstream
        self.senderTimestampNanoseconds = senderTimestampNanoseconds
        self.receivedAt = receivedAt
        self.receivedAtNanoseconds = receivedAtNanoseconds
        self.fecRecoveredFragments = fecRecoveredFragments
        self.isPartialHF = isPartialHF
    }
}

// MARK: - Wavelet-Aware Frame Reassembler (Reed-Solomon FEC + LL Drop + Partial-HF Salvage)

/// Shared SPPW/1 frame reassembler for macOS and iOS receivers.
///
/// Key capabilities:
/// 1. **GF($2^8$) Reed-Solomon Erasure Recovery (`kind == .fecParity`)**:
///    Reconstructs lost LL and HF data fragments on the fly as soon as a block receives
///    $K$ total shards (data + parity).
/// 2. **Immediate LL-Drop ("scartare LL quando necessario")**:
///    Tracks which fragments belong to the coarse LL wavelet subband (`SPPWFragmentFlags.llCritical`).
///    When a newer frame arrives and an older frame is still missing any LL fragment after FEC recovery,
///    the older frame is immediately discarded (`llDroppedFrames += 1`) instead of stalling the pipeline.
/// 3. **Partial-HF Salvage (`isPartialHF = true`)**:
///    When all LL fragments of an older or timed-out frame are intact and only trailing high-frequency
///    detail fragments were lost over Wi-Fi, extracts the longest block-aligned prefix of complete
///    PyroWave wavelet blocks so the Metal GPU decoder can still synthesize a clean frame.
public struct SPPWFrameAssembler: Sendable {
    private struct FECBlockState: Sendable {
        let header: SPPWFECBlockHeader
        let isLLBlock: Bool
        var parityShards: [Data?]
        var receivedParityCount: Int = 0
        var reconstructed: Bool = false

        init(header: SPPWFECBlockHeader, isLLBlock: Bool) {
            self.header = header
            self.isLLBlock = isLLBlock
            self.parityShards = [Data?](repeating: nil, count: Int(header.blockParityCount))
        }
    }

    private struct PartialFrame: Sendable {
        let streamID: UInt32
        let frameID: UInt32
        let width: Int
        let height: Int
        let expectedFragments: Int
        let expectedBytes: Int
        let senderTimestampNanoseconds: UInt64
        let firstArrival: ContinuousClock.Instant
        let firstArrivalNanoseconds: UInt64

        var fragments: [Data?]
        var llCriticalMask: [Bool]

        init(
            streamID: UInt32,
            frameID: UInt32,
            width: Int,
            height: Int,
            expectedFragments: Int,
            expectedBytes: Int,
            senderTimestampNanoseconds: UInt64,
            firstArrivalNanoseconds: UInt64
        ) {
            self.streamID = streamID
            self.frameID = frameID
            self.width = width
            self.height = height
            self.expectedFragments = expectedFragments
            self.expectedBytes = expectedBytes
            self.senderTimestampNanoseconds = senderTimestampNanoseconds
            self.firstArrival = .now
            self.firstArrivalNanoseconds = firstArrivalNanoseconds
            self.fragments = [Data?](repeating: nil, count: expectedFragments)
            self.llCriticalMask = [Bool](repeating: false, count: expectedFragments)
        }
        var highestLLFragmentIndex: Int = -1
        var receivedFragmentCount: Int = 0
        var receivedBytes: Int = 0
        var shardPayloadSize: Int = 0
        var fecRecoveredCount: Int = 0
        var fecBlocks: [UInt16: FECBlockState] = [:]

        /// Returns `true` if every known LL-critical fragment (`0 ... highestLLFragmentIndex`) is present.
        var hasCompleteLL: Bool {
            let llLimit = highestLLFragmentIndex >= 0
                ? highestLLFragmentIndex
                : max(0, min(expectedFragments - 1, expectedFragments / 12))
            guard llLimit < fragments.count else { return false }
            for idx in 0...llLimit {
                if fragments[idx] == nil {
                    return false
                }
            }
            return true
        }
    }

    private var partials: [UInt32: PartialFrame] = [:]
    private var newestFrameID: UInt32 = 0
    private var lastCompletedFrameID: UInt32 = 0
    private var hasCompletedFrame = false

    public private(set) var completedFrames: Int = 0
    public private(set) var droppedFrames: Int = 0
    public var expiredFrames: Int { droppedFrames }
    /// Number of incomplete frames immediately discarded because their coarse LL subband
    /// was missing/unrecoverable when a newer frame arrived ("scartare LL").
    public private(set) var llDroppedFrames: Int = 0
    /// Number of frames salvaged with 100% intact LL subband and partial HF detail subbands.
    public private(set) var partialHFDecodedFrames: Int = 0
    public var partialHFFrames: Int { partialHFDecodedFrames }
    /// Total number of lost UDP data fragments reconstructed via Reed-Solomon GF($2^8$) FEC.
    public private(set) var fecRecoveredFragments: Int = 0
    public var fecRecoveredPackets: Int { fecRecoveredFragments }
    /// Number of frames that required at least one Reed-Solomon FEC parity recovery.
    public private(set) var fecRecoveredFrames: Int = 0
    public private(set) var malformedDatagrams: Int = 0
    public private(set) var lastFrameWidth: Int = 0
    public private(set) var lastFrameHeight: Int = 0

    /// Maximum number of in-flight partial frames held simultaneously.
    public var maxInFlightFrames: Int = 4

    public init() {}

    /// Primary ingestion entrypoint used by `ReceiverFrameAssembler`, `IOSReceiverFrameAssembler`, and tests.
    public mutating func ingest(
        _ datagram: Data,
        parsedHeader: SPPWDatagramHeader? = nil,
        timeoutMilliseconds: Int = 14,
        allowPartialHFDecode: Bool = true,
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> SPPWAssembledFrame? {
        guard let header = parsedHeader ?? SPPWDatagramHeader(parsing: datagram) else {
            malformedDatagrams += 1
            return nil
        }
        return ingest(
            datagram: datagram,
            header: header,
            timeoutMilliseconds: timeoutMilliseconds,
            allowPartialHF: allowPartialHFDecode,
            nowNanos: nowNanos
        )
    }

    /// Ingests either a `.frameFragment` (`kind == 3`) or `.fecParity` (`kind == 8`) datagram.
    ///
    /// Returns a completed (or salvaged partial-HF) `SPPWAssembledFrame` as soon as one is ready.
    public mutating func ingest(
        datagram: Data,
        header: SPPWDatagramHeader,
        timeoutMilliseconds: Int = 14,
        allowPartialHF: Bool = true,
        allowPartialHFDecode: Bool? = nil,
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> SPPWAssembledFrame? {
        let partialHFEnabled = allowPartialHFDecode ?? allowPartialHF
        guard datagram.count >= SPPWDatagramHeader.byteCount else {
            malformedDatagrams += 1
            return nil
        }

        // Drop fragments belonging to frames older than or equal to the last completed frame.
        if hasCompletedFrame && isFrameOlderOrEqual(header.frameID, than: lastCompletedFrameID) {
            return nil
        }

        let expectedFragments = Int(header.fragmentCount)
        let expectedBytes = Int(header.frameByteCount)
        guard expectedFragments > 0,
              expectedFragments <= 16_384,
              expectedBytes > 0,
              expectedBytes <= 64 * 1024 * 1024 else {
            malformedDatagrams += 1
            return nil
        }

        if header.width > 0 && header.height > 0 {
            lastFrameWidth = Int(header.width)
            lastFrameHeight = Int(header.height)
        }

        if header.frameID > newestFrameID || !hasCompletedFrame {
            newestFrameID = max(newestFrameID, header.frameID)
        }

        var partial: PartialFrame
        if let existing = partials.removeValue(forKey: header.frameID) {
            partial = existing
        } else {
            partial = PartialFrame(
                streamID: header.streamID,
                frameID: header.frameID,
                width: Int(header.width),
                height: Int(header.height),
                expectedFragments: expectedFragments,
                expectedBytes: expectedBytes,
                senderTimestampNanoseconds: header.senderTimestampNanoseconds,
                firstArrivalNanoseconds: nowNanos
            )
        }

        guard partial.expectedFragments == expectedFragments,
              partial.expectedBytes == expectedBytes else {
            droppedFrames += 1
            return nil
        }

        let isLLCritical = (header.flags & SPPWFragmentFlags.llCritical) != 0

        if header.kind == .frameFragment {
            let index = Int(header.fragmentIndex)
            guard index < expectedFragments else {
                partials[header.frameID] = partial
                return nil
            }

            if isLLCritical {
                partial.llCriticalMask[index] = true
                if index > partial.highestLLFragmentIndex {
                    partial.highestLLFragmentIndex = index
                }
            }

            if partial.fragments[index] == nil {
                let fragmentPayload = Data(datagram[SPPWDatagramHeader.byteCount..<datagram.count])
                partial.fragments[index] = fragmentPayload
                partial.receivedFragmentCount += 1
                partial.receivedBytes += fragmentPayload.count
                if index == 0 || fragmentPayload.count > partial.shardPayloadSize {
                    partial.shardPayloadSize = max(partial.shardPayloadSize, fragmentPayload.count)
                }
            }
        } else if header.kind == .fecParity {
            let fecPayload = Data(datagram[SPPWDatagramHeader.byteCount..<datagram.count])
            guard let blockHeader = SPPWFECBlockHeader(parsing: fecPayload) else {
                malformedDatagrams += 1
                partials[header.frameID] = partial
                return nil
            }
            let parityIndex = Int(header.fragmentIndex)
            let blockStart = Int(blockHeader.blockStartFragment)
            let blockDataCount = Int(blockHeader.blockDataCount)
            let blockParityCount = Int(blockHeader.blockParityCount)
            let shardSize = Int(blockHeader.shardPayloadSize)

            guard parityIndex < blockParityCount,
                  blockStart + blockDataCount <= expectedFragments,
                  fecPayload.count >= SPPWFECBlockHeader.byteCount + shardSize else {
                malformedDatagrams += 1
                partials[header.frameID] = partial
                return nil
            }

            let shardStart = fecPayload.startIndex + SPPWFECBlockHeader.byteCount
            let parityShard = Data(fecPayload[shardStart..<(shardStart + shardSize)])

            partial.shardPayloadSize = max(partial.shardPayloadSize, shardSize)
            if isLLCritical {
                let llLast = blockStart + blockDataCount - 1
                if llLast > partial.highestLLFragmentIndex {
                    partial.highestLLFragmentIndex = llLast
                }
                for idx in blockStart..<(blockStart + blockDataCount) {
                    partial.llCriticalMask[idx] = true
                }
            }

            var blockState = partial.fecBlocks[blockHeader.blockStartFragment]
                ?? FECBlockState(header: blockHeader, isLLBlock: isLLCritical)
            if parityIndex < blockState.parityShards.count,
               blockState.parityShards[parityIndex] == nil {
                blockState.parityShards[parityIndex] = parityShard
                blockState.receivedParityCount += 1
            }
            partial.fecBlocks[blockHeader.blockStartFragment] = blockState
        } else {
            partials[header.frameID] = partial
            return nil
        }

        // Only attempt Reed-Solomon GF(2^8) erasure recovery when a parity packet arrived
        // or an unreconstructed FEC block already holds parity shards while data is still missing.
        if header.kind == .fecParity && partial.receivedFragmentCount < expectedFragments {
            attemptFECRecovery(on: &partial)
        } else if !partial.fecBlocks.isEmpty
                    && partial.receivedFragmentCount < expectedFragments
                    && partial.fecBlocks.values.contains(where: { !$0.reconstructed && $0.receivedParityCount > 0 }) {
            attemptFECRecovery(on: &partial)
        }

        // Check if the frame is now 100% complete.
        if partial.receivedFragmentCount == expectedFragments {
            if !partials.isEmpty {
                _ = evictSupersededFrames(
                    newerThan: header.frameID,
                    nowNanos: nowNanos,
                    timeoutNanoseconds: UInt64(max(timeoutMilliseconds, 2)) * 1_000_000,
                    allowPartialHF: partialHFEnabled
                )
            }
            return finalizeCompleteFrame(partial)
        }

        partials[header.frameID] = partial

        // Fast path: if this is the only partial frame in flight, no older frame can be superseded.
        guard partials.count > 1 else {
            return nil
        }

        // When a newer frame's fragments arrive, inspect older incomplete frames:
        // - If an older frame's LL subband is missing and unrecoverable -> immediately drop it ("scartare LL").
        // - If an older frame's LL subband is 100% intact and only trailing HF packets are missing -> salvage it!
        let timeoutNanos = UInt64(max(timeoutMilliseconds, 2)) * 1_000_000
        if let salvagedOlderFrame = evictSupersededFrames(
            newerThan: header.frameID,
            nowNanos: nowNanos,
            timeoutNanoseconds: timeoutNanos,
            allowPartialHF: partialHFEnabled
        ) {
            return salvagedOlderFrame
        }

        return nil
    }

    /// Periodic timeout check (can be called when an expected frame deadline expires).
    /// Salvages any timed-out frame whose LL subband is 100% complete (`isPartialHF = true`),
    /// or discards it as an LL-drop if LL is incomplete.
    public mutating func flushTimedOutFrames(
        timeoutMilliseconds: Int,
        allowPartialHF: Bool = true
    ) -> SPPWAssembledFrame? {
        guard !partials.isEmpty else { return nil }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = UInt64(max(timeoutMilliseconds, 2)) * 1_000_000
        let sortedIDs = partials.keys.sorted()

        for id in sortedIDs {
            guard var partial = partials[id] else { continue }
            let ageNanos = nowNanos >= partial.firstArrivalNanoseconds
                ? (nowNanos - partial.firstArrivalNanoseconds)
                : 0
            guard ageNanos >= timeoutNanos else { continue }

            attemptFECRecovery(on: &partial)
            partials.removeValue(forKey: id)

            if partial.receivedFragmentCount == partial.expectedFragments {
                return finalizeCompleteFrame(partial)
            }
            if allowPartialHF, partial.hasCompleteLL, let salvaged = buildValidPartialHFFrame(partial) {
                return salvaged
            }
            droppedFrames += 1
            if !partial.hasCompleteLL {
                llDroppedFrames += 1
            }
        }
        return nil
    }

    /// Alias used by `ReceiverModel` / `IOSReceiverModel` maintenance timers.
    public mutating func flushReadyFrame(
        timeoutMilliseconds: Int,
        allowPartialHFDecode: Bool = true
    ) -> SPPWAssembledFrame? {
        flushTimedOutFrames(timeoutMilliseconds: timeoutMilliseconds, allowPartialHF: allowPartialHFDecode)
    }

    public mutating func reset() {
        partials.removeAll()
        newestFrameID = 0
        lastCompletedFrameID = 0
        hasCompletedFrame = false
    }

    // MARK: - Internal Reed-Solomon Recovery & LL-Drop / Partial-HF Salvage

    private mutating func attemptFECRecovery(on partial: inout PartialFrame) {
        guard !partial.fecBlocks.isEmpty else { return }

        for (blockStartKey, var blockState) in partial.fecBlocks {
            if blockState.reconstructed || blockState.receivedParityCount == 0 {
                continue
            }

            let blockStart = Int(blockState.header.blockStartFragment)
            let blockDataCount = Int(blockState.header.blockDataCount)
            let shardSize = Int(blockState.header.shardPayloadSize)
            guard blockStart + blockDataCount <= partial.expectedFragments else { continue }

            var missingCount = 0
            for idx in blockStart..<(blockStart + blockDataCount) {
                if partial.fragments[idx] == nil {
                    missingCount += 1
                }
            }

            if missingCount == 0 {
                blockState.reconstructed = true
                partial.fecBlocks[blockStartKey] = blockState
                continue
            }

            guard blockState.receivedParityCount >= missingCount else {
                continue
            }

            var blockDataShards = Array(partial.fragments[blockStart..<(blockStart + blockDataCount)])
            let recovered = SPPWReedSolomonGF256.reconstructMissingDataShards(
                dataShards: &blockDataShards,
                parityShards: blockState.parityShards,
                shardSize: shardSize
            )

            if recovered > 0 {
                for localIdx in 0..<blockDataCount {
                    let globalIdx = blockStart + localIdx
                    if partial.fragments[globalIdx] == nil,
                       var recoveredShard = blockDataShards[localIdx] {
                        if globalIdx == partial.expectedFragments - 1 {
                            let priorBytes = globalIdx * shardSize
                            let exactLastLength = max(0, min(shardSize, partial.expectedBytes - priorBytes))
                            if exactLastLength > 0 && exactLastLength < recoveredShard.count {
                                recoveredShard = Data(recoveredShard.prefix(exactLastLength))
                            }
                        }
                        partial.fragments[globalIdx] = recoveredShard
                        partial.receivedFragmentCount += 1
                        partial.receivedBytes += recoveredShard.count
                    }
                }
                partial.fecRecoveredCount += recovered
                fecRecoveredFragments += recovered
                blockState.reconstructed = true
                partial.fecBlocks[blockStartKey] = blockState
            }
        }
    }

    private mutating func evictSupersededFrames(
        newerThan currentFrameID: UInt32,
        nowNanos: UInt64,
        timeoutNanoseconds: UInt64,
        allowPartialHF: Bool
    ) -> SPPWAssembledFrame? {
        var salvagedCandidate: SPPWAssembledFrame?
        let keys = partials.keys.sorted()

        for id in keys where id < currentFrameID {
            guard var partial = partials[id] else { continue }
            if !partial.fecBlocks.isEmpty {
                attemptFECRecovery(on: &partial)
            }

            if partial.receivedFragmentCount == partial.expectedFragments {
                partials.removeValue(forKey: id)
                salvagedCandidate = finalizeCompleteFrame(partial)
                continue
            }

            let frameLag = currentFrameID &- id
            let ageNanos = nowNanos >= partial.firstArrivalNanoseconds
                ? (nowNanos - partial.firstArrivalNanoseconds)
                : 0

            // 1. Immediate LL-Drop ("scartare LL quando necessario")
            if !partial.hasCompleteLL {
                if frameLag >= 1 || ageNanos >= (timeoutNanoseconds / 2) || partials.count > maxInFlightFrames {
                    partials.removeValue(forKey: id)
                    droppedFrames += 1
                    llDroppedFrames += 1
                }
                continue
            }

            // 2. Partial-HF Salvage when coarse LL subband is 100% intact
            if frameLag >= 1 || ageNanos >= timeoutNanoseconds || partials.count > maxInFlightFrames {
                partials.removeValue(forKey: id)
                if allowPartialHF, let salvaged = buildValidPartialHFFrame(partial) {
                    salvagedCandidate = salvaged
                } else {
                    droppedFrames += 1
                }
            }
        }

        return salvagedCandidate
    }

    private mutating func finalizeCompleteFrame(_ partial: PartialFrame) -> SPPWAssembledFrame? {
        var assembled = Data(capacity: partial.expectedBytes)
        for fragment in partial.fragments {
            guard let fragment else {
                droppedFrames += 1
                return nil
            }
            assembled.append(fragment)
        }
        guard assembled.count == partial.expectedBytes else {
            droppedFrames += 1
            return nil
        }

        completedFrames += 1
        if partial.fecRecoveredCount > 0 {
            fecRecoveredFrames += 1
        }
        lastCompletedFrameID = partial.frameID
        hasCompletedFrame = true

        return SPPWAssembledFrame(
            streamID: partial.streamID,
            frameID: partial.frameID,
            width: partial.width,
            height: partial.height,
            bitstream: assembled,
            senderTimestampNanoseconds: partial.senderTimestampNanoseconds,
            receivedAt: partial.firstArrival,
            receivedAtNanoseconds: partial.firstArrivalNanoseconds,
            fecRecoveredFragments: partial.fecRecoveredCount,
            isPartialHF: false
        )
    }

    private mutating func buildValidPartialHFFrame(_ partial: PartialFrame) -> SPPWAssembledFrame? {
        var contiguousPrefix = Data(capacity: partial.receivedBytes)

        for fragment in partial.fragments {
            guard let fragment else {
                break
            }
            contiguousPrefix.append(fragment)
        }

        let validBytes = SPPWPyrowaveSubbandInspector.validBlockAlignedPrefixLength(
            bitstream: contiguousPrefix,
            contiguousByteLength: contiguousPrefix.count
        )
        guard validBytes >= 16 else {
            droppedFrames += 1
            return nil
        }

        let cleanBitstream = validBytes == contiguousPrefix.count
            ? contiguousPrefix
            : Data(contiguousPrefix.prefix(validBytes))

        completedFrames += 1
        partialHFDecodedFrames += 1
        if partial.fecRecoveredCount > 0 {
            fecRecoveredFrames += 1
        }
        lastCompletedFrameID = partial.frameID
        hasCompletedFrame = true

        return SPPWAssembledFrame(
            streamID: partial.streamID,
            frameID: partial.frameID,
            width: partial.width,
            height: partial.height,
            bitstream: cleanBitstream,
            senderTimestampNanoseconds: partial.senderTimestampNanoseconds,
            receivedAt: partial.firstArrival,
            receivedAtNanoseconds: partial.firstArrivalNanoseconds,
            fecRecoveredFragments: partial.fecRecoveredCount,
            isPartialHF: true
        )
    }

    @inline(__always)
    private func isFrameOlderOrEqual(_ a: UInt32, than b: UInt32) -> Bool {
        a <= b
    }
}
