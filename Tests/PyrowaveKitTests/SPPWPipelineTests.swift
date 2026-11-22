import CoreVideo
import Darwin
import Foundation
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

    // Link degrades again immediately -> revert to stableBps (1st failure doubles cooldown to 20 s).
    t += sec
    let revert1 = abr.evaluate(SPPWAdaptiveBitrateSample(
        timestampNanoseconds: t,
        completeFramesDelta: 54,
        llDroppedFramesDelta: 1
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
        partialHFFramesDelta: 3
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
