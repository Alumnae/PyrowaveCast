import Foundation
import Testing
@testable import SPPWCommon

// MARK: - Adaptive bitrate on Wi-Fi

@Test func adaptiveBitrateIgnoresIsolatedWiFiBlipsButReactsToPersistentLoss() {
    let sec: UInt64 = 1_000_000_000
    var t: UInt64 = 10 * sec
    var abr = SPPWAdaptiveBitrateController(ceilingBitrateBps: 100_000_000, nowNanoseconds: t)

    // One lost frame every 5 s (isolated Wi-Fi blips) never cuts the bitrate.
    for second in 1...30 {
        t += sec
        let blip = second % 5 == 0
        let decision = abr.evaluate(SPPWAdaptiveBitrateSample(
            timestampNanoseconds: t,
            completeFramesDelta: blip ? 59 : 60,
            llDroppedFramesDelta: blip ? 1 : 0,
            jitterMs: 6
        ))
        #expect(decision == .hold)
    }
    #expect(abr.currentBitrateBps == 100_000_000)

    // Isolated partial-HF frames are blips too (after a few clean seconds).
    for _ in 0..<3 {
        t += sec
        #expect(abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) == .hold)
    }
    t += sec
    #expect(abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60, partialHFFramesDelta: 2)) == .hold)

    // Loss in two windows within 3 s is congestion: step down, gently (-20 %).
    t += sec
    let step = abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 59, llDroppedFramesDelta: 1))
    #expect(step == .stepDown(newBitrateBps: 80_000_000, reason: "LL drop: 1"))

    // Heavy loss in one window steps down at once.
    var fresh = SPPWAdaptiveBitrateController(ceilingBitrateBps: 100_000_000, nowNanoseconds: 10 * sec)
    guard case .stepDown = fresh.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: 11 * sec, completeFramesDelta: 56, expiredFramesDelta: 4)) else {
        Issue.record("heavy loss must step down immediately")
        return
    }
}

@Test func adaptiveBitrateClimbsBackFasterFromFarBelowTheCeiling() {
    let sec: UInt64 = 1_000_000_000
    var t: UInt64 = 10 * sec
    var abr = SPPWAdaptiveBitrateController(ceilingBitrateBps: 100_000_000, nowNanoseconds: t)
    // Several heavy-loss seconds push it far down.
    for _ in 0..<5 {
        t += sec
        _ = abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 50, llDroppedFramesDelta: 6))
    }
    let low = abr.currentBitrateBps
    #expect(low < 50_000_000)
    for _ in 0..<9 {
        t += sec
        #expect(abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) == .hold)
    }
    t += sec
    guard case let .probeUp(next) = abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60)) else {
        Issue.record("expected a probe after 10 clean seconds")
        return
    }
    #expect(next >= Int(Double(low) * 1.25))
}

@Test func adaptiveBitrateReleasesALockedCeilingAfterTwoCleanMinutes() {
    let sec: UInt64 = 1_000_000_000
    var t: UInt64 = 10 * sec
    var abr = SPPWAdaptiveBitrateController(ceilingBitrateBps: 120_000_000, nowNanoseconds: t)
    func clean() -> SPPWAdaptiveBitrateDecision {
        t += sec
        return abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 60))
    }
    func heavy() -> SPPWAdaptiveBitrateDecision {
        t += sec
        return abr.evaluate(SPPWAdaptiveBitrateSample(timestampNanoseconds: t, completeFramesDelta: 54, llDroppedFramesDelta: 3))
    }
    _ = heavy()
    for _ in 0..<10 { _ = clean() }
    _ = heavy()                                  // 1st failed probe
    for _ in 0..<20 { _ = clean() }
    _ = heavy()                                  // 2nd failed probe -> locked
    #expect(abr.isCeilingLocked)
    let locked = abr.currentBitrateBps
    var probed = false
    for _ in 0..<150 {
        if case .probeUp = clean() { probed = true; break }
    }
    #expect(!abr.isCeilingLocked)
    #expect(probed)
    #expect(abr.currentBitrateBps > locked)
}

// MARK: - Audio jitter buffer on Wi-Fi

@Test func audioJitterAllowanceGrowsWithArrivalSpikesAndDecays() {
    var controller = SPPWAudioJitterController(minimumQueueNanos: 30_000_000)
    let offset: Int64 = 9_000_000_000 // unknown clock offset between devices
    for _ in 0..<200 { controller.noteArrival(transitNanos: offset + 4_000_000) }
    #expect(controller.networkAllowanceNanos == 0)
    #expect(controller.effectiveMinimumQueueNanos == 30_000_000)

    // A 60 ms Wi-Fi stall: the buffer floor rises to cover it.
    controller.noteArrival(transitNanos: offset + 64_000_000)
    #expect(abs(controller.networkAllowanceNanos - 60_000_000) < 1_000_000)
    #expect(controller.effectiveMinimumQueueNanos >= 89_000_000)

    // A starved queue now refills to the higher floor (fewer repeated starvations).
    let refill = controller.decide(queuedNanos: 0, latenessNanos: nil, now: 1_000_000_000)
    guard case let .delay(frames) = refill else {
        Issue.record("expected a refill")
        return
    }
    #expect(frames >= SPPWAudioJitterController.frames(85_000_000))

    // 15 s of calm arrivals (≈ 4 s half-life): the allowance decays back down.
    for _ in 0..<3_000 { controller.noteArrival(transitNanos: offset + 4_000_000) }
    #expect(controller.networkAllowanceNanos < 6_000_000)

    // Spikes are capped.
    controller.noteArrival(transitNanos: offset + 900_000_000)
    #expect(controller.networkAllowanceNanos == controller.maximumNetworkAllowanceNanos)
}

@Test func audioConcealmentFadesThePreviousPacketAndFadeInRamps() {
    let last = [Float](repeating: 0.5, count: 240)
    let filler = SPPWAudioPlayer.concealmentSamples(lastLeft: last, lastRight: last, frames: 600)
    #expect(filler.left.count == 600)
    #expect(filler.left[0] > 0.49)
    #expect(filler.left[239] < 0.01)
    #expect(filler.left[239] > 0)
    #expect(filler.left[240...].allSatisfy { $0 == 0 })
    #expect(zip(filler.left[0..<240], filler.left[1..<240]).allSatisfy { $0 >= $1 })
    #expect(SPPWAudioPlayer.concealmentSamples(lastLeft: [], lastRight: [], frames: 10).left == [Float](repeating: 0, count: 10))

    var samples = [Float](repeating: 1, count: 240)
    samples.withUnsafeMutableBufferPointer {
        SPPWAudioPlayer.applyFadeIn($0.baseAddress!, count: 240, rampFrames: SPPWAudioPlayer.fadeInFrames)
    }
    #expect(samples[0] < 0.02)
    #expect(samples[95] < 1 && samples[95] > 0.98)
    #expect(samples[96...].allSatisfy { $0 == 1 })
}

@Test func pacerFinishesSlightlyLateFramesButDropsBacklog() {
    let now = mach_absolute_time()
    #expect(SPPWMediaPacer.shouldFlushSupersededFrame(startMach: now, frameIntervalNanos: 16_666_667))
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let fiftyMsMach = UInt64(50_000_000) * UInt64(info.denom) / UInt64(info.numer)
    #expect(!SPPWMediaPacer.shouldFlushSupersededFrame(startMach: now &- fiftyMsMach, frameIntervalNanos: 16_666_667))
}
