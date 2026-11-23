import CoreGraphics
import Foundation
import Testing
@testable import SPPWCommon

// MARK: - Remote input wire events

@Test func remoteControlInputEventsRoundTrip() {
    let events: [SPPWInputEvent] = [
        .text("Ciao, 世界! 👋🏽"),
        .text(""),
        .keyPress(keyCode: SPPWMacKeyCode.upArrow, modifiers: SPPWKeyModifiers([.control]).rawValue),
        .pointerDelta(deltaX: -3.5, deltaY: 12.25),
        .buttonAtCursor(button: 1, isDown: true),
        .buttonAtCursor(button: 0, isDown: false),
        .clickAtCursor(button: 0),
        .sequenced(sequence: 65535, event: .text("你好")),
        .sequenced(sequence: 7, event: .clickAtCursor(button: 1))
    ]
    for event in events {
        let decoded = SPPWInputEvent.decode(from: event.encode())
        #expect(decoded == event, "round trip failed for \(event)")
    }
}

@Test func remoteControlInputEventByteLayouts() {
    #expect(SPPWInputEvent.keyPress(keyCode: 0x0102, modifiers: 0x0010_0000).encode()
        == Data([8, 0x01, 0x02, 0x00, 0x10, 0x00, 0x00]))
    #expect(SPPWInputEvent.buttonAtCursor(button: 1, isDown: true).encode() == Data([10, 1, 1]))
    #expect(SPPWInputEvent.clickAtCursor(button: 0).encode() == Data([11, 0]))
    #expect(SPPWInputEvent.text("é").encode() == Data([7, 0, 2, 0xC3, 0xA9]))
    #expect(SPPWInputEvent.pointerDelta(deltaX: 1, deltaY: -1).encode()
        == Data([9, 0x3F, 0x80, 0, 0, 0xBF, 0x80, 0, 0]))
    let sequenced = SPPWInputEvent.sequenced(sequence: 0x0A0B, event: .clickAtCursor(button: 2)).encode()
    #expect(sequenced == Data([12, 0x0A, 0x0B, 11, 2]))
}

@Test func remoteControlInputRejectsMalformedPayloads() {
    #expect(SPPWInputEvent.decode(from: Data([7, 0, 5, 0x61])) == nil)            // text shorter than length
    #expect(SPPWInputEvent.decode(from: Data([7, 0, 2, 0xC3, 0x28])) == nil)      // invalid UTF-8
    #expect(SPPWInputEvent.decode(from: Data([7, 0x04, 0x01] + [UInt8](repeating: 0x61, count: 1025))) == nil)
    #expect(SPPWInputEvent.decode(from: Data([8, 0, 1])) == nil)
    #expect(SPPWInputEvent.decode(from: Data([12, 0, 1, 12, 0, 2, 11, 0])) == nil) // nested envelope
    #expect(SPPWInputEvent.decode(from: Data([12, 0, 1])) == nil)
    #expect(SPPWInputEvent.decode(from: Data([99])) == nil)
}

@Test func remoteControlTextIsTruncatedOnCharacterBoundaries() {
    let long = String(repeating: "汉", count: 400) // 3 bytes each = 1200 bytes
    let encoded = SPPWInputEvent.text(long).encode()
    guard case let .text(decoded)? = SPPWInputEvent.decode(from: encoded) else {
        Issue.record("text did not decode")
        return
    }
    #expect(decoded.utf8.count <= SPPWInputEvent.maximumTextBytes)
    #expect(decoded == String(repeating: "汉", count: 341))
    let pieces = SPPWKeyboardTranslator.chunks(of: long)
    #expect(pieces.joined() == long)
    #expect(pieces.allSatisfy { $0.utf8.count <= SPPWInputEvent.maximumTextBytes })
}

@Test func remoteControlSequenceFilterDropsRedundantCopies() {
    var sequencer = SPPWInputSequencer(start: 65534)
    var filter = SPPWInputSequenceFilter()
    let first = sequencer.wrap(.text("a"))
    let second = sequencer.wrap(.keyPress(keyCode: 36, modifiers: 0))
    let third = sequencer.wrap(.clickAtCursor(button: 0)) // wraps past 65535
    #expect(filter.filter(first) == .text("a"))
    #expect(filter.filter(first) == nil)
    #expect(filter.filter(second) == .keyPress(keyCode: 36, modifiers: 0))
    #expect(filter.filter(third) == .clickAtCursor(button: 0))
    #expect(filter.filter(third) == nil)
    #expect(filter.filter(.pointerDelta(deltaX: 1, deltaY: 1)) == .pointerDelta(deltaX: 1, deltaY: 1))
    #expect(SPPWInputSequencer.needsRedundancy(.text("x")))
    #expect(!SPPWInputSequencer.needsRedundancy(.pointerDelta(deltaX: 1, deltaY: 0)))
}

// MARK: - Keyboard translation (IME text vs key codes)

@Test func keyboardTranslatorSendsCommittedTextAsUnicodeAndShortcutsAsKeyCodes() {
    // IME / composed text stays Unicode.
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "你好", modifiers: []) == [.text("你好")])
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "é", modifiers: []) == [.text("é")])
    // Shortcut modifiers turn a character into a virtual key code.
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "c", modifiers: .command)
        == [.keyPress(keyCode: 8, modifiers: SPPWKeyModifiers.command.rawValue)])
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "Z", modifiers: .command)
        == [.keyPress(keyCode: 6, modifiers: SPPWKeyModifiers([.command, .shift]).rawValue)])
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "?", modifiers: .control)
        == [.keyPress(keyCode: 44, modifiers: SPPWKeyModifiers([.control, .shift]).rawValue)])
    // Shift alone just uppercases; line breaks are Return.
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "a", modifiers: .shift) == [.text("A")])
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "\n", modifiers: [])
        == [.keyPress(keyCode: SPPWMacKeyCode.returnKey, modifiers: 0)])
    // Characters without an ANSI key stay text even with ⌘.
    #expect(SPPWKeyboardTranslator.events(forCommittedText: "ü", modifiers: .command) == [.text("ü")])
}

@Test func stickyModifiersOneShotAndLock() {
    var bar = SPPWStickyModifiers()
    bar.tap(.command)
    bar.lock(.shift)
    #expect(bar.state(of: .command) == .oneShot)
    #expect(bar.consume() == [.command, .shift])
    #expect(bar.state(of: .command) == .off)
    #expect(bar.consume() == .shift)
    bar.tap(.shift)
    #expect(bar.active.isEmpty)
    bar.tap(.control)
    bar.tap(.control)
    #expect(bar.active.isEmpty)
}

@Test func macKeyCodeTablesCoverHIDAndSpecialKeys() {
    #expect(SPPWMacKeyCode.fromHIDUsage(0x04) == 0)       // a
    #expect(SPPWMacKeyCode.fromHIDUsage(0x1D) == 6)       // z
    #expect(SPPWMacKeyCode.fromHIDUsage(0x27) == 29)      // 0
    #expect(SPPWMacKeyCode.fromHIDUsage(0x28) == 36)      // return
    #expect(SPPWMacKeyCode.fromHIDUsage(0x3A) == 122)     // F1
    #expect(SPPWMacKeyCode.fromHIDUsage(0x45) == 111)     // F12
    #expect(SPPWMacKeyCode.fromHIDUsage(0x52) == 126)     // up
    #expect(SPPWMacKeyCode.fromHIDUsage(0xE3) == 55)      // left GUI → command
    #expect(SPPWMacKeyCode.fromHIDUsage(0x64) == 10)      // ISO section
    #expect(SPPWMacKeyCode.fromHIDUsage(0x03) == nil)
    #expect(SPPWMacKeyCode.modifier(forKeyCode: 55) == .command)

    #expect(SPPWSpecialKey.copy.event(adding: []) == .keyPress(keyCode: 8, modifiers: SPPWKeyModifiers.command.rawValue))
    #expect(SPPWSpecialKey.redo.shortcutCaption == "⇧⌘Z")
    #expect(SPPWSpecialKey.missionControl.event(adding: [])
        == .keyPress(keyCode: SPPWMacKeyCode.upArrow, modifiers: SPPWKeyModifiers.control.rawValue))
    #expect(SPPWSpecialKey.left.event(adding: .shift)
        == .keyPress(keyCode: SPPWMacKeyCode.leftArrow, modifiers: SPPWKeyModifiers.shift.rawValue))
    #expect(SPPWSpecialKey.f12.keyCode == 111)
    #expect(SPPWMacKeyCode.implicitFlags(forKeyCode: SPPWMacKeyCode.upArrow) == 0x00A0_0000)
    #expect(SPPWMacKeyCode.implicitFlags(forKeyCode: 8) == 0)
}

@Test func pointerAccelerationScalesWithSpeedAndVelocity() {
    let slow = SPPWPointerAcceleration.scaled(deltaX: 2, deltaY: 0, elapsedSeconds: 0.016, speed: 5)
    let fast = SPPWPointerAcceleration.scaled(deltaX: 30, deltaY: 0, elapsedSeconds: 0.016, speed: 5)
    #expect(abs(slow.dx - 2 * 1.85) < 0.0001)
    #expect(fast.dx / 30 > slow.dx / 2)
    #expect(fast.dx / 30 <= 1.85 * 3.5 + 0.0001)
    let quiet = SPPWPointerAcceleration.scaled(deltaX: 2, deltaY: 0, elapsedSeconds: 0.016, speed: 1)
    #expect(quiet.dx < slow.dx)
}

@Test func uiKitPointMappingMatchesAppKitFlip() {
    let mapped = SPPWInputCoordinateMapper.mapUIKitPoint(
        viewX: 100, viewY: 5, viewWidth: 200, viewHeight: 100,
        videoWidth: 1920, videoHeight: 1080, orientation: SPPWVideoOrientation()
    )
    #expect(mapped != nil)
    #expect(abs((mapped?.normalizedX ?? 0) - 0.5) < 0.001)
    #expect((mapped?.normalizedY ?? 1) < 0.1)
}

// MARK: - Clipboard channel

@Test func clipboardMessagesRoundTripAndChunk() {
    let content = SPPWClipboardContent(text: String(repeating: "clipboard 剪贴板 ", count: 300))
    let chunks = SPPWClipboardMessage.chunks(for: content, transferID: 0xDEADBEEF, maxChunkBytes: 500)
    #expect(chunks.count == (content.data.count + 499) / 500)
    var reassembler = SPPWClipboardReassembler()
    var result: SPPWClipboardReassembler.Result = .pending
    for message in chunks.reversed() {
        let parsed = SPPWClipboardMessage(parsing: message.encoded())
        #expect(parsed == message)
        guard case let .chunk(id, format, index, count, total, bytes)? = parsed else { continue }
        result = reassembler.add(transferID: id, format: format, index: index, count: count, totalByteCount: total, bytes: bytes)
    }
    #expect(result == .complete(content))
    if case let .chunk(id, format, index, count, total, bytes) = chunks[0] {
        #expect(reassembler.add(transferID: id, format: format, index: index, count: count, totalByteCount: total, bytes: bytes) == .duplicate)
    }
    #expect(SPPWClipboardMessage(parsing: SPPWClipboardMessage.subscribe(enabled: true).encoded()) == .subscribe(enabled: true))
    #expect(SPPWClipboardMessage(parsing: SPPWClipboardMessage.ack(transferID: 42).encoded()) == .ack(transferID: 42))
    #expect(SPPWClipboardMessage.ack(transferID: 0x01020304).encoded()
        == Data([2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 0, 0, 0, 0]))
    #expect(SPPWClipboardMessage(parsing: Data([1, 9] + [UInt8](repeating: 0, count: 14))) == nil) // unknown format
    #expect(SPPWClipboardMessage(parsing: Data([1, 1, 0, 3, 0, 2] + [UInt8](repeating: 0, count: 10))) == nil) // index >= count
}

/// Two channels wired back to back through a lossy link: the first round drops every third chunk,
/// retransmission fills the holes, the ack stops retransmission, and echoes are suppressed.
@Test func clipboardChannelRecoversLossAndSuppressesEcho() async throws {
    final class Link: @unchecked Sendable {
        private let lock = NSLock()
        private var toB: [Data] = []
        private var toA: [Data] = []
        private var dropCounter = 0
        private var dropEveryThirdChunk = true

        func fromA(_ payload: Data) {
            lock.withLock {
                if dropEveryThirdChunk, payload.first == 1 {
                    dropCounter += 1
                    if dropCounter % 3 == 0 { return }
                }
                toB.append(payload)
            }
        }
        func fromB(_ payload: Data) { lock.withLock { toA.append(payload) } }
        func takeForB() -> [Data] {
            lock.withLock {
                defer { toB.removeAll() }
                if dropCounter > 30 { dropEveryThirdChunk = false }
                return toB
            }
        }
        func takeForA() -> [Data] { lock.withLock { defer { toA.removeAll() }; return toA } }
        var pendingForB: Int { lock.withLock { toB.count } }
    }
    let link = Link()
    let a = SPPWClipboardChannel(maxChunkBytes: 256, retransmitIntervalNanos: 50_000_000, maxAttempts: 5) { link.fromA($0) }
    let b = SPPWClipboardChannel(maxChunkBytes: 256) { link.fromB($0) }

    let image = SPPWClipboardContent(format: .png, data: Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
    #expect(a.offer(image))
    #expect(!a.offer(image)) // identical item is not resent

    var delivered: SPPWClipboardContent?
    for _ in 0..<60 where delivered == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
        for payload in link.takeForB() {
            if case let .content(content) = b.receive(payload) { delivered = content }
        }
    }
    #expect(delivered == image)

    // The ack reaches A and stops retransmission.
    let acks = link.takeForA()
    #expect(acks.contains { SPPWClipboardMessage(parsing: $0) != nil && $0.first == 2 })
    for ack in acks { _ = a.receive(ack) }
    _ = link.takeForB()
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(link.pendingForB == 0)

    // B now holds the item: offering it back (the pasteboard echo) is suppressed.
    #expect(!b.offer(image))
    #expect(b.offer(SPPWClipboardContent(text: "new")))
    a.cancel()
    b.cancel()
}

// MARK: - macOS injector state (no events posted)

@Test func macInputControllerTracksRelativePointerAndAtomicClicks() {
    let controller = SPPWMacInputController(postEvents: false)
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    controller.inject(.pointerMove(normalizedX: 0.5, normalizedY: 0.5), displayBounds: bounds)
    controller.inject(.pointerDelta(deltaX: 100, deltaY: -50), displayBounds: bounds)
    let moved = controller.lastInjectedCursorPoint
    #expect(abs((moved?.x ?? 0) - (499.5 + 100)) < 0.01)
    #expect(abs((moved?.y ?? 0) - (399.5 - 50)) < 0.01)
    controller.inject(.pointerDelta(deltaX: 5000, deltaY: 5000), displayBounds: bounds)
    #expect(controller.lastInjectedCursorPoint == CGPoint(x: 999, y: 799))

    controller.inject(.buttonAtCursor(button: 0, isDown: true), displayBounds: bounds, nowNanoseconds: 1_000)
    #expect(controller.stateSnapshot.heldButtons == [0])
    controller.inject(.sequenced(sequence: 1, event: .buttonAtCursor(button: 0, isDown: false)), displayBounds: bounds, nowNanoseconds: 2_000)
    #expect(controller.stateSnapshot.heldButtons.isEmpty)

    controller.inject(.clickAtCursor(button: 0), displayBounds: bounds, nowNanoseconds: 100_000_000)
    #expect(controller.stateSnapshot.heldButtons.isEmpty)
    #expect(controller.stateSnapshot.currentClickState == 2) // follows the press above within 500 ms
    controller.inject(.clickAtCursor(button: 0), displayBounds: bounds, nowNanoseconds: 2_000_000_000)
    #expect(controller.stateSnapshot.currentClickState == 1)
}

@Test func macTextSegmentsRespectUnicodeEventLimitAndLineBreaks() {
    let text = "Hello\n" + String(repeating: "👍🏽", count: 6) + "\tok"
    let segments = SPPWMacInputController.textSegments(text)
    #expect(segments.first == .unicode(Array("Hello".utf16)))
    #expect(segments[1] == .key(SPPWMacKeyCode.returnKey))
    for case let .unicode(units) in segments {
        #expect(units.count <= SPPWMacInputController.maximumUnicodeUnitsPerEvent)
    }
    // Emoji with skin tone (4 UTF-16 units) are never split across events.
    let emojiUnits = segments.compactMap { segment -> [UniChar]? in
        if case let .unicode(units) = segment, units.first != 72, units.first != 111 { return units }
        return nil
    }
    #expect(emojiUnits.allSatisfy { $0.count % 4 == 0 })
    #expect(segments.contains(.key(SPPWMacKeyCode.tab)))
    #expect(segments.last == .unicode(Array("ok".utf16)))
}

// MARK: - Host cursor visibility and fullscreen exit chord

@Test func remoteControlCursorVisibilityWireFormat() {
    #expect(SPPWInputEvent.cursorVisibility(hidden: true).encode() == Data([13, 1]))
    #expect(SPPWInputEvent.cursorVisibility(hidden: false).encode() == Data([13, 0]))
    for event: SPPWInputEvent in [
        .cursorVisibility(hidden: true),
        .sequenced(sequence: 42, event: .cursorVisibility(hidden: false)),
    ] {
        #expect(SPPWInputEvent.decode(from: event.encode()) == event)
    }
    #expect(SPPWInputEvent.decode(from: Data([13])) == nil)
    #expect(SPPWInputSequencer.needsRedundancy(.cursorVisibility(hidden: true)))
}

/// Steps for the chord detector: a modifier state, or `nil` for another key/click.
private func chordResults(_ steps: [SPPWKeyModifiers?]) -> [Bool] {
    var detector = SPPWModifierChordDetector()
    return steps.map { step in
        guard let step else {
            detector.otherInput()
            return false
        }
        return detector.modifiersChanged(step)
    }
}

@Test func remoteControlExitChordFiresOnCleanControlOption() {
    // ⌃ down, ⌥ down, ⌃ up, ⌥ up → fires once, on the last release.
    #expect(chordResults([[.control], [.control, .option], [.option], [], []])
        == [false, false, false, true, false])
    // Caps Lock does not interfere.
    #expect(chordResults([[.capsLock, .option, .control], [.capsLock]]) == [false, true])
}

@Test func remoteControlExitChordIgnoresShortcutsAndExtraModifiers() {
    // ⌃⌥ + key (a remote shortcut) never exits.
    #expect(chordResults([[.control, .option], nil, []]) == [false, false, false])
    // ⌃⌥⌘ is a different chord, even if ⌘ is released first.
    #expect(chordResults([[.control, .option, .command], [.control, .option], []]) == [false, false, false])
    // ⌃ alone does not fire.
    #expect(chordResults([[.control], []]) == [false, false])
    // A click with no modifier held does not spoil the next chord.
    #expect(chordResults([nil, [.option, .control], []]) == [false, false, true])
}

// MARK: - Rotated controls and zoom

@Test func remoteControlVideoDeltaFollowsRotationAndFlip() {
    // 0°: unchanged.
    #expect(SPPWVideoOrientation().videoDelta(screenDX: 3, screenDY: -2) == (3, -2))
    // 90° CW: the picture's top is on the screen's right, so a swipe right moves up.
    let quarter = SPPWVideoOrientation(quarterTurnsClockwise: 1)
    #expect(quarter.videoDelta(screenDX: 1, screenDY: 0) == (0, -1))
    #expect(quarter.videoDelta(screenDX: 0, screenDY: 1) == (1, 0))
    #expect(SPPWVideoOrientation(quarterTurnsClockwise: 2).videoDelta(screenDX: 1, screenDY: 2) == (-1, -2))
    #expect(SPPWVideoOrientation(quarterTurnsClockwise: 3).videoDelta(screenDX: 1, screenDY: 0) == (0, 1))
    // Mirror only flips the horizontal axis of the picture.
    #expect(SPPWVideoOrientation(isFlippedHorizontally: true).videoDelta(screenDX: 4, screenDY: 1) == (-4, 1))
}

@Test func remoteControlVideoDeltaMatchesAbsoluteMapping() {
    // A small screen motion must move the mapped video point the same way as the delta.
    for turns in 0..<4 {
        for flip in [false, true] {
            let orientation = SPPWVideoOrientation(quarterTurnsClockwise: turns, isFlippedHorizontally: flip)
            func map(_ x: Double, _ y: Double) -> SPPWInputCoordinateMapper.Result? {
                SPPWInputCoordinateMapper.mapUIKitPoint(
                    viewX: x, viewY: y, viewWidth: 800, viewHeight: 800,
                    videoWidth: 1000, videoHeight: 1000, orientation: orientation
                )
            }
            guard let a = map(400, 400), let b = map(410, 395) else {
                Issue.record("mapping failed")
                continue
            }
            let delta = orientation.videoDelta(screenDX: 10, screenDY: -5)
            let mappedDX = Double(b.normalizedX - a.normalizedX)
            let mappedDY = Double(b.normalizedY - a.normalizedY)
            #expect((mappedDX > 0) == (delta.dx > 0) || abs(delta.dx) < 0.001)
            #expect((mappedDY > 0) == (delta.dy > 0) || abs(delta.dy) < 0.001)
            #expect(abs(mappedDX * 800 - delta.dx) < 0.01 && abs(mappedDY * 800 - delta.dy) < 0.01)
        }
    }
}

@Test func remoteControlRotatedInsetsMoveWithTheVideo() {
    let screen = (top: 47.0, left: 0.0, bottom: 34.0, right: 10.0)
    #expect(SPPWVideoOrientation().rotatedInsets(top: screen.top, left: screen.left, bottom: screen.bottom, right: screen.right) == (47, 0, 34, 10))
    // 90° CW: the container's top edge lies on the screen's right edge.
    #expect(SPPWVideoOrientation(quarterTurnsClockwise: 1).rotatedInsets(top: screen.top, left: screen.left, bottom: screen.bottom, right: screen.right) == (10, 47, 0, 34))
    #expect(SPPWVideoOrientation(quarterTurnsClockwise: 2).rotatedInsets(top: screen.top, left: screen.left, bottom: screen.bottom, right: screen.right) == (34, 10, 47, 0))
    #expect(SPPWVideoOrientation(quarterTurnsClockwise: 3).rotatedInsets(top: screen.top, left: screen.left, bottom: screen.bottom, right: screen.right) == (0, 34, 10, 47))
}

@Test func remoteControlZoomClampsAndKeepsAnchor() {
    var zoom = SPPWViewZoom()
    #expect(!zoom.isZoomed)
    // Zooming about a point keeps the content under it in place.
    zoom.zoom(by: 1.5, anchorX: 300, anchorY: 200, viewWidth: 1000, viewHeight: 600)
    #expect(abs(zoom.scale - 1.5) < 1e-9)
    let anchored = zoom.contentPoint(viewX: 300, viewY: 200, viewWidth: 1000, viewHeight: 600)
    #expect(abs(anchored.x - 300) < 1e-9 && abs(anchored.y - 200) < 1e-9)
    // Never above 2× or below 1×.
    zoom.zoom(by: 10, anchorX: 500, anchorY: 300, viewWidth: 1000, viewHeight: 600)
    #expect(zoom.scale == SPPWViewZoom.maximumScale)
    zoom.zoom(by: 0.01, anchorX: 500, anchorY: 300, viewWidth: 1000, viewHeight: 600)
    #expect(zoom.scale == 1 && zoom.offsetX == 0 && zoom.offsetY == 0)
    // Panning stops at the content edge: no black margin.
    zoom.setScale(2, anchorX: 500, anchorY: 300, viewWidth: 1000, viewHeight: 600)
    zoom.pan(dx: 10_000, dy: -10_000, viewWidth: 1000, viewHeight: 600)
    #expect(zoom.offsetX == 500 && zoom.offsetY == -300)
    let corner = zoom.contentPoint(viewX: 0, viewY: 600, viewWidth: 1000, viewHeight: 600)
    #expect(abs(corner.x) < 1e-9 && abs(corner.y - 600) < 1e-9)
    // Smaller view after a rotation: the offset is clamped again.
    zoom.clampOffset(viewWidth: 600, viewHeight: 1000)
    #expect(zoom.offsetX == 300 && zoom.offsetY == -300)
}

@Test func remoteControlZoomFollowKeepsPointerMappingUnzoomed() {
    var zoom = SPPWViewZoom(scale: 1.8, viewWidth: 1200, viewHeight: 800)
    for (x, y) in [(0.0, 0.0), (1200.0, 800.0), (300.0, 650.0), (600.0, 400.0)] {
        zoom.follow(viewX: x, viewY: y, viewWidth: 1200, viewHeight: 800)
        let content = zoom.contentPoint(viewX: x, viewY: y, viewWidth: 1200, viewHeight: 800)
        #expect(abs(content.x - x) < 1e-9 && abs(content.y - y) < 1e-9)
    }
}

@Test func stillScreenRefreshWaitsForTheInterval() {
    let second = SPPWStillScreenPolicy.refreshIntervalNanoseconds
    #expect(!SPPWStillScreenPolicy.shouldRefresh(nowNanoseconds: 5 * second, lastSentNanoseconds: 0))
    #expect(!SPPWStillScreenPolicy.shouldRefresh(nowNanoseconds: 5 * second, lastSentNanoseconds: 5 * second - second / 2))
    #expect(SPPWStillScreenPolicy.shouldRefresh(nowNanoseconds: 5 * second, lastSentNanoseconds: 4 * second))
    #expect(second < 2_000_000_000, "must stay inside the receivers' 2 s fresh-frame watchdog")
}

@Test func stillScreenResyncRestartsOnlyADeadOrSilentSource() {
    let silent = SPPWStillScreenPolicy.resyncSilenceNanoseconds
    #expect(!SPPWStillScreenPolicy.resyncNeedsSourceRestart(geometryOrRateChanged: false, sourceRunning: true, captureSilenceNanoseconds: nil))
    #expect(!SPPWStillScreenPolicy.resyncNeedsSourceRestart(geometryOrRateChanged: false, sourceRunning: true, captureSilenceNanoseconds: silent - 1))
    #expect(SPPWStillScreenPolicy.resyncNeedsSourceRestart(geometryOrRateChanged: false, sourceRunning: true, captureSilenceNanoseconds: silent))
    #expect(SPPWStillScreenPolicy.resyncNeedsSourceRestart(geometryOrRateChanged: false, sourceRunning: false, captureSilenceNanoseconds: nil))
    #expect(SPPWStillScreenPolicy.resyncNeedsSourceRestart(geometryOrRateChanged: true, sourceRunning: true, captureSilenceNanoseconds: 0))
}

@Test func stillScreenStallNeedsRecentInteractionAndSpacing() {
    let stall = SPPWStillScreenPolicy.interactionStallNanoseconds
    #expect(SPPWStillScreenPolicy.isStalledWhileInteracting(captureSilenceNanoseconds: stall, sinceLastInteractionNanoseconds: 0, sinceLastStallRestartNanoseconds: nil))
    #expect(!SPPWStillScreenPolicy.isStalledWhileInteracting(captureSilenceNanoseconds: stall - 1, sinceLastInteractionNanoseconds: 0, sinceLastStallRestartNanoseconds: nil))
    #expect(!SPPWStillScreenPolicy.isStalledWhileInteracting(captureSilenceNanoseconds: stall, sinceLastInteractionNanoseconds: nil, sinceLastStallRestartNanoseconds: nil))
    #expect(!SPPWStillScreenPolicy.isStalledWhileInteracting(captureSilenceNanoseconds: stall, sinceLastInteractionNanoseconds: 0, sinceLastStallRestartNanoseconds: 1_000_000_000))
    #expect(SPPWStillScreenPolicy.isStalledWhileInteracting(captureSilenceNanoseconds: stall, sinceLastInteractionNanoseconds: 0, sinceLastStallRestartNanoseconds: SPPWStillScreenPolicy.minimumRestartSpacingNanoseconds))
}

@Test func inputThatChangesTheScreenExcludesPointerMotion() {
    #expect(SPPWInputEvent.clickAtCursor(button: 0).normallyChangesScreen)
    #expect(SPPWInputEvent.key(keyCode: 0, isDown: true, modifiers: 0).normallyChangesScreen)
    #expect(SPPWInputEvent.scroll(deltaX: 0, deltaY: 1).normallyChangesScreen)
    #expect(SPPWInputEvent.sequenced(sequence: 3, event: .text("a")).normallyChangesScreen)
    #expect(!SPPWInputEvent.pointerMove(normalizedX: 0.5, normalizedY: 0.5).normallyChangesScreen)
    #expect(!SPPWInputEvent.pointerDelta(deltaX: 1, deltaY: 1).normallyChangesScreen)
    #expect(!SPPWInputEvent.cursorVisibility(hidden: true).normallyChangesScreen)
}

@Test func localPointerViewPointInvertsTheTouchMapping() {
    for turns in 0..<4 {
        for flip in [false, true] {
            let orientation = SPPWVideoOrientation(quarterTurnsClockwise: turns, isFlippedHorizontally: flip)
            for (nx, ny) in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.75), (0.0, 1.0)] {
                guard let view = SPPWInputCoordinateMapper.uiKitViewPoint(
                    normalizedX: nx, normalizedY: ny,
                    viewWidth: 390, viewHeight: 844,
                    videoWidth: 1920, videoHeight: 1080,
                    orientation: orientation
                ), let back = SPPWInputCoordinateMapper.mapUIKitPoint(
                    viewX: view.x, viewY: view.y,
                    viewWidth: 390, viewHeight: 844,
                    videoWidth: 1920, videoHeight: 1080,
                    orientation: orientation,
                    clampOutside: true
                ) else {
                    Issue.record("mapping failed for turns \(turns) flip \(flip)")
                    continue
                }
                #expect(abs(Double(back.normalizedX) - nx) < 1e-4)
                #expect(abs(Double(back.normalizedY) - ny) < 1e-4)
            }
        }
    }
}

@Test func localPointerZoomViewPointInvertsContentPoint() {
    var zoom = SPPWViewZoom()
    zoom.setScale(1.7, anchorX: 120, anchorY: 300, viewWidth: 390, viewHeight: 844)
    let view = zoom.viewPoint(contentX: 200, contentY: 500, viewWidth: 390, viewHeight: 844)
    let back = zoom.contentPoint(viewX: view.x, viewY: view.y, viewWidth: 390, viewHeight: 844)
    #expect(abs(back.x - 200) < 1e-9)
    #expect(abs(back.y - 500) < 1e-9)
}

@Test func localPointerMovesAcrossTheShownPictureAndClamps() {
    var pointer = SPPWLocalPointer()
    let size = SPPWLocalPointer.displayedVideoSize(
        viewWidth: 844, viewHeight: 390, videoWidth: 1920, videoHeight: 1080,
        orientation: SPPWVideoOrientation()
    )!
    #expect(abs(size.height - 390) < 1e-9)
    pointer.move(videoDX: size.width / 4, videoDY: 0, displayedVideoWidth: size.width, displayedVideoHeight: size.height)
    #expect(abs(pointer.normalizedX - 0.75) < 1e-9)
    pointer.move(videoDX: size.width, videoDY: -size.height, displayedVideoWidth: size.width, displayedVideoHeight: size.height)
    #expect(pointer.normalizedX == 1)
    #expect(pointer.normalizedY == 0)
    #expect(pointer.moveEvent == .pointerMove(normalizedX: 1, normalizedY: 0))
    let rotated = SPPWLocalPointer.displayedVideoSize(
        viewWidth: 390, viewHeight: 844, videoWidth: 1920, videoHeight: 1080,
        orientation: SPPWVideoOrientation(quarterTurnsClockwise: 1, isFlippedHorizontally: false)
    )!
    #expect(abs(rotated.height - 390) < 1e-9)
    #expect(abs(rotated.width - 1920.0 * 390 / 1080) < 1e-9)
}
