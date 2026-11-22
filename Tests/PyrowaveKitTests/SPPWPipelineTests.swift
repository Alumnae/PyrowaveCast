import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import CPyrowaveMetal
import Testing
@testable import PyrowaveKit
@testable import PyrowaveServerKit
@testable import SPPWCommon

@Test func reedSolomonGF256RecoversMultiShardBurstErasures() throws {
    let dataCount = 12
    let parityCount = 4
    let shardLength = 320
    let originals: [Data] = (0..<dataCount).map { shardIdx in
        var bytes = [UInt8](repeating: 0, count: shardLength)
        for i in 0..<shardLength {
            bytes[i] = UInt8(truncatingIfNeeded: (shardIdx * 53 + i * 19 + 7) & 0xFF)
        }
        return Data(bytes)
    }

    let parity = SPPWReedSolomonGF256.encodeParity(
        dataShards: originals,
        parityShardCount: parityCount,
        shardLength: shardLength
    )
    #expect(parity.count == parityCount)

    // Drop a burst of 4 data shards (indices 2, 3, 4, 5) — exact maximum capacity.
    var receivedData: [Data?] = originals.map { Optional($0) }
    for lost in [2, 3, 4, 5] {
        receivedData[lost] = nil
    }
    var receivedParity: [Data?] = parity.map { Optional($0) }
    // Also test replacing one parity shard when only 3 data shards are missing.
    let recoveredAllFour = SPPWReedSolomonGF256.reconstruct(
        dataShards: &receivedData,
        parityShards: receivedParity,
        shardLength: shardLength
    )
    #expect(recoveredAllFour)
    for idx in 0..<dataCount {
        #expect(receivedData[idx] == originals[idx])
    }

    // Also test mixed data + parity loss (3 data shards lost + 1 parity shard lost).
    var mixedData: [Data?] = originals.map { Optional($0) }
    mixedData[0] = nil
    mixedData[7] = nil
    mixedData[11] = nil
    receivedParity[1] = nil
    let recoveredMixed = SPPWReedSolomonGF256.reconstruct(
        dataShards: &mixedData,
        parityShards: receivedParity,
        shardLength: shardLength
    )
    #expect(recoveredMixed)
    for idx in 0..<dataCount {
        #expect(mixedData[idx] == originals[idx])
    }
}

@Test func pyrowaveSubbandInspectorIdentifiesCoarseLLBoundary() throws {
    let frame = try TestFrames.synthetic420(width: 256, height: 128)
    let encoded = try PyrowaveCodec().encode(
        frame,
        configuration: CodecConfiguration(quantizationStep: 1.0 / 1024.0)
    )
    let boundary = try #require(SPPWPyrowaveSubbandInspector.inspect(encoded.data))

    #expect(boundary.width == 256)
    #expect(boundary.height == 128)
    #expect(boundary.llBlockCount > 0)
    #expect(boundary.totalBlockCount > boundary.llBlockCount)
    #expect(boundary.llByteEnd > 8)
    #expect(boundary.llByteEnd < boundary.totalByteEnd)
    #expect(boundary.totalByteEnd == encoded.data.count)
    #expect(SPPWPyrowaveSubbandInspector.validPrefixByteLength(of: encoded.data) == encoded.data.count)
}

@Test func asymmetricLLHFFECAssemblerRecoversLostLLAndHFFragments() throws {
    let frame = try TestFrames.synthetic420(width: 256, height: 128)
    let encoded = try PyrowaveCodec().encode(
        frame,
        configuration: CodecConfiguration(quantizationStep: 1.0 / 1024.0)
    )
    let datagrams = buildPacedFrameDatagrams(
        streamID: 7,
        frameID: 1,
        width: 256,
        height: 128,
        timestampNanoseconds: 1_000_000,
        bitstream: encoded.data,
        payloadLimit: 256,
        fecPercent: 20
    )

    let fragments = datagrams.filter { SPPWDatagramHeader($0)?.kind == .frameFragment }
    let parities = datagrams.filter { SPPWDatagramHeader($0)?.kind == .fecParity }
    #expect(fragments.count > 4)
    #expect(!parities.isEmpty)
    // Verify LL fragments are explicitly tagged with .llCritical
    let firstHeader = try #require(SPPWDatagramHeader(fragments[0]))
    #expect((firstHeader.flags & SPPWFragmentFlags.llCritical) != 0)

    // Drop fragment 0 (LL critical!) and the last fragment (HF detail), but feed all other datagrams + parity.
    var assembler = SPPWFrameAssembler()
    var assembled: SPPWAssembledFrame?
    for datagram in datagrams {
        if let h = SPPWDatagramHeader(datagram), h.kind == .frameFragment {
            if h.fragmentIndex == 0 || Int(h.fragmentIndex) == fragments.count - 1 {
                continue
            }
        }
        if let result = assembler.ingest(datagram, timeoutMilliseconds: 50) {
            assembled = result
        }
    }

    let recovered = try #require(assembled)
    #expect(recovered.frameID == 1)
    #expect(recovered.recoveredWithFEC)
    #expect(!recovered.isPartialHF)
    #expect(recovered.data == encoded.data)
    #expect(assembler.fecRecoveredFrames == 1)
    #expect(assembler.fecRecoveredPackets >= 2)
}

@Test func assemblerImmediatelyDropsOlderFrameWithUnrecoverableMissingLL() throws {
    let frame1 = try TestFrames.synthetic420(width: 256, height: 128, frameIndex: 0)
    let frame2 = try TestFrames.synthetic420(width: 256, height: 128, frameIndex: 1)
    let codec = try PyrowaveCodec()
    let encoded1 = try codec.encode(frame1, configuration: CodecConfiguration(quantizationStep: 1.0 / 1024.0))
    let encoded2 = try codec.encode(frame2, configuration: CodecConfiguration(quantizationStep: 1.0 / 1024.0))

    let datagrams1 = buildPacedFrameDatagrams(
        streamID: 7,
        frameID: 10,
        width: 256,
        height: 128,
        timestampNanoseconds: 1_000_000,
        bitstream: encoded1.data,
        payloadLimit: 256,
        fecPercent: 0
    )
    let datagrams2 = buildPacedFrameDatagrams(
        streamID: 7,
        frameID: 11,
        width: 256,
        height: 128,
        timestampNanoseconds: 17_666_666,
        bitstream: encoded2.data,
        payloadLimit: 256,
        fecPercent: 0
    )

    var assembler = SPPWFrameAssembler()
    // Feed frame 10 WITHOUT fragment 0 (missing LL subband, no FEC).
    for datagram in datagrams1.dropFirst() {
        #expect(assembler.ingest(datagram, timeoutMilliseconds: 100) == nil)
    }

    // As soon as the first datagram of frame 11 arrives, frame 10 must be discarded immediately ("scartare LL").
    var completedFrame11: SPPWAssembledFrame?
    for (idx, datagram) in datagrams2.enumerated() {
        if let out = assembler.ingest(datagram, timeoutMilliseconds: 100) {
            completedFrame11 = out
        }
        if idx == 0 {
            #expect(assembler.llDroppedFrames == 1)
        }
    }

    let finalFrame = try #require(completedFrame11)
    #expect(finalFrame.frameID == 11)
    #expect(finalFrame.data == encoded2.data)
}

@Test func assemblerSalvagesAndSessionDecodesPartialHFFrameWhenLLIsIntact() async throws {
    let source = try TestFrames.synthetic420(width: 256, height: 128)
    let descriptor = try PyrowaveSessionDescriptor(
        width: source.width,
        height: source.height,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        videoSignal: VideoSignalMetadata(yCbCrRange: .full)
    )
    let encoder = try PyrowaveEncoderSession(descriptor: descriptor)
    let decoder = try PyrowaveDecoderSession(descriptor: descriptor)
    let encoded = try await encoder.encode(source.makeCVPixelBuffer())

    let datagrams = buildPacedFrameDatagrams(
        streamID: 9,
        frameID: 20,
        width: UInt16(source.width),
        height: UInt16(source.height),
        timestampNanoseconds: 1_000_000,
        bitstream: encoded.frame.data,
        payloadLimit: 256,
        fecPercent: 0
    )
    #expect(datagrams.count >= 4)

    // Deliver all fragments of frame 20 EXCEPT the last HF fragment.
    var assembler = SPPWFrameAssembler()
    for datagram in datagrams.dropLast() {
        #expect(assembler.ingest(datagram, timeoutMilliseconds: 50, allowPartialHFDecode: true) == nil)
    }

    // When a newer frame's first packet arrives, frame 20 has 100% intact LL and only misses trailing HF:
    // the assembler salvages the valid block-aligned prefix immediately.
    let nextFrameFirstDatagram = makeWireFragmentDatagram(
        streamID: 9,
        frameID: 21,
        flags: SPPWFragmentFlags.llCritical,
        width: UInt16(source.width),
        height: UInt16(source.height),
        fragmentIndex: 0,
        fragmentCount: 4,
        frameByteCount: 1000,
        timestampNanoseconds: 17_000_000,
        bitstream: encoded.frame.data,
        range: 0..<250
    )

    let salvagedCandidate = assembler.ingest(
        nextFrameFirstDatagram,
        timeoutMilliseconds: 50,
        allowPartialHFDecode: true
    )
    let salvaged = try #require(salvagedCandidate)
    #expect(salvaged.frameID == 20)
    #expect(salvaged.isPartialHF)
    #expect(assembler.partialHFFrames == 1)
    #expect(salvaged.data.count < encoded.frame.data.count)

    // Verify PyrowaveDecoderSession decodes the partial-HF frame on GPU when allowPartialFrame is true.
    let decoded = try await decoder.decode(EncodedFrame(data: salvaged.data), allowPartialFrame: salvaged.isPartialHF)
    #expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == source.width)
    #expect(CVPixelBufferGetHeight(decoded.pixelBuffer) == source.height)
}

@Test func adaptiveWiFiBufferAdjustsTimeoutAndPlayoutToJitter() {
    var buffer = SPPWAdaptiveWiFiBuffer(mode: .wifiResilient)
    let baseTimeout = buffer.recommendedTimeoutMs(fps: 60)
    #expect(baseTimeout >= 28)

    // Simulate clean 60 fps arrival first, then 18 ms Wi-Fi contention jitter spikes.
    var senderTs: UInt64 = 100_000_000
    var arrivalTs: UInt64 = 100_000_000
    let interval: UInt64 = 16_666_666
    for i in 0..<20 {
        senderTs += interval
        let spike: UInt64 = (i % 2 == 0) ? 18_000_000 : 0
        arrivalTs += interval + (i % 2 == 0 ? spike : 0)
        buffer.recordFrameArrival(senderTimestampNanos: senderTs, arrivalUptimeNanos: arrivalTs)
    }

    #expect(buffer.jitterMilliseconds > 4.0)
    #expect(buffer.recommendedTimeoutMs(fps: 60) > baseTimeout)
    #expect(buffer.targetPlayoutDelayMilliseconds > 0)
}

@Test func audioHeaderAndInputEventsRoundTripBinaryEncoding() {
    let audioHeader = SPPWAudioPacketHeader(sequence: 42, frameCount: 240, channels: 2)
    let encodedAudioHeader = audioHeader.encoded()
    #expect(encodedAudioHeader.count == SPPWAudioPacketHeader.byteCount)
    let decodedAudioHeader = SPPWAudioPacketHeader(encodedAudioHeader)
    #expect(decodedAudioHeader == audioHeader)

    let events: [SPPWInputEvent] = [
        .pointerMove(normalizedX: 0.25, normalizedY: 0.75),
        .mouseButton(button: 0, isDown: true, normalizedX: 0.5, normalizedY: 0.5),
        .scroll(deltaX: -1.5, deltaY: 3.25),
        .key(keyCode: 49, isDown: true, modifiers: 0x0100),
        .touch([
            SPPWTouchPoint(id: 1, phase: 0, normalizedX: 0.1, normalizedY: 0.2),
            SPPWTouchPoint(id: 2, phase: 1, normalizedX: 0.8, normalizedY: 0.9),
        ]),
    ]

    for event in events {
        let payload = event.encode()
        let decoded = SPPWInputEvent.decode(from: payload)
        #expect(decoded == event)
    }
}

@Test func socketBufferTuningAppliesSendAndReceiveBuffersOnUDPSocket() {
    let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    #expect(fd >= 0)
    defer { Darwin.close(fd) }

    let result = SPPWSocketBufferTuning.apply(
        to: fd,
        sendBufferBytes: 2 * 1024 * 1024,
        receiveBufferBytes: 2 * 1024 * 1024,
        dscpClass: SPPWSocketBufferTuning.dscpInteractiveVideoCS4
    )
    #expect(result.actualSendBytes >= 256 * 1024)
    #expect(result.actualReceiveBytes >= 256 * 1024)
}

@Test func adaptiveBitrateStepsDownEverySecondAndHoldsRampUpAtLeast10Seconds() {
    let sec: UInt64 = 1_000_000_000
    var t: UInt64 = 10 * sec
    var abr = SPPWAdaptiveBitrateController(
        ceilingBitrateBps: 180_000_000,
        nowNanoseconds: t
    )

    // Sub-second sample must be ignored (enforces 1 s cadence).
    let subSec = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t + 500_000_000,
        completeFramesDelta: 30,
        llDroppedFramesDelta: 2
    ))
    #expect(subSec == .hold)
    #expect(abr.currentBitrateBps == 180_000_000)

    // Two consecutive 1-second degraded ticks step bitrate down each second.
    t += sec
    let step1 = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 55,
        llDroppedFramesDelta: 2
    ))
    guard case let .stepDown(bps1, _) = step1 else {
        Issue.record("Expected stepDown on first degraded second, got \(step1)")
        return
    }
    #expect(bps1 < 180_000_000)

    t += sec
    let step2 = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 58,
        partialHFFramesDelta: 3
    ))
    guard case let .stepDown(bps2, _) = step2 else {
        Issue.record("Expected stepDown on second degraded second, got \(step2)")
        return
    }
    #expect(bps2 < bps1)

    // Clean seconds 1..9 MUST NOT ramp up (< 10 s cooldown).
    for _ in 1...9 {
        t += sec
        let decision = abr.evaluate(SPPWAdaptiveBitrateSample(
            timestampNanoseconds: t,
            completeFramesDelta: 60,
            jitterMs: 3.0
        ))
        #expect(decision == .hold)
    }
    #expect(abr.currentBitrateBps == bps2)
    #expect(abr.lastStableBitrateBps == bps2)

    // At 10 clean seconds, ABR cautiously probes upward.
    t += sec
    let probe = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 60,
        jitterMs: 3.0
    ))
    guard case let .probeUp(probedBps) = probe else {
        Issue.record("Expected probeUp at 10 s clean, got \(probe)")
        return
    }
    #expect(probedBps > bps2)
}

@Test func adaptiveBitrateRevertsAndLocksStableBitrateWhenPenalizedLinkPersists() {
    let sec: UInt64 = 1_000_000_000
    var t: UInt64 = 10 * sec
    var abr = SPPWAdaptiveBitrateController(
        ceilingBitrateBps: 120_000_000,
        nowNanoseconds: t
    )

    // Step down once to find a clean operating point.
    t += sec
    let drop = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 50,
        expiredFramesDelta: 2
    ))
    guard case let .stepDown(stableBps, _) = drop else {
        Issue.record("Expected initial stepDown, got \(drop)")
        return
    }

    // 10 clean seconds -> 1st probe upward.
    for _ in 1...9 {
        t += sec
        #expect(abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) == .hold)
    }
    t += sec
    guard case .probeUp = abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) else {
        Issue.record("Expected 1st probeUp after 10 s clean")
        return
    }

    // Link degrades again immediately (heavy loss, not an isolated blip) -> revert to
    // stableBps (1st failure doubles cooldown to 20 s).
    t += sec
    let revert1 = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 54,
        llDroppedFramesDelta: 2
    ))
    guard case let .revertToStable(reverted1, locked1, _) = revert1 else {
        Issue.record("Expected revertToStable on 1st failed probe, got \(revert1)")
        return
    }
    #expect(reverted1 == stableBps)
    #expect(!locked1)

    // Must hold for at least 19 s (20 s backoff cooldown after 1st failed probe).
    for _ in 1...19 {
        t += sec
        #expect(abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) == .hold)
    }

    // At 20 s clean -> 2nd probe upward.
    t += sec
    guard case .probeUp = abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) else {
        Issue.record("Expected 2nd probeUp after 20 s clean")
        return
    }

    // Instability still persists -> revert AND lock ceiling at the problem-free bitrate.
    t += sec
    let revert2 = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 55,
        partialHFFramesDelta: 6
    ))
    guard case let .revertToStable(reverted2, locked2, _) = revert2 else {
        Issue.record("Expected revertToStable + lock on 2nd failed probe, got \(revert2)")
        return
    }
    #expect(reverted2 == stableBps)
    #expect(locked2)
    #expect(abr.isCeilingLocked)
    #expect(abr.learnedSafeCeilingBps == stableBps)

    // Even after 60 more clean seconds, stays pinned at the problem-free bitrate.
    for _ in 1...60 {
        t += sec
        #expect(abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) == .hold)
    }
    #expect(abr.currentBitrateBps == stableBps)
}

@Test func videoOrientationRotationsAndFlipsTrackDimensionSwaps() {
    var orientation = SPPWVideoOrientation()
    #expect(orientation.isIdentity)
    #expect(!orientation.swapsDimensions)

    // 0° -> 90° CW swaps dimensions (1920x1080 -> 1080x1920)
    let swapped90 = orientation.rotate()
    #expect(swapped90)
    #expect(orientation.degreesClockwise == 90)
    #expect(orientation.swapsDimensions)

    // 90° -> 180° CW swaps dimensions back to landscape
    let swapped180 = orientation.rotate()
    #expect(swapped180)
    #expect(orientation.degreesClockwise == 180)
    #expect(!orientation.swapsDimensions)

    // 180° -> 270° CW swaps dimensions to portrait
    let swapped270 = orientation.rotate()
    #expect(swapped270)
    #expect(orientation.degreesClockwise == 270)
    #expect(orientation.swapsDimensions)

    // 270° -> 0° CW swaps dimensions back to landscape
    let swapped0 = orientation.rotate()
    #expect(swapped0)
    #expect(orientation.degreesClockwise == 0)
    #expect(!orientation.swapsDimensions)

    orientation.toggleFlip()
    #expect(orientation.isFlippedHorizontally)
    #expect(orientation.scaleX == -1.0)
    #expect(orientation.scaleY == 1.0)
    #expect(!orientation.isIdentity)

    orientation.toggleFlip()
    #expect(!orientation.isFlippedHorizontally)
    #expect(orientation.isIdentity)
}

@Test func localizationCatalogCoversAllSevenLanguages() {
    let requiredLanguages = ["it", "zh", "en", "fr", "de", "ja", "es"]
    #expect(SPPWLocalization.translations.count >= 150)
    for (key, table) in SPPWLocalization.translations {
        for lang in requiredLanguages {
            let value = table[lang] ?? ""
            #expect(!value.isEmpty, "Missing \(lang) translation for \(key)")
        }
    }
}

/// End-to-end 4:4:4 path of the macOS server: a ScreenCaptureKit-style 'xf44'
/// (10-bit 4:4:4 biplanar) IOSurface feeds the vendored encoder, and the
/// receiver session decodes the bitstream to BGRA.
@Test func upstreamEncoderEncodesXF44SurfaceAs444AndSessionDecodesToBGRA() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let width = 128
    let height = 96
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true
    ]
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
        attributes as CFDictionary, &created
    )
    let pixelBuffer = try #require(status == kCVReturnSuccess ? created : nil)
    #expect(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == width)

    // Uniform colour, 10-bit codes stored in the MSBs of 16-bit words.
    let yCode: UInt16 = 512, cbCode: UInt16 = 717, crCode: UInt16 = 410
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    for row in 0..<height {
        let yRow = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt16.self)
        let cRow = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt16.self)
        for column in 0..<width {
            yRow[column] = yCode << 6
            cRow[column * 2] = cbCode << 6
            cRow[column * 2 + 1] = crCode << 6
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    #expect(UpstreamMetalEncoder.chromaSubsampling(of: pixelBuffer, width: width, height: height) == PYROWAVE_CHROMA_SUBSAMPLING_444)
    let encoder = try UpstreamMetalEncoder()
    let encoded = try encoder.encode(pixelBuffer: pixelBuffer, maximumBitstreamBytes: 4_000_000, packetBoundary: 1200)
    #expect(PyrowaveSessionDescriptor.preferredPixelFormat(forBitstream: encoded.bitstream) == kCVPixelFormatType_32BGRA)

    let session = try PyrowaveDecoderSession(descriptor: try PyrowaveSessionDescriptor(
        width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA
    ))
    let decoded = try await session.decode(EncodedFrame(data: encoded.bitstream))
    let output = decoded.pixelBuffer
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
    let pixel = base + (height / 2) * CVPixelBufferGetBytesPerRow(output) + (width / 2) * 4

    let luma = Double(yCode) / 1023
    let cb = Double(cbCode) / 1023 - 0.5
    let cr = Double(crCode) / 1023 - 0.5
    let expected = [luma + 1.8556 * cb, luma - 0.1873 * cb - 0.4681 * cr, luma + 1.5748 * cr]
        .map { Int((min(max($0, 0), 1) * 255).rounded()) }
    for channel in 0..<3 {
        #expect(abs(Int(pixel[channel]) - expected[channel]) <= 6, "channel \(channel): \(pixel[channel]) vs \(expected[channel])")
    }
}

// MARK: - Audio/video sync

/// Builds an interleaved PCM `CMSampleBuffer` stamped on the host clock.
private func makePCMSampleBuffer(
    frames: Int,
    sampleRate: Double,
    channels: Int,
    bigEndian: Bool = false,
    presentationTime: CMTime
) throws -> CMSampleBuffer {
    var flags: AudioFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    if bigEndian { flags |= kAudioFormatFlagIsBigEndian }
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: UInt32(2 * channels),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(2 * channels),
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var format: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &format) == noErr)
    var samples = [Int16](repeating: 0, count: frames * channels)
    for i in 0..<frames {
        let value = Int16(clamping: Int(sin(Double(i) / 10) * 8000))
        for c in 0..<channels {
            samples[i * channels + c] = bigEndian ? value.bigEndian : value
        }
    }
    let byteCount = samples.count * 2
    var block: CMBlockBuffer?
    #expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                               blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                               dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr)
    _ = samples.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
    }
    var sampleBuffer: CMSampleBuffer?
    #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
        presentationTimeStamp: presentationTime, packetDescriptions: nil, sampleBufferOut: &sampleBuffer
    ) == noErr)
    return try #require(sampleBuffer)
}

@Test func captureClockConvertsHostTimeAndRejectsForeignTimelines() {
    let now = SPPWCaptureClock.nowNanoseconds()
    let host = CMClockGetTime(CMClockGetHostTimeClock())
    let converted = SPPWCaptureClock.nanoseconds(fromHostTime: host, now: now)
    #expect(converted != nil)
    if let converted {
        let distance = converted > now ? converted - now : now - converted
        #expect(distance < 5_000_000)
    }
    // A media-file timeline (seconds since the start of a clip) is not on the host clock.
    #expect(SPPWCaptureClock.nanoseconds(fromHostTime: CMTime(seconds: 3, preferredTimescale: 600), now: now) == nil)
    #expect(SPPWCaptureClock.nanoseconds(fromHostTime: .invalid, now: now) == nil)
}

@Test func audioPacketizerStampsChunksWithCaptureTime() throws {
    let packetizer = SPPWAudioPacketizer()
    let start = CMClockGetTime(CMClockGetHostTimeClock())
    let startNanos = try #require(SPPWCaptureClock.nanoseconds(fromHostTime: start))
    // 48 kHz stereo native-endian Int16: fast path, 960 frames = 4 chunks.
    let buffer = try makePCMSampleBuffer(frames: 960, sampleRate: 48_000, channels: 2, presentationTime: start)
    let packets = packetizer.packetize(sampleBuffer: buffer)
    #expect(packets.count == 4)
    for (index, packet) in packets.enumerated() {
        let expected = startNanos + UInt64(index) * 5_000_000
        let distance = packet.timestampNanoseconds > expected ? packet.timestampNanoseconds - expected : expected - packet.timestampNanoseconds
        #expect(distance <= 1_000, "chunk \(index) timestamp off by \(distance) ns")
        #expect(packet.payload.count == SPPWAudioPacketHeader.byteCount + 960)
    }

    // A second buffer 20 ms later continues the timeline exactly.
    let next = CMTimeAdd(start, CMTime(value: 960, timescale: 48_000))
    let more = packetizer.packetize(sampleBuffer: try makePCMSampleBuffer(frames: 480, sampleRate: 48_000, channels: 2, presentationTime: next))
    try #require(more.count == 2)
    let expectedNext = startNanos + 20_000_000
    let distance = more[0].timestampNanoseconds > expectedNext ? more[0].timestampNanoseconds - expectedNext : expectedNext - more[0].timestampNanoseconds
    #expect(distance <= 1_000)
}

@Test func audioPacketizerResamplesReplayKitStyle44kBigEndianMono() throws {
    let packetizer = SPPWAudioPacketizer()
    let start = CMClockGetTime(CMClockGetHostTimeClock())
    var totalChunks = 0
    var time = start
    // 1 s of 44.1 kHz big-endian mono, in 1024-frame buffers (typical ReplayKit .audioApp).
    for _ in 0..<43 {
        let buffer = try makePCMSampleBuffer(frames: 1024, sampleRate: 44_100, channels: 1, bigEndian: true, presentationTime: time)
        let packets = packetizer.packetize(sampleBuffer: buffer)
        for packet in packets {
            let header = try #require(SPPWAudioPacketHeader(parsing: packet.payload))
            #expect(header.channels == 2)
            #expect(header.frameCount == 240)
            // Left and right carry the same (upmixed) mono signal, in native little-endian.
            let pcm = packet.payload.dropFirst(SPPWAudioPacketHeader.byteCount)
            let l = Int16(littleEndian: pcm.withUnsafeBytes { $0.load(fromByteOffset: 200, as: Int16.self) })
            let r = Int16(littleEndian: pcm.withUnsafeBytes { $0.load(fromByteOffset: 202, as: Int16.self) })
            #expect(l == r)
            #expect(abs(Int(l)) <= 8_100)
        }
        totalChunks += packets.count
        time = CMTimeAdd(time, CMTime(value: 1024, timescale: 44_100))
    }
    // 43 * 1024 frames @ 44.1 kHz = 0.9987 s -> ~47_937 frames @ 48 kHz -> ~199 chunks.
    #expect((195...200).contains(totalChunks), "got \(totalChunks) chunks")
}

@Test func avSyncClockTargetsAudioAtVideoPresentationDelay() {
    let clock = SPPWAVSyncClock()
    clock.videoDisplayLatencyNanos = 10_000_000
    #expect(clock.targetPlayoutNanos(senderCaptureNanos: 1_000, now: 1_000) == nil)

    // Receiver clock is 5 s ahead of the server's; video takes 40 ms from capture to display.
    let offset: UInt64 = 5_000_000_000
    let capture: UInt64 = 10_000_000_000
    clock.noteVideoPresented(senderCaptureNanos: capture, presentedAtNanos: capture + offset + 40_000_000)
    let now = capture + offset + 41_000_000
    let target = clock.targetPlayoutNanos(senderCaptureNanos: capture + 2_000_000, now: now)
    #expect(target == capture + 2_000_000 + offset + 50_000_000)

    // Smoothing follows small changes gradually, a large jump resets.
    clock.noteVideoPresented(senderCaptureNanos: capture + 16_000_000, presentedAtNanos: capture + 16_000_000 + offset + 50_000_000)
    // The estimate includes the 5 s clock offset.
    let smoothed = (clock.videoDelayMilliseconds ?? 0) - 5_000
    #expect(smoothed > 40 && smoothed < 50)
    clock.noteVideoPresented(senderCaptureNanos: capture + 32_000_000, presentedAtNanos: capture + 32_000_000 + offset + 900_000_000)
    #expect(clock.videoDelayMilliseconds == 5_900)

    // Stale video stops driving audio.
    #expect(clock.targetPlayoutNanos(senderCaptureNanos: capture, now: capture + offset + 3_000_000_000) == nil)
    clock.reset()
    #expect(clock.videoDelayMilliseconds == nil)
}

@Test func jitterControllerNeverChattersWhenAudioCannotReachVideo() {
    // Regression for choppy audio: audio's own path is 25 ms slower than video, packets arrive
    // in ScreenCaptureKit-style 21 ms bursts. The old per-packet rule dropped almost every
    // packet; the controller must keep playing with at most rare corrections.
    var controller = SPPWAudioJitterController(minimumQueueNanos: 40_000_000)
    var now: UInt64 = 1_000_000_000
    var queued: Int64 = 40_000_000
    var drops = 0, silences = 0
    for packet in 0..<2_000 { // 10 s
        // Burst arrival: queue saw-tooths between ~30 and ~51 ms.
        let phase = Int64(packet % 4)
        let measured = queued - 21_000_000 + phase * 5_000_000
        switch controller.decide(queuedNanos: measured, latenessNanos: 25_000_000, now: now) {
        case .play: break
        case .drop: drops += 1
        case .delay: silences += 1
        }
        now += 5_000_000
    }
    #expect(drops == 0)
    #expect(silences <= 1)
}

@Test func jitterControllerAlignsEarlyAudioAndTrimsDeepQueuesGently() {
    var controller = SPPWAudioJitterController(minimumQueueNanos: 30_000_000)
    var now: UInt64 = 5_000_000_000
    // Empty queue at start: one refill to the depth that puts audio on the video timeline
    // (audio arrives 80 ms early -> desired depth 80 ms).
    let first = controller.decide(queuedNanos: 0, latenessNanos: -80_000_000, now: now)
    #expect(first == .delay(silenceFrames: 3_840))

    // A queue 60 ms too deep is trimmed one 5 ms packet at a time, at most every 250 ms.
    controller = SPPWAudioJitterController(minimumQueueNanos: 30_000_000)
    var dropTimes: [UInt64] = []
    for _ in 0..<400 {
        if controller.decide(queuedNanos: 90_000_000, latenessNanos: nil, now: now) == .drop {
            dropTimes.append(now)
        }
        now += 5_000_000
    }
    #expect(!dropTimes.isEmpty)
    for (a, b) in zip(dropTimes, dropTimes.dropFirst()) {
        #expect(b - a >= 250_000_000)
    }

    // A shallow queue gets small silences (<= 10 ms each), never a large gap.
    controller = SPPWAudioJitterController(minimumQueueNanos: 30_000_000)
    _ = controller.decide(queuedNanos: 30_000_000, latenessNanos: -50_000_000, now: now)
    for _ in 0..<200 {
        now += 5_000_000
        if case .delay(let frames) = controller.decide(queuedNanos: 30_000_000, latenessNanos: -50_000_000, now: now) {
            #expect(frames <= 480)
        }
    }
}

@Test func orderedPacketQueueDeliversInProductionOrder() async {
    let queue = SPPWOrderedPacketQueue<Int>()
    let stream = queue.makeStream()
    DispatchQueue.global().async {
        for value in 0..<200 { queue.yield(value) }
        queue.finish()
    }
    var received: [Int] = []
    for await value in stream { received.append(value) }
    #expect(received == Array(0..<200))
}

@Test func audioPacketizerAppliesInputGainAndAcceptsPCMBuffers() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480
    for channel in 0..<2 {
        for i in 0..<480 { buffer.floatChannelData![channel][i] = 0.25 }
    }
    let captured = SPPWCaptureClock.nowNanoseconds()

    func firstSample(gain: Float) throws -> Int16 {
        let packetizer = SPPWAudioPacketizer()
        packetizer.gain = gain
        let packets = packetizer.packetize(pcmBuffer: buffer, captureNanoseconds: captured)
        #expect(packets.count == 2)
        #expect(packets.first?.timestampNanoseconds == captured)
        let packet = try #require(packets.last)
        return Int16(littleEndian: packet.payload.withUnsafeBytes {
            $0.load(fromByteOffset: SPPWAudioPacketHeader.byteCount + 40, as: Int16.self)
        })
    }

    let unity = try firstSample(gain: 1)
    #expect(abs(Int(unity) - 8192) <= 2)
    #expect(try firstSample(gain: 0) == 0)
    #expect(abs(Int(try firstSample(gain: 2)) - 16384) <= 4)
    // Out-of-range values are clamped.
    let packetizer = SPPWAudioPacketizer()
    packetizer.gain = 7
    #expect(packetizer.gain == 2)
    packetizer.gain = -1
    #expect(packetizer.gain == 0)
}

@Test func audioSourceCatalogListsNoneAndSystemFirstAndResolvesIDs() {
    let sources = SPPWAudioSourceCatalog.availableSources()
    #expect(sources.count >= 2)
    #expect(sources[0].kind == .none)
    #expect(sources[1].kind == .system)
    #expect(Set(sources.map(\.id)).count == sources.count)
    #expect(SPPWAudioSourceCatalog.source(withID: "none", in: sources).kind == .none)
    // A device that disappeared falls back to system audio.
    #expect(SPPWAudioSourceCatalog.source(withID: "input:missing-device", in: sources).kind == .system)
    let mic = SPPWAudioSourceOption(kind: .input(id: "ABC"), name: "Mic")
    #expect(mic.id == "input:ABC")
}

/// Regression: `SPPWAudioPlayer.stop()` used to call `AVAudioPlayerNode.stop()` while holding
/// the lock its buffer completion handlers take, which deadlocked the macOS receiver on
/// disconnect whenever audio was still queued.
@Test func audioPlayerStopsWithQueuedAudioWithoutDeadlock() throws {
    let player = SPPWAudioPlayer()
    func packet(_ sequence: UInt32) -> Data {
        var payload = SPPWAudioPacketHeader(sequence: sequence, frameCount: 240).encoded()
        payload.append(Data(count: 240 * 4))
        return payload
    }
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        for round in 0..<3 {
            for i in 0..<9 { player.enqueue(audioPayload: packet(UInt32(round * 10 + i))) }
            player.isMuted = true      // pauses the engine with audio queued
            player.isMuted = false
            for i in 0..<9 { player.enqueue(audioPayload: packet(UInt32(round * 10 + i))) }
            player.stop()              // disconnect
        }
        finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 10) == .success, "SPPWAudioPlayer stop/mute deadlocked")
}

@Test func inputEventEncodeDecodeRoundTripCoversAllTags() {
    let events: [SPPWInputEvent] = [
        .pointerMove(normalizedX: 0.25, normalizedY: 0.75),
        .mouseButton(button: 0, isDown: true, normalizedX: 0.5, normalizedY: 0.5),
        .mouseButton(button: 1, isDown: false, normalizedX: 0.9, normalizedY: 0.1),
        .scroll(deltaX: -12.5, deltaY: 24.0),
        .key(keyCode: 8, isDown: true, modifiers: 0x0010_0000),
        .touch([SPPWTouchPoint(id: 7, phase: .began, normalizedX: 0.3, normalizedY: 0.6)]),
        .releaseAll
    ]
    for event in events {
        let encoded = event.encoded()
        let decoded = SPPWInputEvent.decode(from: encoded)
        #expect(decoded == event)
    }
    #expect(SPPWInputEvent.releaseAll.encoded() == Data([6]))
    #expect(SPPWInputEvent.decode(from: Data()) == nil)
    #expect(SPPWInputEvent.decode(from: Data([99])) == nil)
    #expect(SPPWInputEvent.decode(from: Data([1, 0, 0])) == nil)
}

@Test func inputCoordinateMapperHandlesLetterboxAndOrientations() throws {
    // 1. Exact fit 16:9 in AppKit (+Y up): top-left is (0, 540), bottom-right is (960, 0).
    let identity = SPPWVideoOrientation()
    let topLeft = try #require(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 0, viewY: 540, viewWidth: 960, viewHeight: 540,
        videoWidth: 1920, videoHeight: 1080, orientation: identity
    ))
    #expect(abs(topLeft.normalizedX - 0.0) < 1e-4)
    #expect(abs(topLeft.normalizedY - 0.0) < 1e-4)
    #expect(topLeft.isInsideVideo)

    let bottomRight = try #require(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 960, viewY: 0, viewWidth: 960, viewHeight: 540,
        videoWidth: 1920, videoHeight: 1080, orientation: identity
    ))
    #expect(abs(bottomRight.normalizedX - 1.0) < 1e-4)
    #expect(abs(bottomRight.normalizedY - 1.0) < 1e-4)

    // 2. Pillarboxed 16:9 video (1600x900) inside wide 2000x900 view -> 200px black bars on left/right.
    #expect(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 50, viewY: 450, viewWidth: 2000, viewHeight: 900,
        videoWidth: 1920, videoHeight: 1080, orientation: identity, clampOutside: false
    ) == nil)
    let clamped = try #require(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 50, viewY: 450, viewWidth: 2000, viewHeight: 900,
        videoWidth: 1920, videoHeight: 1080, orientation: identity, clampOutside: true
    ))
    #expect(clamped.normalizedX == 0.0)
    #expect(abs(clamped.normalizedY - 0.5) < 1e-4)
    #expect(!clamped.isInsideVideo)

    // 3. 90° CW rotation: unrotated video top-left moves to view top-right (viewX = W, viewY = H).
    let rot90 = SPPWVideoOrientation(quarterTurnsClockwise: 1, isFlippedHorizontally: false)
    let rot90TopLeft = try #require(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 540, viewY: 960, viewWidth: 540, viewHeight: 960,
        videoWidth: 1920, videoHeight: 1080, orientation: rot90
    ))
    #expect(abs(rot90TopLeft.normalizedX - 0.0) < 1e-4)
    #expect(abs(rot90TopLeft.normalizedY - 0.0) < 1e-4)

    // 4. Horizontal flip: video top-left moves to view top-right.
    let flipped = SPPWVideoOrientation(quarterTurnsClockwise: 0, isFlippedHorizontally: true)
    let flippedTopLeft = try #require(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 960, viewY: 540, viewWidth: 960, viewHeight: 540,
        videoWidth: 1920, videoHeight: 1080, orientation: flipped
    ))
    #expect(abs(flippedTopLeft.normalizedX - 0.0) < 1e-4)
    #expect(abs(flippedTopLeft.normalizedY - 0.0) < 1e-4)

    // 5. Combined 90° CW + horizontal flip: video top-left moves to view bottom-right (viewX = W, viewY = 0).
    let rot90Flipped = SPPWVideoOrientation(quarterTurnsClockwise: 1, isFlippedHorizontally: true)
    let combined = try #require(SPPWInputCoordinateMapper.mapAppKitPoint(
        viewX: 540, viewY: 0, viewWidth: 540, viewHeight: 960,
        videoWidth: 1920, videoHeight: 1080, orientation: rot90Flipped
    ))
    #expect(abs(combined.normalizedX - 0.0) < 1e-4)
    #expect(abs(combined.normalizedY - 0.0) < 1e-4)
}

#if os(macOS)
@Test func macInputControllerTracksMultiDisplayCoordsClicksAndReleaseAll() {
    let secondaryBounds = CGRect(x: 1920, y: -200, width: 2560, height: 1440)
    let originPt = SPPWMacInputController.screenPoint(normalizedX: 0, normalizedY: 0, displayBounds: secondaryBounds)
    #expect(originPt == CGPoint(x: 1920, y: -200))
    let maxPt = SPPWMacInputController.screenPoint(normalizedX: 1.5, normalizedY: 1.5, displayBounds: secondaryBounds)
    #expect(maxPt == CGPoint(x: 1920 + 2559, y: -200 + 1439))
    let nanPt = SPPWMacInputController.screenPoint(normalizedX: .nan, normalizedY: .infinity, displayBounds: secondaryBounds)
    #expect(nanPt.x.isFinite && nanPt.y.isFinite)

    let controller = SPPWMacInputController(postEvents: false)
    let baseTime: UInt64 = 10_000_000_000

    // Single click -> clickState = 1
    controller.inject(.mouseButton(button: 0, isDown: true, normalizedX: 0.5, normalizedY: 0.5), displayBounds: secondaryBounds, nowNanoseconds: baseTime)
    #expect(controller.stateSnapshot.heldButtons == [0])
    #expect(controller.stateSnapshot.currentClickState == 1)

    controller.inject(.mouseButton(button: 0, isDown: false, normalizedX: 0.5, normalizedY: 0.5), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 40_000_000)
    #expect(controller.stateSnapshot.heldButtons.isEmpty)

    // Double click within 500 ms at same point -> clickState = 2
    controller.inject(.mouseButton(button: 0, isDown: true, normalizedX: 0.5, normalizedY: 0.5), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 200_000_000)
    #expect(controller.stateSnapshot.currentClickState == 2)
    controller.inject(.mouseButton(button: 0, isDown: false, normalizedX: 0.5, normalizedY: 0.5), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 240_000_000)
    // Redundant mouseUp is safely ignored
    controller.inject(.mouseButton(button: 0, isDown: false, normalizedX: 0.5, normalizedY: 0.5), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 241_000_000)
    #expect(controller.stateSnapshot.heldButtons.isEmpty)

    // Hold button + Command + C key, then releaseAll clears everything
    let cmdFlag = UInt32(CGEventFlags.maskCommand.rawValue)
    controller.inject(.mouseButton(button: 1, isDown: true, normalizedX: 0.2, normalizedY: 0.2), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 900_000_000)
    controller.inject(.key(keyCode: 55, isDown: true, modifiers: cmdFlag), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 910_000_000)
    controller.inject(.key(keyCode: 8, isDown: true, modifiers: cmdFlag), displayBounds: secondaryBounds, nowNanoseconds: baseTime + 920_000_000)
    #expect(controller.stateSnapshot.heldButtons == [1])
    #expect(controller.stateSnapshot.heldKeys == [8, 55])
    #expect(controller.stateSnapshot.activeModifierRawValue == UInt64(cmdFlag))

    controller.inject(.releaseAll, displayBounds: secondaryBounds, nowNanoseconds: baseTime + 950_000_000)
    #expect(controller.stateSnapshot.heldButtons.isEmpty)
    #expect(controller.stateSnapshot.heldKeys.isEmpty)
    #expect(controller.stateSnapshot.activeModifierRawValue == 0)
    #expect(controller.stateSnapshot.currentClickState == 1)
}
#endif


@Test func sourceRestartBackoffGrowsThenCapsAtTenSeconds() {
    let seconds = (0..<8).map { SPPWSourceRestartPolicy.delayNanoseconds(attempt: $0) / 1_000_000_000 }
    #expect(seconds == [1, 2, 4, 8, 10, 10, 10, 10])
    #expect(SPPWSourceRestartPolicy.delayNanoseconds(attempt: -3) == 1_000_000_000)
}

@Test func streamingActivityBeginsAndEndsIdempotently() {
    let activity = SPPWStreamingActivity(reason: "PyrowaveKit test")
    #expect(!activity.isActive)
    activity.begin(keepDisplayAwake: false)
    #expect(activity.isActive)
    activity.begin(keepDisplayAwake: true) // replaces the assertion
    #expect(activity.isActive)
    activity.end()
    activity.end()
    #expect(!activity.isActive)
}

// MARK: - Resolution ladder

@Test func resolutionLadderDerivesSizesFromShortSideKeepingAspect() {
    func size(_ s: Int, _ w: Int, _ h: Int) -> String {
        let r = SPPWResolutionLadder.size(shortSide: s, native: (w, h))
        return "\(r.width)x\(r.height)"
    }
    // 16:9
    #expect(size(1440, 3840, 2160) == "2560x1440")
    #expect(size(480, 3840, 2160) == "854x480")
    #expect(size(320, 3840, 2160) == "568x320")
    // 16:10
    #expect(size(1080, 2560, 1600) == "1728x1080")
    // MacBook Pro 14"
    #expect(size(1080, 3024, 1964) == "1662x1080")
    // iPhone landscape and portrait: the short side is always the requested lines.
    #expect(size(720, 2556, 1179) == "1560x720")
    #expect(size(720, 1179, 2556) == "720x1560")
    // Never upscaled.
    #expect(size(2160, 2560, 1600) == "2560x1600")
    #expect(size(1600, 2560, 1600) == "2560x1600")
}

@Test func resolutionLadderResolvesWireRequests() {
    let native = (width: 3024, height: 1964)
    func resolve(_ w: Int, _ h: Int) -> String {
        let r = SPPWResolutionLadder.resolve(requestedWidth: w, requestedHeight: h, native: native)
        return "\(r.width)x\(r.height)"
    }
    #expect(resolve(0, 0) == "3024x1964")       // native
    #expect(resolve(0, 720) == "1108x720")      // short side
    #expect(resolve(1920, 1080) == "1662x1080") // legacy box, fitted keeping aspect
    #expect(resolve(8000, 8000) == "3024x1964") // never above native
    // Idempotent: resolving a resolved size returns it unchanged.
    #expect(resolve(1108, 720) == "1108x720")
    #expect(SPPWResolutionLadder.availableShortSides(nativeShortSide: 1179) == [1080, 720, 480, 360, 320])
}

@Test func resolutionModePersistsAndListsMenuOptions() {
    for mode in [SPPWResolutionMode.native, .automatic, .shortSide(720), .shortSide(320)] {
        #expect(SPPWResolutionMode(id: mode.id) == mode)
    }
    #expect(SPPWResolutionMode(id: "short:999") == .native)
    #expect(SPPWResolutionMode(id: "garbage") == .native)
    let options = SPPWResolutionMode.menuOptions(nativeShortSide: 1600)
    #expect(options.prefix(2) == [.native, .automatic])
    #expect(options.dropFirst(2).map { $0 } == [.shortSide(1440), .shortSide(1080), .shortSide(720), .shortSide(480), .shortSide(360), .shortSide(320)])
    #expect(SPPWResolutionMode.menuOptions(nativeShortSide: nil).count == 2 + SPPWResolutionLadder.shortSides.count)
}

@Test func autoResolutionStepsDownOnCongestionAndUpWithBackoff() {
    var controller = SPPWAutoResolutionController()
    var now: UInt64 = 0
    let native = 1440
    func tick(_ current: Int, _ ceiling: Int, seconds: Int) -> [SPPWAutoResolutionController.Change] {
        var changes: [SPPWAutoResolutionController.Change] = []
        for _ in 0..<seconds {
            now += 1_000_000_000
            let change = controller.evaluate(currentBitrateBps: current, ceilingBitrateBps: ceiling, nativeShortSide: native, now: now)
            if change != .none { changes.append(change) }
        }
        return changes
    }
    // Healthy at native: nothing happens.
    #expect(tick(100, 100, seconds: 5) == [])
    // Bitrate stuck below half the ceiling for 3 s: one level down (native -> 1080p).
    let down = tick(40, 100, seconds: 4)
    #expect(down == [.changed(1080)])
    // At the (new) ceiling for 15 s: probe one level up.
    #expect(tick(100, 100, seconds: 16) == [.changed(nil)])
    // Probe fails quickly -> down again, and the next probe waits twice as long (30 s).
    #expect(tick(30, 100, seconds: 4) == [.changed(1080)])
    #expect(tick(100, 100, seconds: 20) == [])
    #expect(tick(100, 100, seconds: 12) == [.changed(nil)])
    // Brief dips do not trigger anything.
    #expect(tick(40, 100, seconds: 2) == [])
    #expect(tick(100, 100, seconds: 1) == [])
}

@Test func autoResolutionPicksBestLevelForFixedBitrate() {
    let native = (width: 3840, height: 2160)
    // 3840x2160 @60 with quality 1 needs ~697 Mb/s; 20 Mb/s fits a low level only.
    let low = SPPWAutoResolutionController.bestShortSide(bitrateBps: 20_000_000, fps: 60, quality: 1, native: native)
    #expect(low != nil)
    #expect((low ?? 0) <= 480)
    #expect(SPPWAutoResolutionController.bestShortSide(bitrateBps: 1_000_000_000, fps: 60, quality: 1, native: native) == nil)
}

@Test func partialHFDecodeSucceedsWhenEncoderOmitsZeroLLChromaBlock59() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    // At 3840x2160, coarsestBandBlockCount = 12 (4x3). Component 1 (Cb) LL occupies
    // block indices 48..<60, so blockIndex 59 is the bottom-right Cb LL block.
    // Neutral chroma (Cb = Cr = 128) causes the encoder to omit zero LL chroma blocks.
    let width = 3840
    let height = 2160
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true
    ]
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs as CFDictionary, &created
    )
    let pixelBuffer = try #require(status == kCVReturnSuccess ? created : nil)

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let yBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    for row in 0..<height {
        let rowPtr = yBase + row * yStride
        for col in 0..<width {
            rowPtr[col] = UInt8(truncatingIfNeeded: (col / 8 + row / 8) & 0xFF)
        }
    }
    let uvBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)).assumingMemoryBound(to: UInt8.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
    for row in 0..<uvHeight {
        memset(uvBase + row * uvStride, 128, width)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let descriptor = try PyrowaveSessionDescriptor(
        width: width,
        height: height,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        videoSignal: VideoSignalMetadata(yCbCrRange: .full)
    )
    let encoder = try PyrowaveEncoderSession(descriptor: descriptor)
    let decoder = try PyrowaveDecoderSession(descriptor: descriptor)
    let encoded = try await encoder.encode(pixelBuffer)

    let datagrams = buildPacedFrameDatagrams(
        streamID: 77,
        frameID: 1,
        width: UInt16(width),
        height: UInt16(height),
        timestampNanoseconds: 1_000_000,
        bitstream: encoded.frame.data,
        payloadLimit: 1200,
        fecPercent: 0
    )
    #expect(datagrams.count >= 4)

    var assembler = SPPWFrameAssembler()
    for datagram in datagrams.dropLast() {
        #expect(assembler.ingest(datagram, timeoutMilliseconds: 50, allowPartialHFDecode: true) == nil)
    }
    let nextFirst = makeWireFragmentDatagram(
        streamID: 77,
        frameID: 2,
        flags: SPPWFragmentFlags.llCritical,
        width: UInt16(width),
        height: UInt16(height),
        fragmentIndex: 0,
        fragmentCount: 4,
        frameByteCount: 1000,
        timestampNanoseconds: 17_000_000,
        bitstream: encoded.frame.data,
        range: 0..<250
    )
    let salvagedCandidate = assembler.ingest(nextFirst, timeoutMilliseconds: 50, allowPartialHFDecode: true)
    let salvaged = try #require(salvagedCandidate)
    #expect(salvaged.isPartialHF)
    #expect(SPPWPyrowaveSubbandInspector.inspectContiguousPrefix(
        bitstream: salvaged.data,
        contiguousByteLength: salvaged.data.count
    ).hasCompleteLLSubband)

    // Previously threw: partial frame missing critical LL subband block 59
    let decoded = try await decoder.decode(EncodedFrame(data: salvaged.data), allowPartialFrame: true)
    #expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == width)
    #expect(CVPixelBufferGetHeight(decoded.pixelBuffer) == height)

    // Still rejects genuinely LL-truncated bitstreams (e.g. sequence header + first block only)
    let truncatedPrefixLen = SPPWPyrowaveSubbandInspector.validBlockAlignedPrefixLength(
        bitstream: encoded.frame.data,
        contiguousByteLength: min(encoded.frame.data.count, 128)
    )
    let truncatedLL = Data(encoded.frame.data.prefix(truncatedPrefixLen))
    do {
        _ = try await decoder.decode(EncodedFrame(data: truncatedLL), allowPartialFrame: true)
        Issue.record("Expected genuine LL-truncated bitstream to fail")
    } catch PyrowaveSessionError.recoverableFrameFailure {
        // Expected
    }
}

@Test func assemblerDropsPartialFrameWhenLateLLFragmentsAndFECAreLost() async throws {
    let source = try TestFrames.synthetic420(width: 640, height: 360)
    let descriptor = try PyrowaveSessionDescriptor(
        width: source.width,
        height: source.height,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        videoSignal: VideoSignalMetadata(yCbCrRange: .full)
    )
    let encoder = try PyrowaveEncoderSession(descriptor: descriptor)
    let encoded = try await encoder.encode(source.makeCVPixelBuffer())
    let boundary = try #require(SPPWPyrowaveSubbandInspector.inspect(encoded.frame.data))
    let payloadLimit = 256
    let datagrams = buildPacedFrameDatagrams(
        streamID: 88,
        frameID: 1,
        width: UInt16(source.width),
        height: UInt16(source.height),
        timestampNanoseconds: 1_000_000,
        bitstream: encoded.frame.data,
        payloadLimit: payloadLimit,
        fecPercent: 0
    )
    let llFragCount = boundary.llFragmentCount(payloadLimit: payloadLimit, totalFragments: datagrams.count)
    #expect(llFragCount >= 2)

    // Deliver only fragments [0 ..< llFragCount - 1]: the final LL fragment is lost
    // without FEC parity, so highestLLFragmentIndex stops at llFragCount - 2.
    var assembler = SPPWFrameAssembler()
    for datagram in datagrams.prefix(llFragCount - 1) {
        #expect(assembler.ingest(datagram, timeoutMilliseconds: 50, allowPartialHFDecode: true) == nil)
    }

    let nextFirst = makeWireFragmentDatagram(
        streamID: 88,
        frameID: 2,
        flags: SPPWFragmentFlags.llCritical,
        width: UInt16(source.width),
        height: UInt16(source.height),
        fragmentIndex: 0,
        fragmentCount: 4,
        frameByteCount: 1000,
        timestampNanoseconds: 17_000_000,
        bitstream: encoded.frame.data,
        range: 0..<250
    )

    let out = assembler.ingest(nextFirst, timeoutMilliseconds: 50, allowPartialHFDecode: true)
    #expect(out == nil)
    #expect(assembler.partialHFFrames == 0)
    #expect(assembler.llDroppedFrames == 1)
    #expect(assembler.droppedFrames == 1)
}


@Test func buildVersionFormattingIncludesCommitWhenProvided() {
    let formattedWithCommit = SPPWBuildVersion.formatted(version: "0.6.4", build: "604", commit: "c778763")
    #expect(formattedWithCommit == "v0.6.4 (build 604, c778763)")

    let formattedWithoutCommit = SPPWBuildVersion.formatted(version: "0.6.4", build: "604", commit: nil)
    #expect(formattedWithoutCommit == "v0.6.4 (build 604)")

    let formattedWithEmptyCommit = SPPWBuildVersion.formatted(version: "0.6.4", build: "604", commit: "  ")
    #expect(formattedWithEmptyCommit == "v0.6.4 (build 604)")

    let current = SPPWBuildVersion.current
    #expect(current.hasPrefix("v"))
    #expect(current.contains("build"))
}

