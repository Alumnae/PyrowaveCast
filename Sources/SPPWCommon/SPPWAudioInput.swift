import AVFoundation
import CoreMedia
import Foundation
#if os(macOS)
import CoreGraphics
#endif

// MARK: - SPPW/1 Audio Framing (`WireMessageKind.audioFrame = 9`)

/// 8-byte header prepended to the payload of every `.audioFrame` (`kind == 9`) datagram,
/// followed by interleaved 16-bit signed little-endian PCM samples (`Int16`, 48 kHz stereo).
///
/// A 5 ms stereo frame at 48 kHz contains 240 sample frames = 480 `Int16` samples = 960 bytes,
/// fitting comfortably inside a single 1200-byte UDP datagram without fragmentation.
public struct SPPWAudioPacketHeader: Sendable, Equatable {
    public static let byteCount = 8
    public static let defaultSampleRate = 48_000
    public static let sampleRate = 48_000
    public static let defaultChannels: UInt8 = 2
    public static let channelCount = 2
    public static let chunkFrames = 240 // 5 ms at 48 kHz

    public let sequence: UInt32
    public let frameCount: UInt16
    public let channels: UInt8
    public let formatFlags: UInt8 // 0 = interleaved Int16 LE at 48 kHz

    public init(
        sequence: UInt32,
        frameCount: UInt16,
        channels: UInt8 = Self.defaultChannels,
        formatFlags: UInt8 = 0
    ) {
        self.sequence = sequence
        self.frameCount = frameCount
        self.channels = channels
        self.formatFlags = formatFlags
    }

    public init?(parsing payload: Data) {
        guard payload.count >= Self.byteCount else { return nil }
        let s = payload.startIndex
        let seq = (UInt32(payload[s]) << 24) |
                  (UInt32(payload[s + 1]) << 16) |
                  (UInt32(payload[s + 2]) << 8) |
                  UInt32(payload[s + 3])
        let frames = (UInt16(payload[s + 4]) << 8) | UInt16(payload[s + 5])
        let ch = payload[s + 6]
        let flags = payload[s + 7]
        guard frames > 0, ch >= 1, ch <= 2 else { return nil }
        self.sequence = seq
        self.frameCount = frames
        self.channels = ch
        self.formatFlags = flags
    }

    public init?(_ payload: Data) {
        self.init(parsing: payload)
    }

    public func encode(into data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: sequence >> 24))
        data.append(UInt8(truncatingIfNeeded: sequence >> 16))
        data.append(UInt8(truncatingIfNeeded: sequence >> 8))
        data.append(UInt8(truncatingIfNeeded: sequence))
        data.append(UInt8(truncatingIfNeeded: frameCount >> 8))
        data.append(UInt8(truncatingIfNeeded: frameCount))
        data.append(channels)
        data.append(formatFlags)
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.byteCount)
        encode(into: &data)
        return data
    }
}

/// Converts incoming `CMSampleBuffer` audio buffers (such as ScreenCaptureKit's `.audio` output)
/// into 5 ms (240-frame) stereo 48 kHz `Int16` SPPW/1 `.audioFrame` payloads.
public final class SPPWAudioPacketizer: @unchecked Sendable {
    public typealias PacketTuple = (sequence: UInt32, timestampNanoseconds: UInt64, payload: Data)

    private let lock = NSLock()
    private var nextSequence: UInt32 = 0
    /// Residual interleaved stereo `Int16` samples waiting to fill a 240-frame (480-sample) chunk.
    private var pendingStereoSamples: [Int16] = []

    public init() {
        pendingStereoSamples.reserveCapacity(SPPWAudioPacketHeader.chunkFrames * 4)
    }

    /// Extracts PCM samples from a `CMSampleBuffer` and returns zero or more ready 5 ms
    /// `(sequence, timestampNanoseconds, payload)` tuples (each with `SPPWAudioPacketHeader` + 960 bytes of PCM16).
    public func packetize(sampleBuffer: CMSampleBuffer) -> [PacketTuple] {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return []
        }

        let asbd = asbdPtr.pointee
        let totalFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard totalFrames > 0 else { return [] }

        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        var blockBuffer: CMBlockBuffer?

        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return [] }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard !buffers.isEmpty else { return [] }

        var newStereoSamples: [Int16] = []
        newStereoSamples.reserveCapacity(totalFrames * 2)

        if isFloat && bitsPerChannel == 32 {
            if isNonInterleaved {
                guard let leftPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return [] }
                let rightPtr = (buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? leftPtr
                for i in 0..<totalFrames {
                    newStereoSamples.append(Self.floatToInt16(leftPtr[i]))
                    newStereoSamples.append(Self.floatToInt16(rightPtr[i]))
                }
            } else {
                guard let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return [] }
                for i in 0..<totalFrames {
                    let l = ptr[i * channelCount]
                    let r = channelCount > 1 ? ptr[i * channelCount + 1] : l
                    newStereoSamples.append(Self.floatToInt16(l))
                    newStereoSamples.append(Self.floatToInt16(r))
                }
            }
        } else if !isFloat && bitsPerChannel == 16 {
            if isNonInterleaved {
                guard let leftPtr = buffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return [] }
                let rightPtr = (buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Int16.self) : nil) ?? leftPtr
                for i in 0..<totalFrames {
                    newStereoSamples.append(leftPtr[i])
                    newStereoSamples.append(rightPtr[i])
                }
            } else {
                guard let ptr = buffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return [] }
                for i in 0..<totalFrames {
                    let l = ptr[i * channelCount]
                    let r = channelCount > 1 ? ptr[i * channelCount + 1] : l
                    newStereoSamples.append(l)
                    newStereoSamples.append(r)
                }
            }
        } else {
            return []
        }

        let chunkSampleCount = SPPWAudioPacketHeader.chunkFrames * 2 // 480 Int16 values
        var packets: [PacketTuple] = []

        lock.lock()
        pendingStereoSamples.append(contentsOf: newStereoSamples)
        while pendingStereoSamples.count >= chunkSampleCount {
            let seq = nextSequence
            nextSequence &+= 1
            let tsNanos = DispatchTime.now().uptimeNanoseconds

            let header = SPPWAudioPacketHeader(
                sequence: seq,
                frameCount: UInt16(SPPWAudioPacketHeader.chunkFrames),
                channels: 2
            )
            var payload = Data(capacity: SPPWAudioPacketHeader.byteCount + chunkSampleCount * 2)
            header.encode(into: &payload)
            pendingStereoSamples.withUnsafeBufferPointer { buf in
                let rawPtr = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self)
                payload.append(rawPtr, count: chunkSampleCount * 2)
            }
            pendingStereoSamples.removeFirst(chunkSampleCount)
            packets.append((sequence: seq, timestampNanoseconds: tsNanos, payload: payload))
        }
        lock.unlock()

        return packets
    }

    @inline(__always)
    private static func floatToInt16(_ sample: Float) -> Int16 {
        let clamped = min(max(sample, -1.0), 1.0)
        return Int16((clamped * 32767.0).rounded())
    }
}

// MARK: - Low-Latency AVAudioEngine Playout for iOS & macOS Receivers

/// Low-latency 48 kHz stereo `AVAudioEngine` + `AVAudioPlayerNode` receiver output
/// with automatic drift capping so queued Wi-Fi audio never exceeds ~45 ms of latency
/// and automatic idle pause after 3 s of silence so CoreAudio stops waking at 200 Hz
/// when no audio packets arrive.
public final class SPPWAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioFormat: AVAudioFormat
    private let lock = NSLock()
    private let idleQueue = DispatchQueue(label: "it.screenspan.pyrowave.audio.idle", qos: .utility)
    private var idlePauseWorkItem: DispatchWorkItem?
    private var lastAudioEnqueueNanos: UInt64 = 0
    private let idlePauseThresholdNanos: UInt64 = 3_000_000_000
    private var isRunning = false
    #if os(iOS)
    private var sessionActivated = false
    #endif
    private var scheduledBuffersInFlight = 0
    /// Maximum 5 ms buffers allowed in flight (9 * 5 ms = 45 ms max audio buffer).
    private let maxInFlightBuffers = 9
    private var _isMuted: Bool = false

    public var isMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMuted
        }
        set {
            lock.lock()
            _isMuted = newValue
            if newValue && isRunning {
                pauseEngineLocked()
            }
            lock.unlock()
        }
    }

    public init() {
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(SPPWAudioPacketHeader.defaultSampleRate),
            channels: AVAudioChannelCount(SPPWAudioPacketHeader.defaultChannels),
            interleaved: false
        )!
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
    }

    public func start() {
        lock.lock()
        startLocked()
        lock.unlock()
    }

    private func startLocked() {
        guard !isRunning else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        sessionActivated = true
        #endif

        do {
            try engine.start()
            playerNode.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    private func pauseEngineLocked() {
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil
        guard isRunning else { return }
        playerNode.stop()
        engine.pause()
        scheduledBuffersInFlight = 0
        isRunning = false
    }

    private func scheduleIdlePauseLocked(afterSeconds delay: TimeInterval) {
        guard idlePauseWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.idlePauseWorkItem = nil
            guard self.isRunning else {
                self.lock.unlock()
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= self.lastAudioEnqueueNanos ? (now - self.lastAudioEnqueueNanos) : 0
            if elapsed >= self.idlePauseThresholdNanos && self.scheduledBuffersInFlight == 0 {
                self.pauseEngineLocked()
                self.lock.unlock()
                return
            }
            let remainingNanos = elapsed < self.idlePauseThresholdNanos
                ? (self.idlePauseThresholdNanos - elapsed)
                : 500_000_000
            let nextDelay = max(0.5, Double(remainingNanos) / 1_000_000_000.0)
            self.scheduleIdlePauseLocked(afterSeconds: nextDelay)
            self.lock.unlock()
        }
        idlePauseWorkItem = item
        idleQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func stop() {
        lock.lock()
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil
        let wasRunning = isRunning
        #if os(iOS)
        let wasSessionActive = sessionActivated
        sessionActivated = false
        #endif
        if wasRunning {
            playerNode.stop()
            engine.stop()
            scheduledBuffersInFlight = 0
            isRunning = false
        }
        lock.unlock()

        #if os(iOS)
        if wasSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif
    }

    /// Decodes an incoming `.audioFrame` (`kind == 9`) payload and schedules it for immediate playout.
    public func enqueue(audioPayload: Data) {
        guard !isMuted,
              let header = SPPWAudioPacketHeader(parsing: audioPayload) else {
            return
        }
        let frameCount = Int(header.frameCount)
        let channels = Int(header.channels)
        let expectedPCMBytes = frameCount * channels * MemoryLayout<Int16>.size
        guard audioPayload.count >= SPPWAudioPacketHeader.byteCount + expectedPCMBytes else {
            return
        }

        let nowNanos = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard !_isMuted else {
            lock.unlock()
            return
        }
        lastAudioEnqueueNanos = nowNanos
        if !isRunning {
            startLocked()
        }
        guard isRunning else {
            lock.unlock()
            return
        }
        scheduleIdlePauseLocked(afterSeconds: 3.0)
        if scheduledBuffersInFlight >= maxInFlightBuffers {
            // Drop excess audio chunk if Wi-Fi burst delivered > 45 ms at once.
            lock.unlock()
            return
        }
        scheduledBuffersInFlight += 1
        lock.unlock()

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let floatChannels = pcmBuffer.floatChannelData else {
            lock.lock()
            scheduledBuffersInFlight = max(0, scheduledBuffersInFlight - 1)
            lock.unlock()
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let leftOut = floatChannels[0]
        let rightOut = floatChannels[1]
        let scale: Float = 1.0 / 32768.0

        audioPayload.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let samplesPtr = base.advanced(by: SPPWAudioPacketHeader.byteCount)
                .assumingMemoryBound(to: Int16.self)
            if channels >= 2 {
                for i in 0..<frameCount {
                    leftOut[i] = Float(Int16(littleEndian: samplesPtr[i * 2])) * scale
                    rightOut[i] = Float(Int16(littleEndian: samplesPtr[i * 2 + 1])) * scale
                }
            } else {
                for i in 0..<frameCount {
                    let sample = Float(Int16(littleEndian: samplesPtr[i])) * scale
                    leftOut[i] = sample
                    rightOut[i] = sample
                }
            }
        }

        playerNode.scheduleBuffer(pcmBuffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduledBuffersInFlight = max(0, self.scheduledBuffersInFlight - 1)
            self.lock.unlock()
        }
    }

    /// Alias for `enqueue(audioPayload:)`.
    public func enqueueAudioPayload(_ payload: Data) {
        enqueue(audioPayload: payload)
    }

    deinit {
        stop()
    }
}

// MARK: - SPPW/1 Remote Input Channel (`WireMessageKind.input = 4`)

public enum SPPWTouchPhase: UInt8, Sendable {
    case began = 0
    case moved = 1
    case ended = 2
    case cancelled = 3
}

public struct SPPWTouchPoint: Sendable, Equatable {
    public let id: UInt32
    public let phase: UInt8
    public let normalizedX: Float
    public let normalizedY: Float

    public init(id: UInt32, phase: UInt8, normalizedX: Float, normalizedY: Float) {
        self.id = id
        self.phase = phase
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
    }

    public init(id: UInt32, phase: SPPWTouchPhase, normalizedX: Float, normalizedY: Float) {
        self.init(id: id, phase: phase.rawValue, normalizedX: normalizedX, normalizedY: normalizedY)
    }
}

/// Binary remote-input event carried inside `.input` (`kind == 4`) datagrams.
/// Coordinates `normalizedX` and `normalizedY` are normalized in $[0, 1]$ relative to the video frame.
public enum SPPWInputEvent: Sendable, Equatable {
    case pointerMove(normalizedX: Float, normalizedY: Float)
    case mouseButton(button: UInt8, isDown: Bool, normalizedX: Float, normalizedY: Float)
    case scroll(deltaX: Float, deltaY: Float)
    case key(keyCode: UInt16, isDown: Bool, modifiers: UInt32)
    case touch([SPPWTouchPoint])

    private enum Tag: UInt8 {
        case pointerMove = 1
        case mouseButton = 2
        case scroll = 3
        case key = 4
        case touch = 5
    }

    public func encoded() -> Data {
        var data = Data(capacity: 24)
        switch self {
        case let .pointerMove(x, y):
            data.append(Tag.pointerMove.rawValue)
            Self.appendFloat(x, to: &data)
            Self.appendFloat(y, to: &data)
        case let .mouseButton(button, isDown, x, y):
            data.append(Tag.mouseButton.rawValue)
            data.append(button)
            data.append(isDown ? 1 : 0)
            Self.appendFloat(x, to: &data)
            Self.appendFloat(y, to: &data)
        case let .scroll(dx, dy):
            data.append(Tag.scroll.rawValue)
            Self.appendFloat(dx, to: &data)
            Self.appendFloat(dy, to: &data)
        case let .key(keyCode, isDown, modifiers):
            data.append(Tag.key.rawValue)
            data.append(UInt8(truncatingIfNeeded: keyCode >> 8))
            data.append(UInt8(truncatingIfNeeded: keyCode))
            data.append(isDown ? 1 : 0)
            Self.appendU32(modifiers, to: &data)
        case let .touch(points):
            data.append(Tag.touch.rawValue)
            let clampedCount = min(points.count, 16)
            data.append(UInt8(clamping: clampedCount))
            for pt in points.prefix(clampedCount) {
                Self.appendU32(pt.id, to: &data)
                data.append(pt.phase)
                Self.appendFloat(pt.normalizedX, to: &data)
                Self.appendFloat(pt.normalizedY, to: &data)
            }
        }
        return data
    }

    /// Alias for `encoded()` used by `ReceiverModel`, `IOSReceiverModel`, and tests.
    public func encode() -> Data {
        encoded()
    }

    public init?(parsing payload: Data) {
        guard let firstByte = payload.first,
              let tag = Tag(rawValue: firstByte) else {
            return nil
        }
        let s = payload.startIndex
        switch tag {
        case .pointerMove:
            guard payload.count >= 9 else { return nil }
            self = .pointerMove(
                normalizedX: Self.readFloat(payload, at: s + 1),
                normalizedY: Self.readFloat(payload, at: s + 5)
            )
        case .mouseButton:
            guard payload.count >= 11 else { return nil }
            self = .mouseButton(
                button: payload[s + 1],
                isDown: payload[s + 2] != 0,
                normalizedX: Self.readFloat(payload, at: s + 3),
                normalizedY: Self.readFloat(payload, at: s + 7)
            )
        case .scroll:
            guard payload.count >= 9 else { return nil }
            self = .scroll(
                deltaX: Self.readFloat(payload, at: s + 1),
                deltaY: Self.readFloat(payload, at: s + 5)
            )
        case .key:
            guard payload.count >= 8 else { return nil }
            let code = (UInt16(payload[s + 1]) << 8) | UInt16(payload[s + 2])
            let isDown = payload[s + 3] != 0
            let mods = Self.readU32(payload, at: s + 4)
            self = .key(keyCode: code, isDown: isDown, modifiers: mods)
        case .touch:
            guard payload.count >= 2 else { return nil }
            let count = Int(payload[s + 1])
            let entrySize = 13 // 4-byte id + 1-byte phase + 4-byte x + 4-byte y
            guard count >= 0, count <= 16, payload.count >= 2 + count * entrySize else { return nil }
            var points: [SPPWTouchPoint] = []
            points.reserveCapacity(count)
            for idx in 0..<count {
                let offset = s + 2 + idx * entrySize
                let id = Self.readU32(payload, at: offset)
                let phase = payload[offset + 4]
                let x = Self.readFloat(payload, at: offset + 5)
                let y = Self.readFloat(payload, at: offset + 9)
                points.append(SPPWTouchPoint(id: id, phase: phase, normalizedX: x, normalizedY: y))
            }
            self = .touch(points)
        }
    }

    public static func decode(from payload: Data) -> SPPWInputEvent? {
        SPPWInputEvent(parsing: payload)
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        appendU32(value.bitPattern, to: &data)
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
        (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) |
        UInt32(data[offset + 3])
    }

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        Float(bitPattern: readU32(data, at: offset))
    }
}

#if os(macOS)
/// Injects received `SPPWInputEvent` payloads into the macOS WindowServer via `CGEvent`.
public enum SPPWMacInputInjector {
    public static func inject(_ event: SPPWInputEvent, displayID: CGDirectDisplayID = CGMainDisplayID()) {
        let bounds = CGDisplayBounds(displayID)
        let width = max(bounds.width, 1.0)
        let height = max(bounds.height, 1.0)

        @inline(__always)
        func screenPoint(nx: Float, ny: Float) -> CGPoint {
            let clampedX = CGFloat(min(max(nx, 0.0), 1.0))
            let clampedY = CGFloat(min(max(ny, 0.0), 1.0))
            return CGPoint(
                x: bounds.origin.x + clampedX * width,
                y: bounds.origin.y + clampedY * height
            )
        }

        switch event {
        case let .pointerMove(nx, ny):
            let pt = screenPoint(nx: nx, ny: ny)
            if let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: pt,
                mouseButton: .left
            ) {
                cgEvent.post(tap: .cghidEventTap)
            }

        case let .mouseButton(button, isDown, nx, ny):
            let pt = screenPoint(nx: nx, ny: ny)
            let mouseType: CGEventType
            let cgButton: CGMouseButton
            switch button {
            case 1:
                cgButton = .right
                mouseType = isDown ? .rightMouseDown : .rightMouseUp
            case 2:
                cgButton = .center
                mouseType = isDown ? .otherMouseDown : .otherMouseUp
            default:
                cgButton = .left
                mouseType = isDown ? .leftMouseDown : .leftMouseUp
            }
            if let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: mouseType,
                mouseCursorPosition: pt,
                mouseButton: cgButton
            ) {
                cgEvent.post(tap: .cghidEventTap)
            }

        case let .scroll(dx, dy):
            if let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(dy.rounded()),
                wheel2: Int32(dx.rounded()),
                wheel3: 0
            ) {
                cgEvent.post(tap: .cghidEventTap)
            }

        case let .key(keyCode, isDown, modifiers):
            if let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: isDown
            ) {
                if modifiers != 0 {
                    cgEvent.flags = CGEventFlags(rawValue: UInt64(modifiers))
                }
                cgEvent.post(tap: .cghidEventTap)
            }

        case let .touch(points):
            guard let primary = points.first else { return }
            let pt = screenPoint(nx: primary.normalizedX, ny: primary.normalizedY)
            let type: CGEventType
            switch SPPWTouchPhase(rawValue: primary.phase) ?? .moved {
            case .began: type = .leftMouseDown
            case .moved: type = .leftMouseDragged
            case .ended, .cancelled: type = .leftMouseUp
            }
            if let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: pt,
                mouseButton: .left
            ) {
                cgEvent.post(tap: .cghidEventTap)
            }
        }
    }
}
#endif
