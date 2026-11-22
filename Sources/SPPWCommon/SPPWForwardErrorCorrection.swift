import Foundation

// MARK: - SPPW/1 Fragment Flags & FEC Block Header

/// Wire flags embedded in the 16-bit `flags` field of `SPPWDatagramHeader` / `WireHeader`
/// for `.frameFragment` (`kind == 3`) and `.fecParity` (`kind == 8`) datagrams.
public enum SPPWFragmentFlags {
    /// Marks a fragment belonging to the coarse LL (level 4, band 0) wavelet subband.
    /// If ANY LL fragment is unrecoverable after Reed-Solomon erasure decoding when a
    /// newer frame arrives, the receiver immediately discards the stale frame ("scartare LL").
    /// Conversely, if ALL LL fragments are intact and only trailing high-frequency (HF)
    /// detail fragments are missing, the receiver can still salvage and decode the frame on GPU.
    public static let llCritical: UInt16 = 1 << 1

    /// Indicates that this fragment belongs to a frame protected by Reed-Solomon FEC parity packets.
    public static let fecProtected: UInt16 = 1 << 2
}

/// 8-byte header prepended to the payload of every `.fecParity` (`kind == 8`) datagram.
///
/// In a `.fecParity` datagram:
/// - `WireHeader.fragmentIndex` carries `parityIndex` ($0 \dots M-1$ within this FEC block).
/// - `WireHeader.fragmentCount` carries the total data fragment count of the frame.
/// - The first 8 bytes of payload encode `SPPWFECBlockHeader`, followed immediately by
///   `shardPayloadSize` bytes of GF($2^8$) Reed-Solomon parity data.
public struct SPPWFECBlockHeader: Sendable, Equatable {
    public static let byteCount = 8

    /// Index of the first data fragment covered by this FEC block.
    public let blockStartFragment: UInt16
    /// Number of data fragments ($K$) in this FEC block ($1 \le K \le 64$).
    public let blockDataCount: UInt16
    /// Number of parity shards ($M$) generated for this FEC block ($1 \le M \le 64$).
    public let blockParityCount: UInt16
    /// Byte length of each shard in this FEC block (typically equal to `payloadLimit`).
    /// Shorter final fragments are zero-padded up to `shardPayloadSize` during GF($2^8$) math.
    public let shardPayloadSize: UInt16

    public init(
        blockStartFragment: UInt16,
        blockDataCount: UInt16,
        blockParityCount: UInt16,
        shardPayloadSize: UInt16
    ) {
        self.blockStartFragment = blockStartFragment
        self.blockDataCount = blockDataCount
        self.blockParityCount = blockParityCount
        self.shardPayloadSize = shardPayloadSize
    }

    public init?(parsing payload: Data) {
        guard payload.count >= Self.byteCount else { return nil }
        let s = payload.startIndex
        self.blockStartFragment = (UInt16(payload[s]) << 8) | UInt16(payload[s + 1])
        self.blockDataCount = (UInt16(payload[s + 2]) << 8) | UInt16(payload[s + 3])
        self.blockParityCount = (UInt16(payload[s + 4]) << 8) | UInt16(payload[s + 5])
        self.shardPayloadSize = (UInt16(payload[s + 6]) << 8) | UInt16(payload[s + 7])
        guard blockDataCount > 0, blockParityCount > 0, shardPayloadSize > 0 else { return nil }
    }

    public func encode(into data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: blockStartFragment >> 8))
        data.append(UInt8(truncatingIfNeeded: blockStartFragment))
        data.append(UInt8(truncatingIfNeeded: blockDataCount >> 8))
        data.append(UInt8(truncatingIfNeeded: blockDataCount))
        data.append(UInt8(truncatingIfNeeded: blockParityCount >> 8))
        data.append(UInt8(truncatingIfNeeded: blockParityCount))
        data.append(UInt8(truncatingIfNeeded: shardPayloadSize >> 8))
        data.append(UInt8(truncatingIfNeeded: shardPayloadSize))
    }
}

// MARK: - PyroWave Bitstream LL Subband Inspector

/// Result of scanning a PyroWave bitstream for the boundary between the coarse
/// low-frequency LL subband (`level == 4, band == 0`) and high-frequency detail subbands.
public struct SPPWPyrowaveSubbandBoundary: Sendable, Equatable {
    /// Decoded frame width from the PyroWave sequence header.
    public let width: Int
    /// Decoded frame height from the PyroWave sequence header.
    public let height: Int
    /// Byte offset where the coarse LL subband (`level == 4, band == 0` across Y/Cb/Cr) ends.
    /// Because the upstream PyroWave encoder serializes subbands in descending decomposition
    /// order (`level = 4, band = 0` first), all LL blocks occupy a contiguous prefix of the
    /// frame bitstream `[0 ..< llByteEnd]`.
    public let llByteEnd: Int
    /// Number of PyroWave 32x32 wavelet blocks belonging to the LL subband.
    public let llBlockCount: Int
    /// Total number of valid 4-byte-aligned wavelet blocks parsed in the bitstream.
    public let totalBlockCount: Int
    /// Byte offset of the end of the last valid complete wavelet block in the bitstream.
    public let totalByteEnd: Int
    /// Whether the bitstream opened with a PyroWave sequence header (`bit 31 == 1`).
    public let hasSequenceHeader: Bool

    public init(
        width: Int = 0,
        height: Int = 0,
        llByteEnd: Int,
        llBlockCount: Int,
        totalBlockCount: Int = 0,
        totalByteEnd: Int = 0,
        hasSequenceHeader: Bool
    ) {
        self.width = width
        self.height = height
        self.llByteEnd = llByteEnd
        self.llBlockCount = llBlockCount
        self.totalBlockCount = totalBlockCount
        self.totalByteEnd = totalByteEnd
        self.hasSequenceHeader = hasSequenceHeader
    }

    /// Number of UDP fragments (of size `payloadLimit`) required to cover the entire LL subband.
    public func llFragmentCount(payloadLimit: Int, totalFragments: Int) -> Int {
        guard payloadLimit > 0, totalFragments > 0 else { return 0 }
        let count = (llByteEnd + payloadLimit - 1) / payloadLimit
        return min(max(count, 1), totalFragments)
    }
}

/// Result of inspecting a contiguous byte prefix `[0 ..< contiguousByteLength]` of a
/// PyroWave bitstream for block alignment and coarse LL subband completeness.
public struct SPPWPyrowavePrefixInspection: Sendable, Equatable {
    public let validByteLength: Int
    public let validBlockCount: Int
    public let expectedTotalBlocks: Int
    public let maxBlockIndex: Int
    public let hasSequenceHeader: Bool
    /// `true` when `[0 ..< validByteLength]` is guaranteed to contain all non-zero
    /// coarsest LL subband blocks (`level == 4, band == 0` across Y, Cb, Cr) emitted
    /// by the encoder, even if some all-zero LL blocks (e.g. solid chroma) were omitted.
    public let hasCompleteLLSubband: Bool

    public init(
        validByteLength: Int,
        validBlockCount: Int,
        expectedTotalBlocks: Int,
        maxBlockIndex: Int,
        hasSequenceHeader: Bool,
        hasCompleteLLSubband: Bool
    ) {
        self.validByteLength = validByteLength
        self.validBlockCount = validBlockCount
        self.expectedTotalBlocks = expectedTotalBlocks
        self.maxBlockIndex = maxBlockIndex
        self.hasSequenceHeader = hasSequenceHeader
        self.hasCompleteLLSubband = hasCompleteLLSubband
    }
}

/// Zero-allocation parser for upstream PyroWave bitstreams (`Vendor/pyrowave-metal/src/pyrowave_bitstream.cpp`).
///
/// Upstream PyroWave packet layout:
/// - **Optional 8-byte `BitstreamSequenceHeader`** (present when `word0 & 0x8000_0000 != 0` and `(word1 >> 24) & 0x3 == 0`):
///   - `word0`: `[13:0] = width_minus_1`, `[27:14] = height_minus_1`, `[30:28] = sequence`, `[31] = extended (1)`
///   - `word1`: `[23:0] = total_blocks`, `[25:24] = code (0)`, `[26] = chroma_resolution`, `[31:27] = videoSignal`
/// - **Sequence of 4-byte-aligned `BitstreamHeader` blocks**:
///   - `word0`: `[15:0] = ballot`, `[27:16] = payload_words` (total 32-bit words including the 2-word header),
///              `[30:28] = sequence`, `[31] = extended (0)`
///   - `word1`: `[7:0] = quant_code`, `[31:8] = block_index`
public enum SPPWPyrowaveSubbandInspector {
    public static let decompositionLevels = 5
    public static let alignment = 1 << decompositionLevels // 32
    public static let minimumImageSize = 4 << decompositionLevels // 128
    public static let componentCount = 3
    public static let coefficientBlockSize = 32

    /// Returns the number of 32x32 blocks belonging to the coarsest LL subband (`level == 4, band == 0`)
    /// across all 3 planes (`Y`, `Cb`, `Cr`). In PyroWave's block layout (`BlockLayout::init`),
    /// `level == DecompositionLevels - 1` (`4`) is visited first, and for `level == 4` `band` runs `0..<4`
    /// inside each component `0..<3`, or in `PyrowaveBlockLayout` `band` runs `0..<4` inside each component.
    /// Let's compute the exact set or range of `block_index` values for `(level == 4, band == 0)`.
    private static func isLLSubbandBlock(
        blockIndex: Int,
        blocksPerBandAtCoarsestLevel: Int
    ) -> Bool {
        guard blocksPerBandAtCoarsestLevel > 0 else { return blockIndex == 0 }
        // At level = 4 (the first level in BlockLayout), each of the 3 components has 4 bands (0, 1, 2, 3),
        // each containing `blocksPerBandAtCoarsestLevel` 32x32 blocks.
        let totalCoarsestLevelBlocks = componentCount * 4 * blocksPerBandAtCoarsestLevel
        guard blockIndex >= 0 && blockIndex < totalCoarsestLevelBlocks else { return false }
        let offsetInComponent = blockIndex % (4 * blocksPerBandAtCoarsestLevel)
        return offsetInComponent < blocksPerBandAtCoarsestLevel
    }

    private static func coarsestBandBlockCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        let alignedW = max((width + alignment - 1) & ~(alignment - 1), minimumImageSize)
        let alignedH = max((height + alignment - 1) & ~(alignment - 1), minimumImageSize)
        let coarsestLevel = decompositionLevels - 1 // 4
        let subbandW = max(1, (alignedW / 2) >> coarsestLevel)
        let subbandH = max(1, (alignedH / 2) >> coarsestLevel)
        let blocksX = (subbandW + coefficientBlockSize - 1) / coefficientBlockSize
        let blocksY = (subbandH + coefficientBlockSize - 1) / coefficientBlockSize
        return max(1, blocksX * blocksY)
    }

    /// Scans a PyroWave bitstream to find the exact byte boundary of the coarse LL subband
    /// (`level == 4, band == 0`) as well as the total valid block count and byte end.
    public static func inspect(_ bitstream: Data) -> SPPWPyrowaveSubbandBoundary? {
        let totalBytes = bitstream.count
        guard totalBytes >= 8 else { return nil }

        return bitstream.withUnsafeBytes { rawBuffer -> SPPWPyrowaveSubbandBoundary? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            @inline(__always)
            func readU32LE(_ byteOffset: Int) -> UInt32 {
                let b0 = UInt32(base[byteOffset])
                let b1 = UInt32(base[byteOffset + 1]) << 8
                let b2 = UInt32(base[byteOffset + 2]) << 16
                let b3 = UInt32(base[byteOffset + 3]) << 24
                return b0 | b1 | b2 | b3
            }

            var offset = 0
            let firstWord = readU32LE(0)
            var hasSeqHeader = false
            var width = 0
            var height = 0

            if (firstWord & 0x8000_0000) != 0 {
                let secondWord = readU32LE(4)
                let code = (secondWord >> 24) & 0x3
                guard code == 0 else { return nil }
                hasSeqHeader = true
                width = Int(firstWord & 0x3FFF) + 1
                height = Int((firstWord >> 14) & 0x3FFF) + 1
                offset = 8
            }

            let blocksPerCoarsestBand = coarsestBandBlockCount(width: width, height: height)
            let maxCoarsestBlockIndex = componentCount * 4 * blocksPerCoarsestBand

            var llByteEnd = offset
            var llBlockCount = 0
            var totalBlockCount = 0
            var totalByteEnd = offset

            while offset + 8 <= totalBytes {
                let word0 = readU32LE(offset)
                // Bit 31 (`extended`) must be 0 for a valid BitstreamHeader block.
                if (word0 & 0x8000_0000) != 0 {
                    break
                }
                let word1 = readU32LE(offset + 4)
                let payloadWords = Int((word0 >> 16) & 0x0FFF)
                let blockByteCount = payloadWords * 4
                guard payloadWords >= 2, offset + blockByteCount <= totalBytes else {
                    break
                }

                let blockIndex = Int(word1 >> 8)

                offset += blockByteCount
                totalBlockCount += 1
                totalByteEnd = offset

                if isLLSubbandBlock(
                    blockIndex: blockIndex,
                    blocksPerBandAtCoarsestLevel: blocksPerCoarsestBand
                ) {
                    llBlockCount += 1
                    llByteEnd = offset
                } else if blockIndex < maxCoarsestBlockIndex && llBlockCount > 0 {
                    // Because Y, Cb, Cr coarsest subbands (level 4) are interleaved by component
                    // (Y band 0..3, Cb band 0..3, Cr band 0..3), `llByteEnd` must cover up through
                    // the last LL block (`Cr` band 0).
                }
            }

            guard totalBlockCount > 0 else { return nil }
            if llBlockCount == 0 {
                // Fallback if no LL blocks were non-empty: protect at least the first 10% of the frame.
                llByteEnd = min(totalByteEnd, max(offset > 8 ? 16 : 8, totalByteEnd / 10))
            }

            return SPPWPyrowaveSubbandBoundary(
                width: width,
                height: height,
                llByteEnd: llByteEnd,
                llBlockCount: llBlockCount,
                totalBlockCount: totalBlockCount,
                totalByteEnd: totalByteEnd,
                hasSequenceHeader: hasSeqHeader
            )
        }
    }

    /// Alias for `inspect(_:)` used by packetizer callers.
    public static func inspectLLBoundary(bitstream: Data) -> SPPWPyrowaveSubbandBoundary? {
        inspect(bitstream)
    }

    /// Scans a contiguous byte prefix `[0 ..< contiguousByteLength]` to compute both the
    /// longest valid 4-byte-aligned block prefix and whether all emitted coarse LL blocks
    /// (`level == 4, band == 0` across Y, Cb, Cr) have been completely received.
    public static func inspectContiguousPrefix(
        bitstream: Data,
        contiguousByteLength: Int
    ) -> SPPWPyrowavePrefixInspection {
        let limit = min(bitstream.count, contiguousByteLength)
        guard limit >= 8 else {
            return SPPWPyrowavePrefixInspection(
                validByteLength: 0,
                validBlockCount: 0,
                expectedTotalBlocks: 0,
                maxBlockIndex: -1,
                hasSequenceHeader: false,
                hasCompleteLLSubband: false
            )
        }

        return bitstream.withUnsafeBytes { rawBuffer -> SPPWPyrowavePrefixInspection in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return SPPWPyrowavePrefixInspection(
                    validByteLength: 0,
                    validBlockCount: 0,
                    expectedTotalBlocks: 0,
                    maxBlockIndex: -1,
                    hasSequenceHeader: false,
                    hasCompleteLLSubband: false
                )
            }

            @inline(__always)
            func readU32LE(_ byteOffset: Int) -> UInt32 {
                let b0 = UInt32(base[byteOffset])
                let b1 = UInt32(base[byteOffset + 1]) << 8
                let b2 = UInt32(base[byteOffset + 2]) << 16
                let b3 = UInt32(base[byteOffset + 3]) << 24
                return b0 | b1 | b2 | b3
            }

            var offset = 0
            var hasSeqHeader = false
            var width = 0
            var height = 0
            var headerSequence: UInt32 = 0
            var expectedTotalBlocks = 0

            let firstWord = readU32LE(0)
            if (firstWord & 0x8000_0000) != 0 {
                let secondWord = readU32LE(4)
                let code = (secondWord >> 24) & 0x3
                guard code == 0 else {
                    return SPPWPyrowavePrefixInspection(
                        validByteLength: 0,
                        validBlockCount: 0,
                        expectedTotalBlocks: 0,
                        maxBlockIndex: -1,
                        hasSequenceHeader: false,
                        hasCompleteLLSubband: false
                    )
                }
                hasSeqHeader = true
                width = Int(firstWord & 0x3FFF) + 1
                height = Int((firstWord >> 14) & 0x3FFF) + 1
                headerSequence = (firstWord >> 28) & 0x7
                expectedTotalBlocks = Int(secondWord & 0x00FF_FFFF)
                offset = 8
            }

            var validBlocks = 0
            var maxBlockIndex = -1
            while offset + 8 <= limit {
                let word0 = readU32LE(offset)
                if (word0 & 0x8000_0000) != 0 {
                    break
                }
                if hasSeqHeader && ((word0 >> 28) & 0x7) != headerSequence {
                    break
                }
                let word1 = readU32LE(offset + 4)
                let payloadWords = Int((word0 >> 16) & 0x0FFF)
                let blockByteCount = payloadWords * 4
                guard payloadWords >= 2, offset + blockByteCount <= limit else {
                    break
                }
                let blockIndex = Int(word1 >> 8)
                if blockIndex > maxBlockIndex {
                    maxBlockIndex = blockIndex
                }
                offset += blockByteCount
                validBlocks += 1
            }

            let blocksPerCoarsestBand = coarsestBandBlockCount(width: width, height: height)
            // At level 4, Y occupies [0 ..< 4B), Cb occupies [4B ..< 8B), Cr LL occupies [8B ..< 9B),
            // and Cr HF / finer levels start at 9B. Reaching blockIndex >= 9B guarantees all
            // non-empty LL blocks across Y, Cb, Cr have already appeared in ascending order.
            let postLLStartBlockIndex = componentCount * 3 * blocksPerCoarsestBand
            let hasCompleteLL: Bool
            if hasSeqHeader {
                hasCompleteLL = validBlocks >= expectedTotalBlocks || maxBlockIndex >= postLLStartBlockIndex
            } else {
                hasCompleteLL = validBlocks > 0
            }

            let validByteLength = validBlocks > 0 ? offset : 0
            return SPPWPyrowavePrefixInspection(
                validByteLength: validByteLength,
                validBlockCount: validBlocks,
                expectedTotalBlocks: expectedTotalBlocks,
                maxBlockIndex: maxBlockIndex,
                hasSequenceHeader: hasSeqHeader,
                hasCompleteLLSubband: hasCompleteLL
            )
        }
    }

    /// Computes the byte length of the longest valid 4-byte-aligned prefix of complete
    /// PyroWave wavelet blocks within `bitstream[0 ..< contiguousByteLength]`.
    ///
    /// Used when decoding a partial frame whose LL subband is 100% intact (`allowPartialFrame = true`)
    /// so that a truncated trailing HF block at a missing fragment boundary is cleanly stripped
    /// before passing the buffer to `pyrowave_decoder_push_packet`.
    public static func validBlockAlignedPrefixLength(
        bitstream: Data,
        contiguousByteLength: Int
    ) -> Int {
        inspectContiguousPrefix(bitstream: bitstream, contiguousByteLength: contiguousByteLength).validByteLength
    }

    /// Convenience overload checking the longest valid block-aligned prefix across the entire `Data`.
    public static func validPrefixByteLength(of bitstream: Data) -> Int {
        validBlockAlignedPrefixLength(bitstream: bitstream, contiguousByteLength: bitstream.count)
    }
}

// MARK: - Asymmetric LL / HF FEC Planner

/// Describes one FEC block covering a contiguous range of data fragments `[startFragment ..< startFragment + dataCount]`.
public struct SPPWFECBlockPlan: Sendable, Equatable {
    public let startFragment: Int
    public let dataCount: Int
    public let parityCount: Int
    public let isLLGroup: Bool

    public init(startFragment: Int, dataCount: Int, parityCount: Int, isLLGroup: Bool) {
        self.startFragment = startFragment
        self.dataCount = dataCount
        self.parityCount = parityCount
        self.isLLGroup = isLLGroup
    }
}

public enum SPPWFECPlanner {
    /// Maximum data shards per Reed-Solomon block to keep Vandermonde recovery sub-0.2ms on Apple Silicon.
    public static let maxBlockDataFragments = 48

    /// Builds an asymmetric LL/HF FEC block layout for a frame.
    ///
    /// - The coarse LL subband (`0 ..< llFragmentCount`) receives boosted protection
    ///   (`max(fecPercent * 2, 25)%`, minimum 2 parity shards when `fecPercent > 0`),
    ///   because losing LL forces a full frame drop whereas losing HF only softens detail.
    /// - High-frequency subbands (`llFragmentCount ..< totalDataFragments`) are partitioned
    ///   into blocks of up to 48 data fragments protected at `fecPercent`.
    public static func makePlan(
        totalDataFragments: Int,
        llFragmentCount: Int,
        fecPercent: Int
    ) -> [SPPWFECBlockPlan] {
        guard fecPercent > 0, totalDataFragments > 0 else { return [] }
        let clampedFEC = min(max(fecPercent, 1), 100)
        let clampedLL = min(max(llFragmentCount, 1), totalDataFragments)

        var groups: [SPPWFECBlockPlan] = []

        // 1. Protect LL fragments with 2x boosted parity ratio (minimum 25% and at least 2 shards if K >= 2).
        let llParityPercent = min(100, max(clampedFEC * 2, 25))
        var llCursor = 0
        while llCursor < clampedLL {
            let k = min(maxBlockDataFragments, clampedLL - llCursor)
            let rawM = (k * llParityPercent + 99) / 100
            let m = min(maxBlockDataFragments, max(k >= 2 ? 2 : 1, rawM))
            groups.append(SPPWFECBlockPlan(
                startFragment: llCursor,
                dataCount: k,
                parityCount: m,
                isLLGroup: true
            ))
            llCursor += k
        }

        // 2. Protect HF detail fragments in blocks of up to `maxBlockDataFragments`.
        var hfCursor = clampedLL
        while hfCursor < totalDataFragments {
            let k = min(maxBlockDataFragments, totalDataFragments - hfCursor)
            let m = min(maxBlockDataFragments, max(1, (k * clampedFEC + 99) / 100))
            groups.append(SPPWFECBlockPlan(
                startFragment: hfCursor,
                dataCount: k,
                parityCount: m,
                isLLGroup: false
            ))
            hfCursor += k
        }

        return groups
    }
}

// MARK: - GF(2^8) Reed-Solomon Erasure Codec

/// Systematic Vandermonde/Cauchy Reed-Solomon erasure code over $\text{GF}(2^8)$
/// with primitive polynomial $x^8 + x^4 + x^3 + x^2 + 1$ (`0x11D`).
///
/// Supports up to $K + M \le 255$ shards per block and vectorizes shard row-additions
/// 8 bytes at a time on 64-bit Apple Silicon.
public enum SPPWReedSolomonGF256 {
    private static let primitivePoly = 0x11D

    // Lookup tables initialized once at load time.
    private static let tables: (exp: [UInt8], log: [UInt8], mul: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = UInt8(i)
            x <<= 1
            if (x & 0x100) != 0 {
                x ^= primitivePoly
            }
        }
        for i in 255..<512 {
            exp[i] = exp[i - 255]
        }
        // Flat 256x256 multiplication table (64 KB, fits in L1/L2 cache).
        var mul = [UInt8](repeating: 0, count: 256 * 256)
        for a in 1..<256 {
            let logA = Int(log[a])
            let rowOffset = a << 8
            for b in 1..<256 {
                mul[rowOffset | b] = exp[logA + Int(log[b])]
            }
        }
        return (exp, log, mul)
    }()

    @inline(__always)
    public static func gfAdd(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a ^ b
    }

    @inline(__always)
    public static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return tables.mul[(Int(a) << 8) | Int(b)]
    }

    @inline(__always)
    public static func gfDiv(_ a: UInt8, _ b: UInt8) -> UInt8 {
        precondition(b != 0, "Division by zero in GF(2^8)")
        if a == 0 { return 0 }
        let diff = Int(tables.log[Int(a)]) - Int(tables.log[Int(b)])
        return tables.exp[diff >= 0 ? diff : (diff + 255)]
    }

    @inline(__always)
    public static func gfInv(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "Inverse of zero in GF(2^8)")
        return tables.exp[255 - Int(tables.log[Int(a)])]
    }

    /// Cauchy parity matrix coefficient $C_{p, d} = \frac{1}{x_p \oplus y_d}$ where
    /// $x_p = p$ ($0 \le p < M$) and $y_d = M + d$ ($0 \le d < K$).
    /// Every square submatrix of a Cauchy matrix over $\text{GF}(2^8)$ is guaranteed invertible!
    @inline(__always)
    public static func cauchyCoefficient(parityRow p: Int, dataCol d: Int, parityCount m: Int) -> UInt8 {
        let xp = UInt8(truncatingIfNeeded: p)
        let yd = UInt8(truncatingIfNeeded: m + d)
        return gfInv(xp ^ yd)
    }

    /// Accumulates `dst[i] ^= coeff * src[i]` across `byteCount` bytes using the flat 256-byte row
    /// of the precomputed $\text{GF}(2^8)$ multiplication table.
    @inline(__always)
    private static func mulAccumulateRow(
        dst: UnsafeMutablePointer<UInt8>,
        src: UnsafePointer<UInt8>,
        coeff: UInt8,
        byteCount: Int
    ) {
        if coeff == 0 || byteCount <= 0 { return }
        if coeff == 1 {
            var i = 0
            while i + 8 <= byteCount {
                let d64 = UnsafeMutableRawPointer(dst.advanced(by: i)).loadUnaligned(as: UInt64.self)
                let s64 = UnsafeRawPointer(src.advanced(by: i)).loadUnaligned(as: UInt64.self)
                UnsafeMutableRawPointer(dst.advanced(by: i)).storeBytes(of: d64 ^ s64, as: UInt64.self)
                i += 8
            }
            while i < byteCount {
                dst[i] ^= src[i]
                i += 1
            }
            return
        }

        tables.mul.withUnsafeBufferPointer { mulBuf in
            let rowPtr = mulBuf.baseAddress!.advanced(by: Int(coeff) << 8)
            var i = 0
            while i + 4 <= byteCount {
                dst[i] ^= rowPtr[Int(src[i])]
                dst[i + 1] ^= rowPtr[Int(src[i + 1])]
                dst[i + 2] ^= rowPtr[Int(src[i + 2])]
                dst[i + 3] ^= rowPtr[Int(src[i + 3])]
                i += 4
            }
            while i < byteCount {
                dst[i] ^= rowPtr[Int(src[i])]
                i += 1
            }
        }
    }

    /// Scales a row `row[i] = coeff * row[i]` in place.
    @inline(__always)
    private static func scaleRow(
        row: UnsafeMutablePointer<UInt8>,
        coeff: UInt8,
        byteCount: Int
    ) {
        if coeff == 1 || byteCount <= 0 { return }
        if coeff == 0 {
            memset(row, 0, byteCount)
            return
        }
        tables.mul.withUnsafeBufferPointer { mulBuf in
            let rowPtr = mulBuf.baseAddress!.advanced(by: Int(coeff) << 8)
            for i in 0..<byteCount {
                row[i] = rowPtr[Int(row[i])]
            }
        }
    }

    // MARK: - Encoding

    /// Encodes `parityCount` ($M$) Reed-Solomon parity shards of length `shardSize` directly from
    /// a contiguous frame `bitstream` slice starting at `blockStartOffset`.
    public static func encodeParity(
        bitstream: Data,
        blockStartOffset: Int,
        dataCount: Int,
        parityCount: Int,
        shardSize: Int
    ) -> [Data] {
        guard dataCount > 0,
              parityCount > 0,
              shardSize > 0,
              dataCount + parityCount <= 255 else {
            return []
        }

        let totalBytes = bitstream.count
        var parityBuffers = [[UInt8]](
            repeating: [UInt8](repeating: 0, count: shardSize),
            count: parityCount
        )

        bitstream.withUnsafeBytes { rawBitstream in
            guard let basePtr = rawBitstream.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for d in 0..<dataCount {
                let fragStart = blockStartOffset + d * shardSize
                guard fragStart < totalBytes else { break }
                let fragLen = min(shardSize, totalBytes - fragStart)
                let srcPtr = basePtr.advanced(by: fragStart)

                for p in 0..<parityCount {
                    let c = cauchyCoefficient(parityRow: p, dataCol: d, parityCount: parityCount)
                    parityBuffers[p].withUnsafeMutableBufferPointer { dstBuf in
                        mulAccumulateRow(
                            dst: dstBuf.baseAddress!,
                            src: srcPtr,
                            coeff: c,
                            byteCount: fragLen
                        )
                    }
                }
            }
        }

        return parityBuffers.map { Data($0) }
    }

    /// Convenience encoder taking an explicit array of `dataShards` (used in unit tests).
    public static func encodeParity(
        dataShards: [Data],
        parityCount: Int,
        shardSize: Int
    ) -> [Data] {
        let k = dataShards.count
        guard k > 0, parityCount > 0, shardSize > 0, k + parityCount <= 255 else { return [] }

        var parityBuffers = [[UInt8]](
            repeating: [UInt8](repeating: 0, count: shardSize),
            count: parityCount
        )

        for (d, shard) in dataShards.enumerated() {
            let fragLen = min(shardSize, shard.count)
            guard fragLen > 0 else { continue }
            shard.withUnsafeBytes { rawShard in
                guard let srcPtr = rawShard.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for p in 0..<parityCount {
                    let c = cauchyCoefficient(parityRow: p, dataCol: d, parityCount: parityCount)
                    parityBuffers[p].withUnsafeMutableBufferPointer { dstBuf in
                        mulAccumulateRow(
                            dst: dstBuf.baseAddress!,
                            src: srcPtr,
                            coeff: c,
                            byteCount: fragLen
                        )
                    }
                }
            }
        }

        return parityBuffers.map { Data($0) }
    }

    /// Overload matching `(dataShards:parityShardCount:shardLength:)`.
    public static func encodeParity(
        dataShards: [Data],
        parityShardCount: Int,
        shardLength: Int
    ) -> [Data] {
        encodeParity(dataShards: dataShards, parityCount: parityShardCount, shardSize: shardLength)
    }

    // MARK: - Erasure Decoding (Gaussian Elimination on Cauchy Submatrix)

    /// Reconstructs missing data shards in place inside `dataShards` ($K$ elements)
    /// using the available `parityShards` ($M$ elements).
    ///
    /// - Returns: The number of erased data shards successfully reconstructed ($0$ if none or insufficient parity).
    @discardableResult
    public static func reconstructMissingDataShards(
        dataShards: inout [Data?],
        parityShards: [Data?],
        shardSize: Int
    ) -> Int {
        let k = dataShards.count
        let m = parityShards.count
        guard k > 0, m > 0, shardSize > 0, k + m <= 255 else { return 0 }

        var missingDataIndices: [Int] = []
        var presentDataIndices: [Int] = []
        missingDataIndices.reserveCapacity(m)
        presentDataIndices.reserveCapacity(k)

        for d in 0..<k {
            if dataShards[d] == nil {
                missingDataIndices.append(d)
            } else {
                presentDataIndices.append(d)
            }
        }

        let r = missingDataIndices.count
        if r == 0 { return 0 }

        var availableParityRows: [Int] = []
        availableParityRows.reserveCapacity(r)
        for p in 0..<m where parityShards[p] != nil {
            availableParityRows.append(p)
            if availableParityRows.count == r {
                break
            }
        }

        // Need at least R received parity shards to solve for R missing data shards.
        guard availableParityRows.count == r else { return 0 }

        // 1. Initialize RHS buffers `rhs[i]` (0 <= i < R) with the received parity shard `p = availableParityRows[i]`,
        //    and subtract the contribution of all PRESENT data shards:
        //    rhs[i] = Parity[p_i] ^ \sum_{d \in present} C_{p_i, d} * Data[d]
        var rhs = [[UInt8]](repeating: [UInt8](repeating: 0, count: shardSize), count: r)
        for i in 0..<r {
            let p = availableParityRows[i]
            if let pData = parityShards[p] {
                let copyLen = min(shardSize, pData.count)
                pData.withUnsafeBytes { rawP in
                    if let base = rawP.baseAddress {
                        rhs[i].withUnsafeMutableBytes { dstRaw in
                            memcpy(dstRaw.baseAddress!, base, copyLen)
                        }
                    }
                }
            }
        }

        for d in presentDataIndices {
            guard let dData = dataShards[d] else { continue }
            let copyLen = min(shardSize, dData.count)
            guard copyLen > 0 else { continue }
            dData.withUnsafeBytes { rawD in
                guard let srcPtr = rawD.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<r {
                    let p = availableParityRows[i]
                    let c = cauchyCoefficient(parityRow: p, dataCol: d, parityCount: m)
                    rhs[i].withUnsafeMutableBufferPointer { dstBuf in
                        mulAccumulateRow(
                            dst: dstBuf.baseAddress!,
                            src: srcPtr,
                            coeff: c,
                            byteCount: copyLen
                        )
                    }
                }
            }
        }

        // 2. Build the R x R Cauchy submatrix `mat[i * r + j] = C_{p_i, missing_j}`.
        var mat = [UInt8](repeating: 0, count: r * r)
        for i in 0..<r {
            let p = availableParityRows[i]
            for j in 0..<r {
                let d = missingDataIndices[j]
                mat[i * r + j] = cauchyCoefficient(parityRow: p, dataCol: d, parityCount: m)
            }
        }

        // 3. Gauss-Jordan elimination over GF(2^8) to invert `mat` directly onto `rhs`.
        for col in 0..<r {
            var pivotRow = col
            while pivotRow < r && mat[pivotRow * r + col] == 0 {
                pivotRow += 1
            }
            guard pivotRow < r else { return 0 }

            if pivotRow != col {
                for c in 0..<r {
                    mat.swapAt(col * r + c, pivotRow * r + c)
                }
                rhs.swapAt(col, pivotRow)
            }

            let pivotVal = mat[col * r + col]
            if pivotVal != 1 {
                let invPivot = gfInv(pivotVal)
                for c in col..<r {
                    mat[col * r + c] = gfMul(mat[col * r + c], invPivot)
                }
                rhs[col].withUnsafeMutableBufferPointer { rowBuf in
                    scaleRow(row: rowBuf.baseAddress!, coeff: invPivot, byteCount: shardSize)
                }
            }

            for row in 0..<r where row != col {
                let factor = mat[row * r + col]
                if factor != 0 {
                    for c in col..<r {
                        mat[row * r + c] ^= gfMul(factor, mat[col * r + c])
                    }
                    rhs[col].withUnsafeBufferPointer { pivotBuf in
                        rhs[row].withUnsafeMutableBufferPointer { targetBuf in
                            mulAccumulateRow(
                                dst: targetBuf.baseAddress!,
                                src: pivotBuf.baseAddress!,
                                coeff: factor,
                                byteCount: shardSize
                            )
                        }
                    }
                }
            }
        }

        // 4. Write recovered data shards back into `dataShards`.
        for j in 0..<r {
            let d = missingDataIndices[j]
            dataShards[d] = Data(rhs[j])
        }

        return r
    }

    /// Boolean convenience wrapper around `reconstructMissingDataShards` (returns `true` when all data shards are present).
    public static func reconstruct(
        dataShards: inout [Data?],
        parityShards: [Data?],
        shardLength: Int
    ) -> Bool {
        if !dataShards.contains(where: { $0 == nil }) {
            return true
        }
        _ = reconstructMissingDataShards(
            dataShards: &dataShards,
            parityShards: parityShards,
            shardSize: shardLength
        )
        return !dataShards.contains(where: { $0 == nil })
    }
}
