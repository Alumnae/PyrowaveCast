import AVFoundation
import CoreMedia
import Foundation
#if os(macOS)
import ApplicationServices
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

// MARK: - Shared capture clock (audio/video sync)

/// The clock every SPPW/1 media timestamp (`senderTimestampNanoseconds`) is expressed in:
/// monotonic `mach_absolute_time` uptime in nanoseconds, i.e. `DispatchTime.now().uptimeNanoseconds`.
///
/// Servers stamp video frames and audio packets with the instant they were *captured*
/// (not encoded or sent), so a receiver can line both streams up on one timeline.
/// ScreenCaptureKit and ReplayKit deliver sample buffers whose presentation timestamps
/// are on the host time clock (`CMClockGetHostTimeClock`, also `mach_absolute_time`).
public enum SPPWCaptureClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Largest accepted distance between a sample buffer timestamp and "now"; anything
    /// further away is not on the host clock (e.g. a media file timeline) and is ignored.
    public static let maximumSkewNanoseconds: UInt64 = 2_000_000_000

    public static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Converts a host-clock `CMTime` to capture-clock nanoseconds, or `nil` when the time is
    /// invalid or clearly not on the host clock.
    public static func nanoseconds(fromHostTime time: CMTime, now: UInt64 = nowNanoseconds()) -> UInt64? {
        guard time.isValid, time.isNumeric else { return nil }
        let ticks = CMClockConvertHostTimeToSystemUnits(time)
        let nanos = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !nanos.overflow, timebase.denom > 0 else { return nil }
        let value = nanos.partialValue / UInt64(timebase.denom)
        let distance = value > now ? value - now : now - value
        return distance <= maximumSkewNanoseconds ? value : nil
    }

    /// Converts `mach_absolute_time` ticks (e.g. `AVAudioTime.hostTime`) to capture-clock nanoseconds.
    public static func nanoseconds(fromHostTicks ticks: UInt64) -> UInt64 {
        let nanos = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !nanos.overflow, timebase.denom > 0 else { return nowNanoseconds() }
        return nanos.partialValue / UInt64(timebase.denom)
    }

    /// Capture instant of a sample buffer, falling back to "now" when it carries no usable
    /// host-clock timestamp.
    public static func captureNanoseconds(of sampleBuffer: CMSampleBuffer) -> UInt64 {
        let now = nowNanoseconds()
        return nanoseconds(fromHostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), now: now) ?? now
    }
}

/// Converts incoming `CMSampleBuffer` audio buffers (such as ScreenCaptureKit's `.audio` output)
/// into 5 ms (240-frame) stereo 48 kHz `Int16` SPPW/1 `.audioFrame` payloads.
///
/// Every packet's timestamp is the capture instant of its first sample (see `SPPWCaptureClock`).
/// Sources that are not already 48 kHz native-endian Float32/Int16 (ReplayKit `.audioApp` is
/// commonly 44.1 kHz, sometimes big-endian or mono) go through an `AVAudioConverter`.
public final class SPPWAudioPacketizer: @unchecked Sendable {
    public typealias PacketTuple = (sequence: UInt32, timestampNanoseconds: UInt64, payload: Data)

    private let lock = NSLock()
    private var nextSequence: UInt32 = 0
    /// Residual interleaved stereo `Int16` samples waiting to fill a 240-frame (480-sample) chunk.
    private var pendingStereoSamples: [Int16] = []
    /// Cached converter for sources that need resampling / format conversion.
    private var converter: AVAudioConverter?
    private var converterSourceDescription: AudioStreamBasicDescription?
    private static let nanosecondsPerFrame = 1_000_000_000.0 / Double(SPPWAudioPacketHeader.sampleRate)

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

        let bufferCaptureNanos = SPPWCaptureClock.captureNanoseconds(of: sampleBuffer)
        let newStereoSamples: [Int16]
        if Self.isFastPathFormat(asbd) {
            guard let samples = Self.extractStereoInt16(sampleBuffer, asbd: asbd, totalFrames: totalFrames) else {
                return []
            }
            newStereoSamples = samples
        } else {
            lock.lock()
            let converted = convertToStereo48k(sampleBuffer, asbd: asbd, totalFrames: totalFrames)
            lock.unlock()
            guard let converted else { return [] }
            newStereoSamples = converted
        }
        return appendAndChunk(newStereoSamples, bufferCaptureNanos: bufferCaptureNanos)
    }

    /// Packetizes PCM from an `AVAudioPCMBuffer` (microphone engine taps, media file audio
    /// taps). `captureNanoseconds` is the `SPPWCaptureClock` instant of the first frame.
    public func packetize(pcmBuffer: AVAudioPCMBuffer, captureNanoseconds: UInt64) -> [PacketTuple] {
        guard pcmBuffer.frameLength > 0 else { return [] }
        lock.lock()
        let converted = convertToStereo48k(pcmBuffer)
        lock.unlock()
        guard let converted else { return [] }
        return appendAndChunk(converted, bufferCaptureNanos: captureNanoseconds)
    }

    /// Input gain applied to every packet (1 = unchanged, 0 = silence, up to 2 = +6 dB).
    /// Safe to change while capturing.
    public var gain: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _gain
        }
        set {
            lock.lock()
            _gain = min(max(newValue.isFinite ? newValue : 1, 0), 2)
            lock.unlock()
        }
    }
    private var _gain: Float = 1

    private func appendAndChunk(_ input: [Int16], bufferCaptureNanos: UInt64) -> [PacketTuple] {
        guard !input.isEmpty else { return [] }
        let chunkSampleCount = SPPWAudioPacketHeader.chunkFrames * 2 // 480 Int16 values
        let chunkNanos = UInt64((Double(SPPWAudioPacketHeader.chunkFrames) * Self.nanosecondsPerFrame).rounded())
        var packets: [PacketTuple] = []

        lock.lock()
        var newStereoSamples = input
        if _gain != 1 {
            let gain = _gain
            for index in newStereoSamples.indices {
                let scaled = (Float(newStereoSamples[index]) * gain).rounded()
                newStereoSamples[index] = Int16(max(-32768, min(32767, scaled)))
            }
        }
        // The samples still pending from earlier buffers immediately precede this buffer, so
        // re-anchor the timeline on every buffer instead of accumulating drift.
        let pendingFrames = pendingStereoSamples.count / 2
        let pendingNanos = UInt64((Double(pendingFrames) * Self.nanosecondsPerFrame).rounded())
        var chunkTimestamp = bufferCaptureNanos > pendingNanos ? bufferCaptureNanos - pendingNanos : bufferCaptureNanos
        pendingStereoSamples.append(contentsOf: newStereoSamples)
        while pendingStereoSamples.count >= chunkSampleCount {
            let seq = nextSequence
            nextSequence &+= 1

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
            packets.append((sequence: seq, timestampNanoseconds: chunkTimestamp, payload: payload))
            chunkTimestamp &+= chunkNanos
        }
        lock.unlock()

        return packets
    }

    /// 48 kHz, native-endian, packed Float32 or Int16: copied without a converter.
    private static func isFastPathFormat(_ asbd: AudioStreamBasicDescription) -> Bool {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        return asbd.mFormatID == kAudioFormatLinearPCM
            && Int(asbd.mSampleRate.rounded()) == SPPWAudioPacketHeader.sampleRate
            && !isBigEndian
            && ((isFloat && asbd.mBitsPerChannel == 32) || (!isFloat && asbd.mBitsPerChannel == 16))
            && asbd.mChannelsPerFrame >= 1
    }

    private static func extractStereoInt16(
        _ sampleBuffer: CMSampleBuffer,
        asbd: AudioStreamBasicDescription,
        totalFrames: Int
    ) -> [Int16]? {
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        var blockBuffer: CMBlockBuffer?

        // CoreMedia rejects (kCMSampleBufferError_ArrayTooSmall) any list size other than the
        // exact one it needs, so ask for it first: 1 buffer when interleaved, 1 per channel otherwise.
        var ablSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, ablSize > 0 else { return nil }
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
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard !buffers.isEmpty else { return nil }

        var newStereoSamples: [Int16] = []
        newStereoSamples.reserveCapacity(totalFrames * 2)

        if isFloat && bitsPerChannel == 32 {
            if isNonInterleaved {
                guard let leftPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let rightPtr = (buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? leftPtr
                for i in 0..<totalFrames {
                    newStereoSamples.append(Self.floatToInt16(leftPtr[i]))
                    newStereoSamples.append(Self.floatToInt16(rightPtr[i]))
                }
            } else {
                guard let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                for i in 0..<totalFrames {
                    let l = ptr[i * channelCount]
                    let r = channelCount > 1 ? ptr[i * channelCount + 1] : l
                    newStereoSamples.append(Self.floatToInt16(l))
                    newStereoSamples.append(Self.floatToInt16(r))
                }
            }
        } else if !isFloat && bitsPerChannel == 16 {
            if isNonInterleaved {
                guard let leftPtr = buffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
                let rightPtr = (buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Int16.self) : nil) ?? leftPtr
                for i in 0..<totalFrames {
                    newStereoSamples.append(leftPtr[i])
                    newStereoSamples.append(rightPtr[i])
                }
            } else {
                guard let ptr = buffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
                for i in 0..<totalFrames {
                    let l = ptr[i * channelCount]
                    let r = channelCount > 1 ? ptr[i * channelCount + 1] : l
                    newStereoSamples.append(l)
                    newStereoSamples.append(r)
                }
            }
        } else {
            return nil
        }
        return newStereoSamples
    }

    /// Copies a sample buffer into an `AVAudioPCMBuffer` and converts it.
    /// Must be called with `lock` held (the converter keeps resampler state between buffers).
    private func convertToStereo48k(
        _ sampleBuffer: CMSampleBuffer,
        asbd: AudioStreamBasicDescription,
        totalFrames: Int
    ) -> [Int16]? {
        var sourceDescription = asbd
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              let sourceFormat = AVAudioFormat(streamDescription: &sourceDescription),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(totalFrames)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(totalFrames),
            into: input.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }
        return convertToStereo48k(input)
    }

    /// Resamples / converts any linear PCM buffer to interleaved 48 kHz stereo `Int16`.
    /// Must be called with `lock` held (the converter keeps resampler state between buffers).
    private func convertToStereo48k(_ input: AVAudioPCMBuffer) -> [Int16]? {
        let asbd = input.format.streamDescription.pointee
        let sourceFormat = input.format
        let sourceChannels = max(1, Int(asbd.mChannelsPerFrame))
        let outputChannels = min(sourceChannels, 2)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(SPPWAudioPacketHeader.sampleRate),
            channels: AVAudioChannelCount(outputChannels),
            interleaved: true
        ) else { return nil }

        if converter == nil || converterSourceDescription.map({ !Self.sameFormat($0, asbd) }) ?? true {
            converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
            converter?.downmix = sourceChannels > 2
            converterSourceDescription = asbd
        }
        guard let converter else { return nil }
        let totalFrames = Int(input.frameLength)

        let ratio = Double(SPPWAudioPacketHeader.sampleRate) / max(asbd.mSampleRate, 1)
        let capacity = AVAudioFrameCount(Double(totalFrames) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.int16ChannelData?[0] else { return nil }

        let frames = Int(output.frameLength)
        var stereo: [Int16] = []
        stereo.reserveCapacity(frames * 2)
        if outputChannels == 2 {
            stereo.append(contentsOf: UnsafeBufferPointer(start: data, count: frames * 2))
        } else {
            for i in 0..<frames {
                stereo.append(data[i])
                stereo.append(data[i])
            }
        }
        return stereo
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBytesPerFrame == b.mBytesPerFrame
    }

    @inline(__always)
    private static func floatToInt16(_ sample: Float) -> Int16 {
        let clamped = min(max(sample, -1.0), 1.0)
        return Int16((clamped * 32767.0).rounded())
    }
}

// MARK: - Ordered hand-off from capture threads

/// Hands packets produced on capture threads to a single consumer task, preserving order.
///
/// Spawning one `Task { await actor.send(...) }` per packet group does NOT preserve order:
/// unstructured tasks race to the actor, so 5 ms audio packets could leave out of sequence
/// (audible as crackle). Producers `yield` here; one task iterates `makeStream()`.
public final class SPPWOrderedPacketQueue<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Element>.Continuation?
    private let capacity: Int

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// Starts a new stream (finishing any previous one). Iterate it from exactly one task.
    public func makeStream() -> AsyncStream<Element> {
        let (stream, newContinuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        lock.lock()
        let previous = continuation
        continuation = newContinuation
        lock.unlock()
        previous?.finish()
        return stream
    }

    public func yield(_ element: Element) {
        lock.lock()
        let current = continuation
        lock.unlock()
        current?.yield(element)
    }

    public func finish() {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.finish()
    }
}

// MARK: - Server audio sources

/// One entry of the server's "audio source" picker.
public struct SPPWAudioSourceOption: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Video only.
        case none
        /// Everything the device plays (macOS system audio; iOS app / system audio).
        case system
        /// A microphone or other input device, by its system identifier
        /// (macOS `AVCaptureDevice.uniqueID`, iOS `AVAudioSessionPortDescription.uid`).
        case input(id: String)
    }

    public let kind: Kind
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Stable string for persisting the choice (`UserDefaults`).
    public var id: String {
        switch kind {
        case .none: "none"
        case .system: "system"
        case .input(let id): "input:" + id
        }
    }

    public static var none: SPPWAudioSourceOption {
        SPPWAudioSourceOption(kind: .none, name: SPPWLocalization.tr("audio.source.none"))
    }

    public static var system: SPPWAudioSourceOption {
        SPPWAudioSourceOption(kind: .system, name: SPPWLocalization.tr("audio.source.system"))
    }
}

/// Reads the audio sources the server can stream from the system.
public enum SPPWAudioSourceCatalog {
    /// `none`, `system`, then every input device currently known to the system.
    /// On macOS microphones need ScreenCaptureKit microphone capture (macOS 15+).
    public static func availableSources() -> [SPPWAudioSourceOption] {
        var sources: [SPPWAudioSourceOption] = [.none, .system]
        sources.append(contentsOf: inputDevices())
        return sources
    }

    /// Resolves a persisted `id` against the current list, falling back to system audio.
    public static func source(withID id: String, in sources: [SPPWAudioSourceOption]) -> SPPWAudioSourceOption {
        sources.first { $0.id == id } ?? sources.first { $0.kind == .system } ?? .system
    }

    private static func inputDevices() -> [SPPWAudioSourceOption] {
        #if os(macOS)
        guard #available(macOS 15.0, *) else { return [] }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map {
            SPPWAudioSourceOption(kind: .input(id: $0.uniqueID), name: $0.localizedName)
        }
        #elseif os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord && session.category != .record {
            // Inputs are only listed for a category that records.
            try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        }
        return (session.availableInputs ?? []).map {
            SPPWAudioSourceOption(kind: .input(id: $0.uid), name: $0.portName)
        }
        #else
        return []
        #endif
    }
}

#if os(iOS)
/// Captures an audio input (built-in, wired or Bluetooth microphone) with `AVAudioEngine` and
/// hands PCM buffers stamped on `SPPWCaptureClock` to the server's packetizer.
public final class SPPWMicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var isRunning = false

    public init() {}

    /// - Parameters:
    ///   - portUID: `AVAudioSessionPortDescription.uid` of the input to use, or `nil` for the current route.
    ///   - handler: called on the audio thread with each buffer and its capture instant.
    public func start(
        portUID: String?,
        handler: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        if let portUID, let port = session.availableInputs?.first(where: { $0.uid == portUID }) {
            try? session.setPreferredInput(port)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, when in
            let captured = when.isHostTimeValid
                ? SPPWCaptureClock.nanoseconds(fromHostTicks: when.hostTime)
                : SPPWCaptureClock.nowNanoseconds()
            handler(buffer, captured)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    deinit {
        stop()
    }
}
#endif

// MARK: - Receiver A/V sync clock

/// Shared timeline a receiver uses to present audio in sync with video.
///
/// Both media streams carry capture-instant timestamps from the same server clock
/// (`SPPWCaptureClock`). The receiver measures how long video takes from capture to the
/// screen (`presentedAt - capturedAt`, which also absorbs the unknown offset between the two
/// devices' clocks) and schedules every audio packet to be *heard* at
/// `capturedAt + videoDelay + videoDisplayLatency`. Video is never delayed for audio: it keeps
/// its lowest-latency path and audio follows it, so the pair stays lip-synced without adding
/// video lag. Without recent video (audio-only, paused stream) audio free-runs at minimum latency.
public final class SPPWAVSyncClock: @unchecked Sendable {
    private let lock = NSLock()
    private var videoDelayNanos: Double?
    private var lastVideoPresentedNanos: UInt64 = 0

    /// Time between handing a frame to `AVSampleBufferDisplayLayer` and photons on screen
    /// (next vsync + compositor), added on top of the measured decode-to-present delay.
    public var videoDisplayLatencyNanos: Int64 = 12_000_000
    /// Video older than this no longer drives audio timing.
    public var videoStaleAfterNanos: UInt64 = 1_000_000_000
    /// Smoothing for the video delay estimate.
    public var smoothing: Double = 0.1
    /// A jump larger than this (new server, clock reset, long stall) restarts the estimate.
    public var resetThresholdNanos: Double = 250_000_000

    public init() {}

    /// Call when a decoded frame is handed to the display layer.
    public func noteVideoPresented(senderCaptureNanos: UInt64, presentedAtNanos: UInt64 = SPPWCaptureClock.nowNanoseconds()) {
        guard senderCaptureNanos != 0 else { return }
        let sample = Double(Int64(bitPattern: presentedAtNanos &- senderCaptureNanos))
        lock.lock()
        if let current = videoDelayNanos, abs(sample - current) < resetThresholdNanos {
            videoDelayNanos = current + (sample - current) * smoothing
        } else {
            videoDelayNanos = sample
        }
        lastVideoPresentedNanos = presentedAtNanos
        lock.unlock()
    }

    /// Local capture-clock instant at which audio captured at `senderCaptureNanos` should be heard,
    /// or `nil` when there is no recent video to follow.
    public func targetPlayoutNanos(senderCaptureNanos: UInt64, now: UInt64 = SPPWCaptureClock.nowNanoseconds()) -> UInt64? {
        guard senderCaptureNanos != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let delay = videoDelayNanos,
              now &- lastVideoPresentedNanos <= videoStaleAfterNanos else { return nil }
        let total = Int64(delay.rounded()) &+ videoDisplayLatencyNanos
        return UInt64(bitPattern: Int64(bitPattern: senderCaptureNanos) &+ total)
    }

    /// Current smoothed capture-to-present video delay (includes the clock offset), for diagnostics.
    public var videoDelayMilliseconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return videoDelayNanos.map { $0 / 1_000_000 }
    }

    public func reset() {
        lock.lock()
        videoDelayNanos = nil
        lastVideoPresentedNanos = 0
        lock.unlock()
    }
}

/// What the receiver does with one incoming audio packet.
public enum SPPWAudioSyncDecision: Equatable, Sendable {
    /// Append the packet behind what is already queued.
    case play
    /// The queue is too deep (audio heard later than it should): skip this packet.
    case drop
    /// The queue is too shallow (or empty): queue this much silence first, then the packet.
    case delay(silenceFrames: Int)
}

/// Receiver jitter buffer / lip-sync controller.
///
/// It keeps the playout queue at a *desired depth* and corrects it only gently:
/// - the desired depth is what makes audio heard together with the matching video
///   (`queued - lateness`), clamped to `[minimumQueue, maximumQueue]`; without a video
///   timeline it is `minimumQueue`. When audio cannot reach the video (its own path is
///   slower) the depth simply stays at the minimum: audio is never dropped for that.
/// - the measured queue is smoothed, because packets arrive in bursts (ScreenCaptureKit
///   delivers ~21 ms buffers) and the render thread drains in IO-buffer steps;
/// - at most one correction per `minimumCorrectionInterval`, each one packet (5 ms) dropped
///   or at most `maximumSilence` inserted, and only beyond `correctionThreshold`;
/// - an empty queue (stream start, real loss) is refilled once to the desired depth.
/// Pure value type so the policy is unit-testable without an audio device.
public struct SPPWAudioJitterController: Sendable {
    public var minimumQueueNanos: Int64
    public var maximumQueueNanos: Int64 = 200_000_000
    public var correctionThresholdNanos: Int64 = 25_000_000
    public var minimumCorrectionIntervalNanos: UInt64 = 500_000_000
    public var maximumSilenceNanos: Int64 = 10_000_000
    /// Per-packet smoothing of the desired depth and of the measured queue. Slow on purpose:
    /// the video delay it follows jitters on Wi-Fi, and every correction is an audible cut.
    public var smoothing: Double = 0.02
    /// Upper bound of the extra depth added for measured network arrival spikes.
    public var maximumNetworkAllowanceNanos: Int64 = 120_000_000
    /// Per-packet decay of the spike peak (≈ 4 s half-life at 200 packets/s).
    public var spikeDecay: Double = 0.99913

    private var desiredQueueNanos: Double?
    private var smoothedQueueNanos: Double?
    private var lastCorrectionNanos: UInt64?
    private var baselineTransitNanos: Double?
    private var peakSpikeNanos: Double = 0

    public init(minimumQueueNanos: Int64 = 30_000_000) {
        self.minimumQueueNanos = minimumQueueNanos
    }

    public var currentDesiredQueueMilliseconds: Double? { desiredQueueNanos.map { $0 / 1_000_000 } }

    /// Extra depth that covers the arrival spikes seen recently (Wi-Fi retries, power save,
    /// AWDL channel hops, capture bursts): the peak of `transit - baseline`, rising at once
    /// and decaying slowly, so one stall raises the buffer for the next few seconds.
    public var networkAllowanceNanos: Int64 {
        Int64(min(peakSpikeNanos, Double(maximumNetworkAllowanceNanos)))
    }

    /// The smallest queue the controller keeps: device minimum plus the network allowance.
    public var effectiveMinimumQueueNanos: Int64 {
        min(minimumQueueNanos + networkAllowanceNanos, maximumQueueNanos)
    }

    /// Records one packet's transit, `arrival - senderCapture` (any constant clock offset is fine).
    public mutating func noteArrival(transitNanos: Int64) {
        let transit = Double(transitNanos)
        guard let baseline = baselineTransitNanos, abs(transit - baseline) < 2_000_000_000 else {
            baselineTransitNanos = transit
            peakSpikeNanos = 0
            return
        }
        // Baseline = the fastest recent path; it creeps up slowly so clock drift or a route
        // change cannot inflate the spikes forever.
        let newBaseline = transit < baseline ? transit : baseline + (transit - baseline) * 0.0005
        baselineTransitNanos = newBaseline
        peakSpikeNanos = max(transit - newBaseline, peakSpikeNanos * spikeDecay)
    }

    public mutating func reset() {
        desiredQueueNanos = nil
        smoothedQueueNanos = nil
        lastCorrectionNanos = nil
        baselineTransitNanos = nil
        peakSpikeNanos = 0
    }

    /// - Parameters:
    ///   - queuedNanos: audio already queued ahead of this packet.
    ///   - latenessNanos: `heardAt - target` from `SPPWAVSyncClock` (> 0: audio late), or `nil`
    ///     without a video timeline.
    ///   - packetNanos: duration of the incoming packet (what a drop removes).
    public mutating func decide(
        queuedNanos: Int64,
        latenessNanos: Int64?,
        packetNanos: Int64 = 5_000_000,
        now: UInt64
    ) -> SPPWAudioSyncDecision {
        let floor = effectiveMinimumQueueNanos
        let raw = latenessNanos.map { queuedNanos - $0 } ?? floor
        let clamped = Double(min(max(raw, floor), maximumQueueNanos))
        let desired = desiredQueueNanos.map { $0 + (clamped - $0) * smoothing } ?? clamped
        desiredQueueNanos = desired

        if queuedNanos <= 0 {
            // Starved: refill once to the desired depth instead of chattering.
            lastCorrectionNanos = now
            smoothedQueueNanos = desired
            return .delay(silenceFrames: Self.frames(Int64(desired)))
        }

        let measured = Double(queuedNanos)
        let smoothed = smoothedQueueNanos.map { $0 + (measured - $0) * smoothing } ?? measured
        smoothedQueueNanos = smoothed

        if let last = lastCorrectionNanos, now &- last < minimumCorrectionIntervalNanos {
            return .play
        }
        let deviation = smoothed - desired
        if deviation > Double(correctionThresholdNanos) {
            lastCorrectionNanos = now
            smoothedQueueNanos = smoothed - Double(packetNanos)
            return .drop
        }
        if deviation < -Double(correctionThresholdNanos) {
            let silence = min(Int64(-deviation), maximumSilenceNanos)
            lastCorrectionNanos = now
            smoothedQueueNanos = smoothed + Double(silence)
            return .delay(silenceFrames: Self.frames(silence))
        }
        return .play
    }

    static func frames(_ nanos: Int64) -> Int {
        max(1, Int((Double(nanos) * Double(SPPWAudioPacketHeader.sampleRate) / 1_000_000_000).rounded()))
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
    /// Upper bound on queued audio while following video (the video path can be slower than
    /// audio by tens of milliseconds; beyond this something is wrong and audio is dropped).
    private let maxSyncedQueuedFrames = SPPWAudioPacketHeader.sampleRate / 4 // 250 ms
    /// Audio frames scheduled on the player node and not yet finished.
    private var queuedFrames = 0
    /// Device output latency (hardware + IO buffer), refreshed when the engine starts.
    private var outputLatencyNanos: UInt64 = 0
    private var _isMuted: Bool = false
    /// Serializes engine start / pause / stop. Order: `controlLock` before `lock`; buffer
    /// completion handlers only ever take `lock`.
    private let controlLock = NSLock()
    /// Bumped whenever the queue is flushed, so late completions of flushed buffers are ignored.
    private var playbackGeneration: UInt64 = 0
    /// Jitter buffer / lip-sync policy (minimum depth set from the device IO buffer at start).
    private var jitter = SPPWAudioJitterController()
    /// Player sample time at which the audio scheduled so far ends.
    private var scheduledEndFrame: Int64 = 0
    /// Last packet sequence scheduled; older/duplicate packets are dropped, not played out of order.
    private var lastSequence: UInt32?
    public private(set) var outOfOrderDroppedPackets = 0
    /// Lost packets covered by a faded repeat of the previous packet.
    public private(set) var concealedPackets = 0
    /// Last scheduled packet (deinterleaved), the source for loss concealment.
    private var lastLeft: [Float] = []
    private var lastRight: [Float] = []
    /// The next packet starts after a cut (drop, gap, silence) and is faded in.
    private var needsFadeIn = false
    /// Gaps of at most this many lost packets are concealed; longer ones restart cleanly.
    private let maximumConcealedPackets = 8
    /// Fade-in length after a discontinuity (2 ms).
    static let fadeInFrames = 96
    /// When set, packets are scheduled to be heard together with the matching video frames.
    public var syncClock: SPPWAVSyncClock?
    /// Counters for diagnostics (packets dropped / silence frames inserted to keep sync).
    public private(set) var syncDroppedPackets = 0
    public private(set) var syncInsertedSilenceFrames = 0

    public var isMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMuted
        }
        set {
            lock.lock()
            _isMuted = newValue
            let shouldPause = newValue && isRunning
            lock.unlock()
            if shouldPause {
                pauseEngine(onlyIfIdle: false)
            }
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
        controlLock.lock()
        lock.lock()
        startLocked()
        lock.unlock()
        controlLock.unlock()
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
            outputLatencyNanos = currentOutputLatencyNanos()
            // Room for network/packetization jitter plus two render quanta of the device.
            jitter = SPPWAudioJitterController(minimumQueueNanos: 20_000_000 + 2 * currentIOBufferNanos())
            scheduledEndFrame = 0
            lastSequence = nil
        } catch {
            isRunning = false
        }
    }

    /// Duration of one render quantum (the device IO buffer).
    private func currentIOBufferNanos() -> Int64 {
        #if os(iOS)
        let seconds = AVAudioSession.sharedInstance().ioBufferDuration
        #else
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var seconds = 512.0 / 48_000.0
        if let unit = engine.outputNode.audioUnit,
           AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size) == noErr,
           frames > 0 {
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            seconds = Double(frames) / (rate > 0 ? rate : 48_000)
        }
        #endif
        guard seconds.isFinite, seconds > 0 else { return 10_000_000 }
        return Int64(min(seconds, 0.1) * 1_000_000_000)
    }

    /// Player sample time currently being rendered, or nil before the first render.
    private func renderedFrame() -> Int64? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else { return nil }
        return playerTime.sampleTime
    }

    private func currentOutputLatencyNanos() -> UInt64 {
        var seconds = engine.outputNode.presentationLatency
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        seconds = max(seconds, session.outputLatency) + session.ioBufferDuration
        #endif
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }

    /// Stops the player node and pauses the engine.
    ///
    /// Must be called WITHOUT `lock`: `AVAudioPlayerNode.stop()` runs the completion handlers
    /// of every still-queued buffer before returning, and those take `lock` — calling it with
    /// the lock held deadlocks the caller (it froze the macOS receiver on disconnect).
    private func pauseEngine(onlyIfIdle: Bool) {
        controlLock.lock()
        defer { controlLock.unlock() }
        lock.lock()
        if onlyIfIdle {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= lastAudioEnqueueNanos ? (now - lastAudioEnqueueNanos) : 0
            guard elapsed >= idlePauseThresholdNanos, scheduledBuffersInFlight == 0 else {
                lock.unlock()
                return
            }
        }
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        resetQueueLocked()
        lock.unlock()

        playerNode.stop()
        engine.pause()
    }

    /// Forgets queued audio; completions of buffers from before the reset are ignored.
    private func resetQueueLocked() {
        scheduledBuffersInFlight = 0
        queuedFrames = 0
        playbackGeneration &+= 1
        scheduledEndFrame = 0
        lastSequence = nil
        jitter.reset()
        lastLeft = []
        lastRight = []
        needsFadeIn = false
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
                self.lock.unlock()
                // Re-checked under the control lock; stopping happens outside `lock`.
                self.pauseEngine(onlyIfIdle: true)
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
        controlLock.lock()
        defer { controlLock.unlock() }
        lock.lock()
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil
        let wasRunning = isRunning
        #if os(iOS)
        let wasSessionActive = sessionActivated
        sessionActivated = false
        #endif
        if wasRunning {
            isRunning = false
            resetQueueLocked()
        }
        lock.unlock()

        // Outside `lock`: stop() synchronously runs the queued buffers' completion
        // handlers, which take `lock` (see pauseEngine).
        if wasRunning {
            playerNode.stop()
            engine.stop()
        }

        #if os(iOS)
        if wasSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif
    }

    /// Decodes an incoming `.audioFrame` (`kind == 9`) payload and schedules it for playout.
    /// `senderTimestampNanoseconds` is the datagram header timestamp (capture instant of the
    /// packet's first sample); with a `syncClock` that has recent video, the packet is aligned
    /// to the video timeline, otherwise it plays as soon as possible.
    public func enqueue(audioPayload: Data, senderTimestampNanoseconds: UInt64 = 0) {
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
            // Engine transitions are serialized by `controlLock`, always taken before `lock`.
            lock.unlock()
            start()
            lock.lock()
        }
        guard isRunning, !_isMuted else {
            lock.unlock()
            return
        }
        let generation = playbackGeneration
        scheduleIdlePauseLocked(afterSeconds: 3.0)

        // Play strictly in sequence order: a packet older than (or equal to) the last one
        // scheduled arrived late or twice; playing it would scramble 5 ms of audio.
        var lostPackets = 0
        if let last = lastSequence {
            let delta = Int32(bitPattern: header.sequence &- last)
            if delta <= 0 && delta > -4096 {
                outOfOrderDroppedPackets += 1
                lock.unlock()
                return
            }
            if delta > 1 {
                if delta - 1 <= Int32(maximumConcealedPackets) {
                    lostPackets = Int(delta - 1)
                } else {
                    needsFadeIn = true
                }
            }
        }
        lastSequence = header.sequence
        if senderTimestampNanoseconds != 0 {
            jitter.noteArrival(transitNanos: Int64(bitPattern: nowNanos &- senderTimestampNanoseconds))
        }

        // Queue depth from the player's own clock (precise to one render quantum), falling
        // back to completion counting before the first render.
        var queuedFramesNow = queuedFrames
        if let rendered = renderedFrame() {
            if scheduledEndFrame < rendered {
                scheduledEndFrame = rendered // starved: new audio starts now
            }
            queuedFramesNow = Int(scheduledEndFrame - rendered)
        }
        let rate = Double(SPPWAudioPacketHeader.sampleRate)
        // Lost packets are filled in (see below), so the decision sees the queue with them.
        let concealFrames = lostPackets * frameCount
        let queuedNanos = Int64(Double(queuedFramesNow + concealFrames) * 1_000_000_000 / rate)
        var lateness: Int64?
        if let target = syncClock?.targetPlayoutNanos(senderCaptureNanos: senderTimestampNanoseconds, now: nowNanos) {
            let heardAt = nowNanos &+ UInt64(max(queuedNanos, 0)) &+ outputLatencyNanos
            lateness = Int64(bitPattern: heardAt &- target)
        }

        var silenceFrames = concealFrames
        switch jitter.decide(
            queuedNanos: queuedNanos,
            latenessNanos: lateness,
            packetNanos: Int64(Double(frameCount) * 1_000_000_000 / rate),
            now: nowNanos
        ) {
        case .play:
            break
        case .drop:
            syncDroppedPackets += 1
            needsFadeIn = true
            lock.unlock()
            return
        case .delay(let frames):
            silenceFrames += frames
        }
        if queuedFramesNow + silenceFrames + frameCount > maxSyncedQueuedFrames {
            syncDroppedPackets += 1
            needsFadeIn = true
            lock.unlock()
            return
        }
        scheduledEndFrame += Int64(silenceFrames + frameCount)
        if silenceFrames > 0 {
            syncInsertedSilenceFrames += silenceFrames - concealFrames
            concealedPackets += lostPackets
            scheduledBuffersInFlight += 1
            queuedFrames += silenceFrames
        }
        scheduledBuffersInFlight += 1
        queuedFrames += frameCount
        // Gap filler: a faded repeat of the previous packet, then silence (no hard cut).
        let filler = silenceFrames > 0
            ? Self.concealmentSamples(lastLeft: lastLeft, lastRight: lastRight, frames: silenceFrames)
            : nil
        let fadeIn = needsFadeIn || silenceFrames > 0
        needsFadeIn = false
        lock.unlock()

        let insertedSilenceFrames = silenceFrames
        if insertedSilenceFrames > 0, let filler, let silence = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(silenceFrames)
        ) {
            silence.frameLength = AVAudioFrameCount(silenceFrames)
            if let channels = silence.floatChannelData {
                filler.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: silenceFrames) }
                filler.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: silenceFrames) }
            }
            playerNode.scheduleBuffer(silence) { [weak self] in
                self?.completeScheduled(frames: insertedSilenceFrames, generation: generation)
            }
        } else if insertedSilenceFrames > 0 {
            completeScheduled(frames: insertedSilenceFrames, generation: generation)
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let floatChannels = pcmBuffer.floatChannelData else {
            completeScheduled(frames: frameCount, generation: generation)
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

        if fadeIn {
            Self.applyFadeIn(leftOut, count: frameCount, rampFrames: Self.fadeInFrames)
            Self.applyFadeIn(rightOut, count: frameCount, rampFrames: Self.fadeInFrames)
        }
        let keptLeft = Array(UnsafeBufferPointer(start: leftOut, count: frameCount))
        let keptRight = Array(UnsafeBufferPointer(start: rightOut, count: frameCount))
        lock.lock()
        if generation == playbackGeneration {
            lastLeft = keptLeft
            lastRight = keptRight
        }
        lock.unlock()

        playerNode.scheduleBuffer(pcmBuffer) { [weak self] in
            self?.completeScheduled(frames: frameCount, generation: generation)
        }
    }

    /// Gap filler of `frames` samples per channel: the previous packet repeated once with a
    /// linear fade to zero, then silence. Avoids the click of a hard cut to silence.
    static func concealmentSamples(lastLeft: [Float], lastRight: [Float], frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: max(frames, 0))
        var right = left
        let source = min(lastLeft.count, lastRight.count)
        let fadeLength = min(source, frames)
        guard fadeLength > 0 else { return (left, right) }
        for i in 0..<fadeLength {
            let gain = Float(fadeLength - i) / Float(fadeLength + 1)
            left[i] = lastLeft[i] * gain
            right[i] = lastRight[i] * gain
        }
        return (left, right)
    }

    /// Linear fade-in over the first `rampFrames` samples.
    static func applyFadeIn(_ samples: UnsafeMutablePointer<Float>, count: Int, rampFrames: Int) {
        let ramp = min(rampFrames, count)
        guard ramp > 0 else { return }
        for i in 0..<ramp {
            samples[i] *= Float(i + 1) / Float(ramp + 1)
        }
    }

    /// Completion of a scheduled buffer. Never call `playerNode.stop()` / `engine.stop()`
    /// while holding `lock`: they invoke this synchronously.
    private func completeScheduled(frames: Int, generation: UInt64) {
        lock.lock()
        if generation == playbackGeneration {
            scheduledBuffersInFlight = max(0, scheduledBuffersInFlight - 1)
            queuedFrames = max(0, queuedFrames - frames)
        }
        lock.unlock()
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
    case releaseAll
    /// Committed Unicode text (system keyboard, IME such as Pinyin, dictation, paste-as-typing).
    /// The server types it with `CGEventKeyboardSetUnicodeString`, independent of the Mac keyboard layout.
    case text(String)
    /// Atomic key tap (down + up) of a macOS virtual key code with `CGEventFlags` modifier bits.
    /// Used by special keys and shortcuts, so a lost packet can never leave a key held.
    case keyPress(keyCode: UInt16, modifiers: UInt32)
    /// Relative pointer motion in host display points (trackpad mode, hardware mouse).
    case pointerDelta(deltaX: Float, deltaY: Float)
    /// Mouse button press/release at the current host cursor position.
    case buttonAtCursor(button: UInt8, isDown: Bool)
    /// Atomic click (down + up) at the current host cursor position; the host counts double/triple clicks.
    case clickAtCursor(button: UInt8)
    /// Reliability envelope: the client sends it twice, the host applies each `sequence` once
    /// (`SPPWInputSequenceFilter`). The inner event must not itself be `.sequenced`.
    indirect case sequenced(sequence: UInt16, event: SPPWInputEvent)
    /// Asks the host to leave its own cursor out of the captured video (`hidden == true`) because
    /// the receiver shows a local pointer, or to draw it again. State, not an action: receivers
    /// resend it with every heartbeat while hidden; the host forgets it when the client leaves.
    case cursorVisibility(hidden: Bool)

    /// Longest UTF-8 text carried by one `.text` event.
    public static let maximumTextBytes = 1024

    private enum Tag: UInt8 {
        case pointerMove = 1
        case mouseButton = 2
        case scroll = 3
        case key = 4
        case touch = 5
        case releaseAll = 6
        case text = 7
        case keyPress = 8
        case pointerDelta = 9
        case buttonAtCursor = 10
        case clickAtCursor = 11
        case sequenced = 12
        case cursorVisibility = 13
    }

    /// The event with any `.sequenced` envelope removed.
    public var unwrapped: SPPWInputEvent {
        if case let .sequenced(_, inner) = self { return inner.unwrapped }
        return self
    }

    /// Input that normally changes what is on screen (clicks, keys, text, scrolling,
    /// touches). Plain pointer motion does not count: with the remote cursor hidden it
    /// changes no pixels. Used to tell a still screen from a stuck capture.
    public var normallyChangesScreen: Bool {
        switch unwrapped {
        case .mouseButton, .scroll, .key, .touch, .text, .keyPress, .buttonAtCursor, .clickAtCursor:
            return true
        case .pointerMove, .pointerDelta, .releaseAll, .cursorVisibility, .sequenced:
            return false
        }
    }

    /// Truncates `text` to at most `maxBytes` UTF-8 bytes without splitting a character.
    public static func truncatedUTF8(_ text: String, maxBytes: Int = maximumTextBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
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
        case .releaseAll:
            data.append(Tag.releaseAll.rawValue)
        case let .text(text):
            let bytes = Array(Self.truncatedUTF8(text).utf8)
            data.append(Tag.text.rawValue)
            data.append(UInt8(truncatingIfNeeded: bytes.count >> 8))
            data.append(UInt8(truncatingIfNeeded: bytes.count))
            data.append(contentsOf: bytes)
        case let .keyPress(keyCode, modifiers):
            data.append(Tag.keyPress.rawValue)
            data.append(UInt8(truncatingIfNeeded: keyCode >> 8))
            data.append(UInt8(truncatingIfNeeded: keyCode))
            Self.appendU32(modifiers, to: &data)
        case let .pointerDelta(dx, dy):
            data.append(Tag.pointerDelta.rawValue)
            Self.appendFloat(dx, to: &data)
            Self.appendFloat(dy, to: &data)
        case let .buttonAtCursor(button, isDown):
            data.append(Tag.buttonAtCursor.rawValue)
            data.append(button)
            data.append(isDown ? 1 : 0)
        case let .clickAtCursor(button):
            data.append(Tag.clickAtCursor.rawValue)
            data.append(button)
        case let .sequenced(sequence, event):
            data.append(Tag.sequenced.rawValue)
            data.append(UInt8(truncatingIfNeeded: sequence >> 8))
            data.append(UInt8(truncatingIfNeeded: sequence))
            data.append(event.unwrapped.encoded())
        case let .cursorVisibility(hidden):
            data.append(Tag.cursorVisibility.rawValue)
            data.append(hidden ? 1 : 0)
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
        case .releaseAll:
            self = .releaseAll
        case .text:
            guard payload.count >= 3 else { return nil }
            let length = (Int(payload[s + 1]) << 8) | Int(payload[s + 2])
            guard length <= Self.maximumTextBytes, payload.count >= 3 + length,
                  let text = String(bytes: payload[(s + 3)..<(s + 3 + length)], encoding: .utf8) else { return nil }
            self = .text(text)
        case .keyPress:
            guard payload.count >= 7 else { return nil }
            let code = (UInt16(payload[s + 1]) << 8) | UInt16(payload[s + 2])
            self = .keyPress(keyCode: code, modifiers: Self.readU32(payload, at: s + 3))
        case .pointerDelta:
            guard payload.count >= 9 else { return nil }
            self = .pointerDelta(
                deltaX: Self.readFloat(payload, at: s + 1),
                deltaY: Self.readFloat(payload, at: s + 5)
            )
        case .buttonAtCursor:
            guard payload.count >= 3 else { return nil }
            self = .buttonAtCursor(button: payload[s + 1], isDown: payload[s + 2] != 0)
        case .clickAtCursor:
            guard payload.count >= 2 else { return nil }
            self = .clickAtCursor(button: payload[s + 1])
        case .sequenced:
            guard payload.count >= 4, payload[s + 3] != Tag.sequenced.rawValue else { return nil }
            let sequence = (UInt16(payload[s + 1]) << 8) | UInt16(payload[s + 2])
            guard let inner = SPPWInputEvent(parsing: Data(payload[(s + 3)...])) else { return nil }
            self = .sequenced(sequence: sequence, event: inner)
        case .cursorVisibility:
            guard payload.count >= 2 else { return nil }
            self = .cursorVisibility(hidden: payload[s + 1] != 0)
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

// MARK: - Remote input helpers (keyboard, sticky modifiers, trackpad, reliability)

/// Client-side reliability for discrete input: wraps events in `.sequenced` with a rolling number.
/// Senders transmit each wrapped event twice (immediately and again a few ms later).
public struct SPPWInputSequencer: Sendable {
    private var next: UInt16

    public init(start: UInt16 = UInt16.random(in: 0...UInt16.max)) {
        next = start
    }

    public mutating func wrap(_ event: SPPWInputEvent) -> SPPWInputEvent {
        let sequence = next
        next &+= 1
        return .sequenced(sequence: sequence, event: event.unwrapped)
    }

    /// Discrete events (keys, text, clicks, buttons) need delivery; motion and scroll do not.
    public static func needsRedundancy(_ event: SPPWInputEvent) -> Bool {
        switch event.unwrapped {
        case .text, .keyPress, .key, .buttonAtCursor, .clickAtCursor, .mouseButton, .releaseAll, .cursorVisibility:
            return true
        case .pointerMove, .scroll, .touch, .pointerDelta, .sequenced:
            return false
        }
    }
}

/// Host-side duplicate filter for `.sequenced` events (one per client). Accepts each sequence
/// number once within a sliding window, so the redundant copy of an event is dropped.
public struct SPPWInputSequenceFilter: Sendable {
    public static let windowSize = 256
    private var seen: [UInt16] = []
    private var seenSet: Set<UInt16> = []

    public init() {}

    /// Returns `true` the first time `sequence` is seen in the recent window.
    public mutating func accept(_ sequence: UInt16) -> Bool {
        guard !seenSet.contains(sequence) else { return false }
        seen.append(sequence)
        seenSet.insert(sequence)
        if seen.count > Self.windowSize {
            seenSet.remove(seen.removeFirst())
        }
        return true
    }

    /// Unwraps `event`; returns `nil` for a duplicate `.sequenced` copy.
    public mutating func filter(_ event: SPPWInputEvent) -> SPPWInputEvent? {
        if case let .sequenced(sequence, inner) = event {
            return accept(sequence) ? inner.unwrapped : nil
        }
        return event
    }
}

/// `CGEventFlags`-compatible modifier bits carried by `.key` / `.keyPress` (`modifiers: UInt32`).
public struct SPPWKeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let capsLock = SPPWKeyModifiers(rawValue: 0x0001_0000)
    public static let shift = SPPWKeyModifiers(rawValue: 0x0002_0000)
    public static let control = SPPWKeyModifiers(rawValue: 0x0004_0000)
    public static let option = SPPWKeyModifiers(rawValue: 0x0008_0000)
    public static let command = SPPWKeyModifiers(rawValue: 0x0010_0000)
    public static let numericPad = SPPWKeyModifiers(rawValue: 0x0020_0000)
    public static let function = SPPWKeyModifiers(rawValue: 0x0080_0000)

    /// Modifiers that turn a typed character into a shortcut (everything except Shift).
    public static let shortcutModifiers: SPPWKeyModifiers = [.control, .option, .command]
}

/// Detects a modifier-only chord such as ⌃⌥: every required modifier held together, then all
/// released, with no other key, click or extra modifier in between. Because ⌃⌥+key never
/// completes the chord, the receiver can bind it locally (leave fullscreen) without stealing
/// any shortcut from the remote Mac.
public struct SPPWModifierChordDetector: Sendable {
    public let required: SPPWKeyModifiers
    private static let chordBits: SPPWKeyModifiers = [.shift, .control, .option, .command, .function]
    private var held: SPPWKeyModifiers = []
    private var armed = false
    private var spoiled = false

    public init(required: SPPWKeyModifiers = [.control, .option]) {
        self.required = required.intersection(Self.chordBits)
    }

    /// Feeds the current modifier state (NSEvent / CGEventFlags bit layout). Returns true
    /// exactly once, when the last modifier of a clean chord is released.
    public mutating func modifiersChanged(_ flags: SPPWKeyModifiers) -> Bool {
        let relevant = flags.intersection(Self.chordBits)
        held = relevant
        if relevant.isEmpty {
            let fired = armed && !spoiled
            armed = false
            spoiled = false
            return fired
        }
        if !relevant.subtracting(required).isEmpty {
            spoiled = true
        } else if relevant == required {
            armed = true
        }
        return false
    }

    /// Any key press, click or scroll while modifiers are held cancels the chord.
    public mutating func otherInput() {
        if !held.isEmpty { spoiled = true }
    }

    public mutating func reset() {
        held = []
        armed = false
        spoiled = false
    }
}

/// macOS virtual key codes (`kVK_*`, ANSI positions) and conversions used by the iOS receiver.
public enum SPPWMacKeyCode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let command: UInt16 = 55
    public static let shift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let option: UInt16 = 58
    public static let control: UInt16 = 59
    public static let function: UInt16 = 63
    public static let help: UInt16 = 114
    public static let home: UInt16 = 115
    public static let pageUp: UInt16 = 116
    public static let forwardDelete: UInt16 = 117
    public static let end: UInt16 = 119
    public static let pageDown: UInt16 = 121
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    /// F1...F20.
    public static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    public static func functionKey(_ number: Int) -> UInt16? {
        (1...functionKeys.count).contains(number) ? functionKeys[number - 1] : nil
    }

    /// Flags a real Apple keyboard sets on navigation and function keys. System shortcuts such as
    /// Mission Control (⌃↑) only match when arrows carry `numericPad | function`.
    public static func implicitFlags(forKeyCode keyCode: UInt16) -> CGEventFlagsRaw {
        switch keyCode {
        case leftArrow, rightArrow, downArrow, upArrow:
            return SPPWKeyModifiers([.numericPad, .function]).rawValue64
        case help, home, pageUp, forwardDelete, end, pageDown:
            return SPPWKeyModifiers.function.rawValue64
        default:
            return functionKeys.contains(keyCode) ? SPPWKeyModifiers.function.rawValue64 : 0
        }
    }

    public typealias CGEventFlagsRaw = UInt64

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]
    private static let plain: [Character: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43,
        "/": 44, ".": 47, "`": 50, " ": 49
    ]
    private static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26,
        "_": 27, "*": 28, ")": 29, "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43,
        "?": 44, ">": 47, "~": 50
    ]

    /// US-ANSI key for a typed character, used when a shortcut modifier is active (⌘C, ⌃A…).
    public static func keyCode(for character: Character) -> (keyCode: UInt16, needsShift: Bool)? {
        if let code = letters[character] { return (code, false) }
        if character.isUppercase, let lower = character.lowercased().first, let code = letters[lower] {
            return (code, true)
        }
        if let code = plain[character] { return (code, false) }
        if let code = shifted[character] { return (code, true) }
        switch character {
        case "\n", "\r": return (returnKey, false)
        case "\t": return (tab, false)
        default: return nil
        }
    }

    private static let hidTable: [UInt16: UInt16] = {
        var table: [UInt16: UInt16] = [:]
        let letterOrder: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
        for (offset, letter) in letterOrder.enumerated() { table[UInt16(0x04 + offset)] = letters[letter] }
        let digits: [Character] = Array("1234567890")
        for (offset, digit) in digits.enumerated() { table[UInt16(0x1E + offset)] = plain[digit] }
        let fixed: [UInt16: UInt16] = [
            0x28: returnKey, 0x29: escape, 0x2A: delete, 0x2B: tab, 0x2C: space,
            0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42, 0x32: 42, 0x33: 41, 0x34: 39,
            0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44, 0x39: capsLock,
            0x49: help, 0x4A: home, 0x4B: pageUp, 0x4C: forwardDelete, 0x4D: end, 0x4E: pageDown,
            0x4F: rightArrow, 0x50: leftArrow, 0x51: downArrow, 0x52: upArrow,
            0x53: 71, 0x54: 75, 0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76,
            0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87, 0x5E: 88, 0x5F: 89, 0x60: 91,
            0x61: 92, 0x62: 82, 0x63: 65, 0x64: 10, 0x67: 81,
            0x7F: 74, 0x80: 72, 0x81: 73, 0x87: 94, 0x89: 93, 0x90: 104, 0x91: 102,
            0xE0: control, 0xE1: shift, 0xE2: option, 0xE3: command,
            0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54
        ]
        table.merge(fixed) { _, new in new }
        for number in 1...12 { table[UInt16(0x3A + number - 1)] = functionKeys[number - 1] }
        for number in 13...20 { table[UInt16(0x68 + number - 13)] = functionKeys[number - 1] }
        return table
    }()

    /// Maps a USB HID keyboard usage (`UIKey.keyCode.rawValue`, page 0x07) to a macOS key code.
    public static func fromHIDUsage(_ usage: UInt16) -> UInt16? {
        hidTable[usage]
    }

    /// Modifier bit for a modifier key code, `nil` for regular keys.
    public static func modifier(forKeyCode keyCode: UInt16) -> SPPWKeyModifiers? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 57: return .capsLock
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }
}

extension SPPWKeyModifiers {
    var rawValue64: UInt64 { UInt64(rawValue) }
}

/// Sticky modifier bar (Shift, Control, Option, Command) for touch keyboards.
/// Tap: off → one shot (applies to the next key) → off. Double tap: locked until tapped again.
public struct SPPWStickyModifiers: Sendable, Equatable {
    public enum State: Sendable, Equatable { case off, oneShot, locked }

    public static let order: [SPPWKeyModifiers] = [.shift, .control, .option, .command]
    private var states: [UInt32: State] = [:]

    public init() {}

    public func state(of modifier: SPPWKeyModifiers) -> State {
        states[modifier.rawValue] ?? .off
    }

    public mutating func tap(_ modifier: SPPWKeyModifiers) {
        states[modifier.rawValue] = state(of: modifier) == .off ? .oneShot : .off
    }

    public mutating func lock(_ modifier: SPPWKeyModifiers) {
        states[modifier.rawValue] = .locked
    }

    public var active: SPPWKeyModifiers {
        states.reduce(into: SPPWKeyModifiers()) { result, entry in
            if entry.value != .off { result.insert(SPPWKeyModifiers(rawValue: entry.key)) }
        }
    }

    /// Returns the active modifiers for one key and clears the one-shot ones.
    public mutating func consume() -> SPPWKeyModifiers {
        let current = active
        for (key, value) in states where value == .oneShot { states[key] = .off }
        return current
    }

    public mutating func reset() { states.removeAll() }
}

/// Turns keyboard input on the receiver into wire events.
///
/// IME rule: text composed on the device (Pinyin, Kana, accents, dictation, emoji) is only sent
/// once committed, as `.text` Unicode, so the Mac's own input source and layout never re-interpret
/// it. Keys that are not text (arrows, Esc, F-keys) and shortcuts (a character with ⌘/⌃/⌥) go as
/// virtual key codes with modifier flags (`.keyPress`), because apps match shortcuts on key codes.
public enum SPPWKeyboardTranslator {
    public static func events(forCommittedText text: String, modifiers: SPPWKeyModifiers) -> [SPPWInputEvent] {
        guard !text.isEmpty else { return [] }
        let shortcut = !modifiers.isDisjoint(with: SPPWKeyModifiers.shortcutModifiers)
        if text.count == 1, let character = text.first {
            if character == "\n" || character == "\r" {
                return [.keyPress(keyCode: SPPWMacKeyCode.returnKey, modifiers: modifiers.rawValue)]
            }
            if character == "\t" {
                return [.keyPress(keyCode: SPPWMacKeyCode.tab, modifiers: modifiers.rawValue)]
            }
            if shortcut, let mapped = SPPWMacKeyCode.keyCode(for: character) {
                var flags = modifiers
                if mapped.needsShift { flags.insert(.shift) }
                return [.keyPress(keyCode: mapped.keyCode, modifiers: flags.rawValue)]
            }
            if modifiers.contains(.shift) {
                return [.text(text.uppercased())]
            }
        }
        return chunks(of: text).map { .text($0) }
    }

    /// Backspace from the on-screen keyboard.
    public static func deleteBackward(modifiers: SPPWKeyModifiers) -> SPPWInputEvent {
        .keyPress(keyCode: SPPWMacKeyCode.delete, modifiers: modifiers.rawValue)
    }

    /// Splits long text (pastes, dictation) into `.text`-sized pieces on character boundaries.
    public static func chunks(of text: String, maxBytes: Int = SPPWInputEvent.maximumTextBytes) -> [String] {
        var pieces: [String] = []
        var current = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes, !current.isEmpty {
                pieces.append(current)
                current = ""
                used = 0
            }
            current.append(character)
            used += size
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// Keys and Mac shortcuts offered by the receiver's special keys panel.
public enum SPPWSpecialKey: String, CaseIterable, Sendable {
    case escape, tab, returnKey, delete, forwardDelete
    case up, down, left, right, pageUp, pageDown, home, end
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case cut, copy, paste, selectAll, undo, redo
    case spotlight, appSwitcher, minimize, closeWindow, quit, missionControl, showDesktop

    public var keyCode: UInt16 {
        switch self {
        case .escape: return SPPWMacKeyCode.escape
        case .tab, .appSwitcher: return SPPWMacKeyCode.tab
        case .returnKey: return SPPWMacKeyCode.returnKey
        case .delete: return SPPWMacKeyCode.delete
        case .forwardDelete: return SPPWMacKeyCode.forwardDelete
        case .up, .missionControl: return SPPWMacKeyCode.upArrow
        case .down: return SPPWMacKeyCode.downArrow
        case .left: return SPPWMacKeyCode.leftArrow
        case .right: return SPPWMacKeyCode.rightArrow
        case .pageUp: return SPPWMacKeyCode.pageUp
        case .pageDown: return SPPWMacKeyCode.pageDown
        case .home: return SPPWMacKeyCode.home
        case .end: return SPPWMacKeyCode.end
        case .f1: return SPPWMacKeyCode.functionKeys[0]
        case .f2: return SPPWMacKeyCode.functionKeys[1]
        case .f3: return SPPWMacKeyCode.functionKeys[2]
        case .f4: return SPPWMacKeyCode.functionKeys[3]
        case .f5: return SPPWMacKeyCode.functionKeys[4]
        case .f6: return SPPWMacKeyCode.functionKeys[5]
        case .f7: return SPPWMacKeyCode.functionKeys[6]
        case .f8: return SPPWMacKeyCode.functionKeys[7]
        case .f9: return SPPWMacKeyCode.functionKeys[8]
        case .f10: return SPPWMacKeyCode.functionKeys[9]
        case .f11, .showDesktop: return SPPWMacKeyCode.functionKeys[10]
        case .f12: return SPPWMacKeyCode.functionKeys[11]
        case .cut: return 7
        case .copy: return 8
        case .paste: return 9
        case .selectAll: return 0
        case .undo, .redo: return 6
        case .spotlight: return SPPWMacKeyCode.space
        case .minimize: return 46
        case .closeWindow: return 13
        case .quit: return 12
        }
    }

    /// Modifiers built into the shortcut (combined with the sticky bar when sent).
    public var builtInModifiers: SPPWKeyModifiers {
        switch self {
        case .cut, .copy, .paste, .selectAll, .undo, .spotlight, .appSwitcher, .minimize, .closeWindow, .quit:
            return .command
        case .redo: return [.command, .shift]
        case .missionControl: return .control
        default: return []
        }
    }

    public var isShortcut: Bool { !builtInModifiers.isEmpty || self == .showDesktop }

    public func event(adding modifiers: SPPWKeyModifiers) -> SPPWInputEvent {
        .keyPress(keyCode: keyCode, modifiers: builtInModifiers.union(modifiers).rawValue)
    }

    /// Short shortcut caption such as `⌘C`, or `nil` for plain keys.
    public var shortcutCaption: String? {
        switch self {
        case .showDesktop: return "F11"
        case .missionControl: return "⌃↑"
        case .spotlight: return "⌘␣"
        case .appSwitcher: return "⌘⇥"
        case .redo: return "⇧⌘Z"
        default:
            guard builtInModifiers == .command else { return nil }
            let letters: [SPPWSpecialKey: String] = [
                .cut: "X", .copy: "C", .paste: "V", .selectAll: "A", .undo: "Z",
                .minimize: "M", .closeWindow: "W", .quit: "Q"
            ]
            return letters[self].map { "⌘" + $0 }
        }
    }
}

/// Trackpad-mode pointer acceleration: finger travel in device points → host display points.
public enum SPPWPointerAcceleration {
    /// `speed` is the user setting `1...10` (5 = default). Slow, precise moves get the base gain;
    /// fast flicks up to 3.5× more, like a Mac trackpad.
    public static func scaled(
        deltaX: Double,
        deltaY: Double,
        elapsedSeconds: Double,
        speed: Double
    ) -> (dx: Double, dy: Double) {
        let clampedSpeed = min(max(speed, 1), 10)
        let base = 0.6 + 0.25 * clampedSpeed
        let distance = hypot(deltaX, deltaY)
        let velocity = elapsedSeconds > 0 ? distance / elapsedSeconds : 0
        let boost = 1 + min(max((velocity - 150) / 600, 0), 2.5)
        return (deltaX * base * boost, deltaY * base * boost)
    }
}

/// Maps pointer coordinates inside a video view (AppKit bottom-left `+Y` up)
/// through `.resizeAspect` letterboxing and `SPPWVideoOrientation` rotation/flip
/// into top-left normalized `[0, 1]` video-frame coordinates for `SPPWInputEvent`.
public enum SPPWInputCoordinateMapper {
    public struct Result: Sendable, Equatable {
        public let normalizedX: Float
        public let normalizedY: Float
        public let isInsideVideo: Bool

        public init(normalizedX: Float, normalizedY: Float, isInsideVideo: Bool) {
            self.normalizedX = normalizedX
            self.normalizedY = normalizedY
            self.isInsideVideo = isInsideVideo
        }
    }

    /// Maps a point `(viewX, viewY)` in bottom-left (`+Y` up) AppKit view coordinates
    /// inside `(viewWidth, viewHeight)` displaying a `(videoWidth, videoHeight)` frame
    /// with `.resizeAspect` gravity and `orientation` transform.
    ///
    /// Returns `nil` if dimensions are invalid or when `clampOutside == false` and
    /// the point falls in the letterbox/pillarbox margin outside the video frame.
    public static func mapAppKitPoint(
        viewX: Double,
        viewY: Double,
        viewWidth: Double,
        viewHeight: Double,
        videoWidth: Double,
        videoHeight: Double,
        orientation: SPPWVideoOrientation,
        clampOutside: Bool = false
    ) -> Result? {
        guard viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else {
            return nil
        }

        // Layer bounds swap width/height for 90° and 270° rotations, centered at (viewWidth/2, viewHeight/2).
        let layerW = orientation.swapsDimensions ? viewHeight : viewWidth
        let layerH = orientation.swapsDimensions ? viewWidth : viewHeight

        // Forward transform in SampleBufferVideoView:
        //   p_view_centered = R(theta) * S(sx, sy) * p_layer_centered
        // where theta = -orientation.rotationAngleRadians (AppKit +Y up => CW is negative).
        // Exact inverse:
        //   p_layer_centered = S(1/sx, 1/sy) * R(-theta) * p_view_centered
        let vx = viewX - viewWidth * 0.5
        let vy = viewY - viewHeight * 0.5

        let invTheta = orientation.rotationAngleRadians // -(-rotationAngleRadians)
        let cosT = cos(invTheta)
        let sinT = sin(invTheta)
        let rotX = vx * cosT - vy * sinT
        let rotY = vx * sinT + vy * cosT

        let sx = orientation.scaleX == 0 ? 1.0 : orientation.scaleX
        let sy = orientation.scaleY == 0 ? 1.0 : orientation.scaleY
        let lx = (rotX / sx) + layerW * 0.5
        let ly = (rotY / sy) + layerH * 0.5

        // `.resizeAspect` fits (videoWidth, videoHeight) centered inside (layerW, layerH).
        let scale = min(layerW / videoWidth, layerH / videoHeight)
        let fittedW = videoWidth * scale
        let fittedH = videoHeight * scale
        guard fittedW > 0, fittedH > 0 else { return nil }

        let originX = (layerW - fittedW) * 0.5
        let originY = (layerH - fittedH) * 0.5

        let rawNX = (lx - originX) / fittedW
        // Flip Y: AppKit ly=originY+fittedH is top of video -> normalizedY = 0.
        let rawNY = 1.0 - (ly - originY) / fittedH

        let inside = rawNX >= 0.0 && rawNX <= 1.0 && rawNY >= 0.0 && rawNY <= 1.0
        if !inside && !clampOutside {
            return nil
        }

        let clampedX = Float(min(max(rawNX, 0.0), 1.0))
        let clampedY = Float(min(max(rawNY, 0.0), 1.0))
        return Result(normalizedX: clampedX, normalizedY: clampedY, isInsideVideo: inside)
    }

    /// Inverse of `mapUIKitPoint`: the UIKit view point (top-left origin, `+Y` down) where the
    /// normalized video point `(normalizedX, normalizedY)` (`0,0` = top-left of the remote
    /// screen) is displayed, with `.resizeAspect` gravity and the `orientation` transform.
    public static func uiKitViewPoint(
        normalizedX: Double,
        normalizedY: Double,
        viewWidth: Double,
        viewHeight: Double,
        videoWidth: Double,
        videoHeight: Double,
        orientation: SPPWVideoOrientation
    ) -> (x: Double, y: Double)? {
        guard viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else { return nil }
        let layerW = orientation.swapsDimensions ? viewHeight : viewWidth
        let layerH = orientation.swapsDimensions ? viewWidth : viewHeight
        let scale = min(layerW / videoWidth, layerH / videoHeight)
        let fittedW = videoWidth * scale
        let fittedH = videoHeight * scale
        guard fittedW > 0, fittedH > 0 else { return nil }
        // Layer point (AppKit-style, +Y up), centred.
        let lx = (layerW - fittedW) * 0.5 + normalizedX * fittedW
        let ly = (layerH - fittedH) * 0.5 + (1.0 - normalizedY) * fittedH
        let sx = orientation.scaleX == 0 ? 1.0 : orientation.scaleX
        let sy = orientation.scaleY == 0 ? 1.0 : orientation.scaleY
        let px = (lx - layerW * 0.5) * sx
        let py = (ly - layerH * 0.5) * sy
        // Forward rotation by theta = -rotationAngleRadians.
        let angle = orientation.rotationAngleRadians
        let cosA = cos(angle)
        let sinA = sin(angle)
        let vx = px * cosA + py * sinA
        let vy = -px * sinA + py * cosA
        return (vx + viewWidth * 0.5, viewHeight - (vy + viewHeight * 0.5))
    }

    /// Same as `mapAppKitPoint` for UIKit views (top-left origin, `+Y` down).
    public static func mapUIKitPoint(
        viewX: Double,
        viewY: Double,
        viewWidth: Double,
        viewHeight: Double,
        videoWidth: Double,
        videoHeight: Double,
        orientation: SPPWVideoOrientation,
        clampOutside: Bool = false
    ) -> Result? {
        mapAppKitPoint(
            viewX: viewX,
            viewY: viewHeight - viewY,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            orientation: orientation,
            clampOutside: clampOutside
        )
    }
}

// MARK: - Rotated and zoomed video: input mapping

extension SPPWVideoOrientation {
    /// Converts a motion seen on screen (trackpad swipe, mouse motion, scroll; `+X` right,
    /// `+Y` down) into the video's own axes, so that with the video turned 90° a swipe
    /// towards the picture's top still moves the remote pointer up. Undoes the display
    /// transform (rotation clockwise, then the horizontal mirror applied first in layer space).
    public func videoDelta(screenDX: Double, screenDY: Double) -> (dx: Double, dy: Double) {
        var x: Double
        let y: Double
        switch quarterTurnsClockwise {
        case 1:
            x = screenDY
            y = -screenDX
        case 2:
            x = -screenDX
            y = -screenDY
        case 3:
            x = -screenDY
            y = screenDX
        default:
            x = screenDX
            y = screenDY
        }
        if isFlippedHorizontally { x = -x }
        return (x, y)
    }

    /// Insets of a container rotated with the video (`quarterTurnsClockwise`), derived from
    /// the screen's insets: with a 90° turn the container's top edge lies on the screen's right.
    public func rotatedInsets(
        top: Double,
        left: Double,
        bottom: Double,
        right: Double
    ) -> (top: Double, left: Double, bottom: Double, right: Double) {
        switch quarterTurnsClockwise {
        case 1: return (right, top, left, bottom)
        case 2: return (bottom, right, top, left)
        case 3: return (left, bottom, right, top)
        default: return (top, left, bottom, right)
        }
    }
}

/// A pointer the receiver draws itself and sends to the remote Mac as absolute positions
/// (`.pointerMove`), so what the user sees is exactly where the Mac clicks, without the
/// delay of the Mac cursor in the video. Relative input (trackpad swipes, an iPad mouse)
/// moves it across the picture as displayed: a swipe as long as the shown video's width
/// crosses the whole remote screen at speed 1.
public struct SPPWLocalPointer: Sendable, Equatable {
    /// Position on the remote screen, `0...1`, `0,0` = top-left.
    public var normalizedX: Double
    public var normalizedY: Double

    public init(normalizedX: Double = 0.5, normalizedY: Double = 0.5) {
        self.normalizedX = min(max(normalizedX, 0), 1)
        self.normalizedY = min(max(normalizedY, 0), 1)
    }

    /// Size of the displayed (aspect-fit, unzoomed) video in its own axes, in view points.
    public static func displayedVideoSize(
        viewWidth: Double,
        viewHeight: Double,
        videoWidth: Double,
        videoHeight: Double,
        orientation: SPPWVideoOrientation
    ) -> (width: Double, height: Double)? {
        guard viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else { return nil }
        let layerW = orientation.swapsDimensions ? viewHeight : viewWidth
        let layerH = orientation.swapsDimensions ? viewWidth : viewHeight
        let scale = min(layerW / videoWidth, layerH / videoHeight)
        return (videoWidth * scale, videoHeight * scale)
    }

    /// Moves by a motion already in the video's axes (`SPPWVideoOrientation.videoDelta`),
    /// in view points of the displayed video, clamped to the remote screen.
    public mutating func move(
        videoDX: Double,
        videoDY: Double,
        displayedVideoWidth: Double,
        displayedVideoHeight: Double
    ) {
        guard displayedVideoWidth > 0, displayedVideoHeight > 0 else { return }
        normalizedX = min(max(normalizedX + videoDX / displayedVideoWidth, 0), 1)
        normalizedY = min(max(normalizedY + videoDY / displayedVideoHeight, 0), 1)
    }

    public var moveEvent: SPPWInputEvent {
        .pointerMove(normalizedX: Float(normalizedX), normalizedY: Float(normalizedY))
    }
}

/// Receiver-side magnifier (1×–2×) for the video view.
///
/// `scale` magnifies the view about its center and `offsetX`/`offsetY` translate the
/// magnified content, in the caller's view points (UIKit or AppKit axes, used consistently).
/// The content always covers the view, so no black margin appears while zoomed. Input
/// mapping undoes the zoom with `contentPoint(...)` before `SPPWInputCoordinateMapper`.
public struct SPPWViewZoom: Equatable, Sendable {
    public static let minimumScale = 1.0
    public static let maximumScale = 2.0

    public private(set) var scale: Double = 1
    public private(set) var offsetX: Double = 0
    public private(set) var offsetY: Double = 0

    public init() {}

    public init(scale: Double, offsetX: Double = 0, offsetY: Double = 0, viewWidth: Double, viewHeight: Double) {
        self.scale = Self.clampedScale(scale)
        self.offsetX = offsetX
        self.offsetY = offsetY
        clampOffset(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    public var isZoomed: Bool { scale > 1.0005 }

    public static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return minimumScale }
        return min(max(value, minimumScale), maximumScale)
    }

    /// Multiplies the scale by `factor`, keeping the content under `(anchorX, anchorY)` in place.
    public mutating func zoom(by factor: Double, anchorX: Double, anchorY: Double, viewWidth: Double, viewHeight: Double) {
        guard factor.isFinite, factor > 0 else { return }
        setScale(scale * factor, anchorX: anchorX, anchorY: anchorY, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Sets an absolute scale, keeping the content under the anchor in place.
    public mutating func setScale(_ newScale: Double, anchorX: Double, anchorY: Double, viewWidth: Double, viewHeight: Double) {
        let target = Self.clampedScale(newScale)
        let content = contentPoint(viewX: anchorX, viewY: anchorY, viewWidth: viewWidth, viewHeight: viewHeight)
        let cx = viewWidth * 0.5
        let cy = viewHeight * 0.5
        scale = target
        offsetX = anchorX - cx - target * (content.x - cx)
        offsetY = anchorY - cy - target * (content.y - cy)
        clampOffset(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Moves the magnified content by a view-space delta (two-finger drag, scroll).
    public mutating func pan(dx: Double, dy: Double, viewWidth: Double, viewHeight: Double) {
        offsetX += dx
        offsetY += dy
        clampOffset(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Viewport that follows an absolute pointer: the point under the pointer is the same
    /// content point as without zoom, so the pointer still reaches every edge of the video.
    public mutating func follow(viewX: Double, viewY: Double, viewWidth: Double, viewHeight: Double) {
        offsetX = (viewWidth * 0.5 - viewX) * (scale - 1)
        offsetY = (viewHeight * 0.5 - viewY) * (scale - 1)
        clampOffset(viewWidth: viewWidth, viewHeight: viewHeight)
    }

    public mutating func reset() {
        scale = 1
        offsetX = 0
        offsetY = 0
    }

    /// The unzoomed view point shown at `(viewX, viewY)`.
    public func contentPoint(viewX: Double, viewY: Double, viewWidth: Double, viewHeight: Double) -> (x: Double, y: Double) {
        let cx = viewWidth * 0.5
        let cy = viewHeight * 0.5
        return ((viewX - cx - offsetX) / scale + cx, (viewY - cy - offsetY) / scale + cy)
    }

    /// Inverse of `contentPoint`: where an unzoomed view point appears in the zoomed view.
    public func viewPoint(contentX: Double, contentY: Double, viewWidth: Double, viewHeight: Double) -> (x: Double, y: Double) {
        let cx = viewWidth * 0.5
        let cy = viewHeight * 0.5
        return (cx + offsetX + scale * (contentX - cx), cy + offsetY + scale * (contentY - cy))
    }

    /// Re-clamps after the view size changed (rotation, window resize).
    public mutating func clampOffset(viewWidth: Double, viewHeight: Double) {
        let limitX = max(0, (scale - 1) * viewWidth * 0.5)
        let limitY = max(0, (scale - 1) * viewHeight * 0.5)
        offsetX = min(max(offsetX, -limitX), limitX)
        offsetY = min(max(offsetY, -limitY), limitY)
        if !isZoomed {
            scale = 1
            offsetX = 0
            offsetY = 0
        }
    }
}

#if os(macOS)
/// Injects received `SPPWInputEvent` payloads into the macOS WindowServer via `CGEvent`.
///
/// For live server sessions, prefer `SPPWMacInputController` so held buttons/keys,
/// mouse drags, multi-click state, modifier flags, and disconnect cleanup are tracked.
public enum SPPWMacInputInjector {
    private static let sharedController = SPPWMacInputController()

    /// Returns `true` when the current process has macOS Accessibility permission
    /// (`Privacy & Security → Accessibility`), required to post synthetic `CGEvent`s.
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts macOS to show the Accessibility permission dialog if not yet granted.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func inject(_ event: SPPWInputEvent, displayID: CGDirectDisplayID = CGMainDisplayID()) {
        sharedController.inject(event, displayID: displayID)
    }

    public static func releaseAll(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        sharedController.releaseAll(displayID: displayID)
    }
}

/// Stateful, thread-safe macOS `CGEvent` input controller.
///
/// Tracks held mouse buttons, held keys, active modifiers, and multi-click state so that:
/// - pointer movement while a button is down posts `*MouseDragged` instead of `.mouseMoved`;
/// - rapid clicks at the same spot increment `mouseEventClickState` (double/triple click);
/// - modifier keys post `.flagsChanged` and propagate flags to subsequent mouse/scroll/key events;
/// - redundant release packets (sent for UDP reliability) are deduplicated;
/// - `releaseAll()` releases every held button and key on disconnect, disable, or `.releaseAll`.
public final class SPPWMacInputController: @unchecked Sendable {
    public struct StateSnapshot: Sendable, Equatable {
        public let heldButtons: Set<UInt8>
        public let heldKeys: Set<UInt16>
        public let activeModifierRawValue: UInt64
        public let currentClickState: Int64
    }

    /// Device-independent modifier bitmask shared by `NSEvent.ModifierFlags` and `CGEventFlags`.
    public static let deviceIndependentModifierMask: UInt64 = 0x00FF_0000

    private static let doubleClickIntervalNanos: UInt64 = 500_000_000
    private static let doubleClickMaxDistance: CGFloat = 6.0

    private let lock = NSLock()
    private let postEvents: Bool
    private var heldButtons: Set<UInt8> = []
    private var heldKeys: Set<UInt16> = []
    private var activeModifiers: CGEventFlags = []
    private var lastCursorPoint: CGPoint?
    private var lastClickButton: UInt8?
    private var lastClickPoint: CGPoint = .zero
    private var lastClickNanos: UInt64 = 0
    private var currentClickState: Int64 = 1
    private var activeTouchDown: Bool = false

    public init(postEvents: Bool = true) {
        self.postEvents = postEvents
    }

    public var stateSnapshot: StateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StateSnapshot(
            heldButtons: heldButtons,
            heldKeys: heldKeys,
            activeModifierRawValue: activeModifiers.rawValue,
            currentClickState: currentClickState
        )
    }

    /// Maps normalized top-left `[0, 1]` coordinates into global Quartz display coordinates,
    /// clamping to the interior of `displayBounds` so edges stay on the target display.
    public static func screenPoint(normalizedX: Float, normalizedY: Float, displayBounds: CGRect) -> CGPoint {
        let safeX = normalizedX.isFinite ? Double(min(max(normalizedX, 0.0), 1.0)) : 0.5
        let safeY = normalizedY.isFinite ? Double(min(max(normalizedY, 0.0), 1.0)) : 0.5
        let maxOffsetX = max(Double(displayBounds.width) - 1.0, 0.0)
        let maxOffsetY = max(Double(displayBounds.height) - 1.0, 0.0)
        return CGPoint(
            x: Double(displayBounds.origin.x) + safeX * maxOffsetX,
            y: Double(displayBounds.origin.y) + safeY * maxOffsetY
        )
    }

    /// Returns the modifier flag corresponding to a macOS virtual modifier keyCode, or `nil` for regular keys.
    public static func modifierFlag(forKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand      // Right/Left Command
        case 56, 60: return .maskShift        // Left/Right Shift
        case 57:     return .maskAlphaShift   // Caps Lock
        case 58, 61: return .maskAlternate    // Left/Right Option
        case 59, 62: return .maskControl      // Left/Right Control
        case 63:     return .maskSecondaryFn  // Fn / Globe
        default:     return nil
        }
    }

    public func inject(
        _ event: SPPWInputEvent,
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let resolvedDisplayID = displayID == kCGNullDirectDisplay ? CGMainDisplayID() : displayID
        let bounds = CGDisplayBounds(resolvedDisplayID)
        let safeBounds = (bounds.width > 0 && bounds.height > 0) ? bounds : CGRect(x: 0, y: 0, width: 1920, height: 1080)
        inject(event, displayBounds: safeBounds, nowNanoseconds: nowNanoseconds)
    }

    public func inject(
        _ event: SPPWInputEvent,
        displayBounds: CGRect,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        defer { lock.unlock() }

        switch event.unwrapped {
        case let .pointerMove(nx, ny):
            let pt = Self.screenPoint(normalizedX: nx, normalizedY: ny, displayBounds: displayBounds)
            lastCursorPoint = pt
            let (mouseType, cgButton, buttonNumber): (CGEventType, CGMouseButton, Int64?)
            if heldButtons.contains(0) {
                (mouseType, cgButton, buttonNumber) = (.leftMouseDragged, .left, nil)
            } else if heldButtons.contains(1) {
                (mouseType, cgButton, buttonNumber) = (.rightMouseDragged, .right, nil)
            } else if let other = heldButtons.min() {
                (mouseType, cgButton, buttonNumber) = (
                    .otherMouseDragged,
                    CGMouseButton(rawValue: UInt32(other)) ?? .center,
                    Int64(other)
                )
            } else {
                (mouseType, cgButton, buttonNumber) = (.mouseMoved, .left, nil)
            }
            postMouseEvent(
                type: mouseType,
                point: pt,
                button: cgButton,
                buttonNumber: buttonNumber,
                clickState: nil,
                flags: activeModifiers
            )

        case let .mouseButton(button, isDown, nx, ny):
            let pt = Self.screenPoint(normalizedX: nx, normalizedY: ny, displayBounds: displayBounds)
            lastCursorPoint = pt
            applyButtonLocked(button: button, isDown: isDown, point: pt, nowNanoseconds: nowNanoseconds)

        case let .scroll(dx, dy):
            guard postEvents else { return }
            let wheelY = Int32(clamping: Int(dy.isFinite ? dy.rounded() : 0))
            let wheelX = Int32(clamping: Int(dx.isFinite ? dx.rounded() : 0))
            guard wheelY != 0 || wheelX != 0 else { return }
            if let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: wheelY,
                wheel2: wheelX,
                wheel3: 0
            ) {
                if !activeModifiers.isEmpty {
                    cgEvent.flags = activeModifiers
                }
                cgEvent.post(tap: .cghidEventTap)
            }

        case let .key(keyCode, isDown, modifiers):
            let sanitizedFlags = CGEventFlags(rawValue: UInt64(modifiers) & Self.deviceIndependentModifierMask)
            activeModifiers = sanitizedFlags

            if Self.modifierFlag(forKeyCode: keyCode) != nil {
                if isDown {
                    heldKeys.insert(keyCode)
                } else {
                    heldKeys.remove(keyCode)
                }
                postModifierEvent(keyCode: keyCode, isDown: isDown, flags: sanitizedFlags)
                return
            }

            if !isDown && !heldKeys.contains(keyCode) {
                // Deduplicate redundant keyUp packets sent for UDP reliability.
                return
            }
            // A second keyDown for a held key is the client's auto-repeat.
            let isRepeat = isDown && heldKeys.contains(keyCode)
            if isDown {
                heldKeys.insert(keyCode)
            } else {
                heldKeys.remove(keyCode)
            }
            postKeyEvent(keyCode: keyCode, isDown: isDown, flags: sanitizedFlags, autorepeat: isRepeat)

        case let .touch(points):
            guard let primary = points.first else { return }
            let pt = Self.screenPoint(normalizedX: primary.normalizedX, normalizedY: primary.normalizedY, displayBounds: displayBounds)
            lastCursorPoint = pt
            let phase = SPPWTouchPhase(rawValue: primary.phase) ?? .moved
            let type: CGEventType
            switch phase {
            case .began:
                activeTouchDown = true
                heldButtons.insert(0)
                type = .leftMouseDown
            case .moved:
                type = activeTouchDown ? .leftMouseDragged : .mouseMoved
            case .ended, .cancelled:
                guard activeTouchDown || heldButtons.contains(0) else { return }
                activeTouchDown = false
                heldButtons.remove(0)
                type = .leftMouseUp
            }
            postMouseEvent(
                type: type,
                point: pt,
                button: .left,
                buttonNumber: nil,
                clickState: phase == .moved ? nil : 1,
                flags: activeModifiers
            )

        case .releaseAll:
            releaseAllLocked(displayBounds: displayBounds)

        case let .text(text):
            postTextLocked(text)

        case let .keyPress(keyCode, modifiers):
            let flags = CGEventFlags(rawValue: UInt64(modifiers) & Self.deviceIndependentModifierMask)
            guard Self.modifierFlag(forKeyCode: keyCode) == nil else { return }
            postKeyEvent(keyCode: keyCode, isDown: true, flags: flags)
            postKeyEvent(keyCode: keyCode, isDown: false, flags: flags)

        case let .pointerDelta(dx, dy):
            guard dx.isFinite, dy.isFinite else { return }
            let current = currentCursorPoint(displayBounds: displayBounds)
            let pt = Self.clampedPoint(
                CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy)),
                to: displayBounds
            )
            lastCursorPoint = pt
            let (mouseType, cgButton, buttonNumber) = dragDescriptorLocked()
            postMouseEvent(
                type: mouseType,
                point: pt,
                button: cgButton,
                buttonNumber: buttonNumber,
                clickState: nil,
                flags: activeModifiers,
                delta: (Int64(dx.rounded()), Int64(dy.rounded()))
            )

        case let .buttonAtCursor(button, isDown):
            let pt = currentCursorPoint(displayBounds: displayBounds)
            lastCursorPoint = pt
            applyButtonLocked(button: button, isDown: isDown, point: pt, nowNanoseconds: nowNanoseconds)

        case let .clickAtCursor(button):
            let pt = currentCursorPoint(displayBounds: displayBounds)
            lastCursorPoint = pt
            applyButtonLocked(button: button, isDown: true, point: pt, nowNanoseconds: nowNanoseconds)
            applyButtonLocked(button: button, isDown: false, point: pt, nowNanoseconds: nowNanoseconds)

        case .sequenced:
            // Unwrapped above; sequence filtering happens per client in the server.
            break

        case .cursorVisibility:
            // Capture setting, applied by the server (ScreenCaptureKit `showsCursor`).
            break
        }
    }

    /// Splits text into `CGEvent` Unicode chunks of at most this many UTF-16 units (WindowServer limit).
    public static let maximumUnicodeUnitsPerEvent = 20

    /// Groups whole characters into UTF-16 chunks for `CGEventKeyboardSetUnicodeString`, turning
    /// `\n`/`\r` into Return and `\t` into Tab key taps so every app sees real line breaks.
    public enum TextSegment: Equatable, Sendable {
        case unicode([UniChar])
        case key(UInt16)
    }

    public static func textSegments(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var buffer: [UniChar] = []
        func flush() {
            if !buffer.isEmpty { segments.append(.unicode(buffer)); buffer.removeAll() }
        }
        for character in text {
            switch character {
            case "\n", "\r", "\r\n":
                flush(); segments.append(.key(SPPWMacKeyCode.returnKey))
            case "\t":
                flush(); segments.append(.key(SPPWMacKeyCode.tab))
            default:
                let units = Array(String(character).utf16)
                if buffer.count + units.count > maximumUnicodeUnitsPerEvent { flush() }
                buffer.append(contentsOf: units)
            }
        }
        flush()
        return segments
    }

    private func postTextLocked(_ text: String) {
        for segment in Self.textSegments(text) {
            switch segment {
            case let .key(code):
                postKeyEvent(keyCode: code, isDown: true, flags: [])
                postKeyEvent(keyCode: code, isDown: false, flags: [])
            case let .unicode(units):
                guard postEvents else { continue }
                for isDown in [true, false] {
                    guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
                    cgEvent.flags = []
                    units.withUnsafeBufferPointer { buffer in
                        cgEvent.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    }
                    cgEvent.post(tap: .cghidEventTap)
                }
            }
        }
    }

    private func applyButtonLocked(button: UInt8, isDown: Bool, point pt: CGPoint, nowNanoseconds: UInt64) {
        if !isDown && !heldButtons.contains(button) {
            // Deduplicate redundant mouseUp packets sent for UDP reliability.
            return
        }

        let clickState: Int64
        if isDown {
            if lastClickButton == button,
               nowNanoseconds >= lastClickNanos,
               (nowNanoseconds - lastClickNanos) <= Self.doubleClickIntervalNanos,
               hypot(pt.x - lastClickPoint.x, pt.y - lastClickPoint.y) <= Self.doubleClickMaxDistance {
                currentClickState = min(currentClickState + 1, 3)
            } else {
                currentClickState = 1
            }
            lastClickButton = button
            lastClickPoint = pt
            lastClickNanos = nowNanoseconds
            heldButtons.insert(button)
            clickState = currentClickState
        } else {
            heldButtons.remove(button)
            clickState = currentClickState
        }

        let (mouseType, cgButton, buttonNumber) = Self.mouseEventDescriptor(button: button, isDown: isDown)
        postMouseEvent(
            type: mouseType,
            point: pt,
            button: cgButton,
            buttonNumber: buttonNumber,
            clickState: clickState,
            flags: activeModifiers
        )
    }

    private func dragDescriptorLocked() -> (CGEventType, CGMouseButton, Int64?) {
        if heldButtons.contains(0) { return (.leftMouseDragged, .left, nil) }
        if heldButtons.contains(1) { return (.rightMouseDragged, .right, nil) }
        if let other = heldButtons.min() {
            return (.otherMouseDragged, CGMouseButton(rawValue: UInt32(other)) ?? .center, Int64(other))
        }
        return (.mouseMoved, .left, nil)
    }

    /// The live cursor position (it may have moved locally), clamped to the streamed display.
    /// Without event posting (tests) the last injected position is used.
    private func currentCursorPoint(displayBounds: CGRect) -> CGPoint {
        let fallback = lastCursorPoint ?? CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        let live = postEvents ? (CGEvent(source: nil)?.location ?? fallback) : fallback
        return Self.clampedPoint(live, to: displayBounds)
    }

    /// Clamps a global Quartz point to the interior of `bounds`.
    public static func clampedPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        let maxX = bounds.origin.x + max(bounds.width - 1, 0)
        let maxY = bounds.origin.y + max(bounds.height - 1, 0)
        let x = point.x.isFinite ? min(max(point.x, bounds.origin.x), maxX) : bounds.midX
        let y = point.y.isFinite ? min(max(point.y, bounds.origin.y), maxY) : bounds.midY
        return CGPoint(x: x, y: y)
    }

    /// Last cursor position set by injected events (diagnostics and tests).
    public var lastInjectedCursorPoint: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return lastCursorPoint
    }

    public func releaseAll(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        let resolvedDisplayID = displayID == kCGNullDirectDisplay ? CGMainDisplayID() : displayID
        let bounds = CGDisplayBounds(resolvedDisplayID)
        let safeBounds = (bounds.width > 0 && bounds.height > 0) ? bounds : CGRect(x: 0, y: 0, width: 1920, height: 1080)
        releaseAll(displayBounds: safeBounds)
    }

    public func releaseAll(displayBounds: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        releaseAllLocked(displayBounds: displayBounds)
    }

    private func releaseAllLocked(displayBounds: CGRect) {
        let buttonsToRelease = heldButtons.sorted()
        let keysToRelease = heldKeys.sorted()
        let hadModifiers = !activeModifiers.isEmpty
        heldButtons.removeAll()
        heldKeys.removeAll()
        activeModifiers = []
        activeTouchDown = false
        lastClickButton = nil
        currentClickState = 1

        let releasePoint = lastCursorPoint ?? CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        for button in buttonsToRelease {
            let (mouseType, cgButton, buttonNumber) = Self.mouseEventDescriptor(button: button, isDown: false)
            postMouseEvent(
                type: mouseType,
                point: releasePoint,
                button: cgButton,
                buttonNumber: buttonNumber,
                clickState: 1,
                flags: []
            )
        }

        var modifierKeys: [UInt16] = []
        for keyCode in keysToRelease {
            if Self.modifierFlag(forKeyCode: keyCode) != nil {
                modifierKeys.append(keyCode)
            } else {
                postKeyEvent(keyCode: keyCode, isDown: false, flags: [])
            }
        }
        for modKey in modifierKeys {
            postModifierEvent(keyCode: modKey, isDown: false, flags: [])
        }
        if modifierKeys.isEmpty && hadModifiers {
            postModifierEvent(keyCode: 55, isDown: false, flags: [])
        }
    }

    private static func mouseEventDescriptor(button: UInt8, isDown: Bool) -> (CGEventType, CGMouseButton, Int64?) {
        switch button {
        case 0:
            return (isDown ? .leftMouseDown : .leftMouseUp, .left, nil)
        case 1:
            return (isDown ? .rightMouseDown : .rightMouseUp, .right, nil)
        default:
            let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
            return (isDown ? .otherMouseDown : .otherMouseUp, cgButton, Int64(button))
        }
    }

    private func postMouseEvent(
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        buttonNumber: Int64?,
        clickState: Int64?,
        flags: CGEventFlags,
        delta: (Int64, Int64)? = nil
    ) {
        guard postEvents else { return }
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if let buttonNumber {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        }
        if let clickState {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if let delta {
            cgEvent.setIntegerValueField(.mouseEventDeltaX, value: delta.0)
            cgEvent.setIntegerValueField(.mouseEventDeltaY, value: delta.1)
        }
        if !flags.isEmpty {
            cgEvent.flags = flags
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(keyCode: UInt16, isDown: Bool, flags: CGEventFlags, autorepeat: Bool = false) {
        guard postEvents else { return }
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: isDown
        ) else { return }
        cgEvent.flags = flags.union(CGEventFlags(rawValue: SPPWMacKeyCode.implicitFlags(forKeyCode: keyCode)))
        if autorepeat {
            cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    private func postModifierEvent(keyCode: UInt16, isDown: Bool, flags: CGEventFlags) {
        guard postEvents else { return }
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: isDown
        ) else { return }
        cgEvent.type = .flagsChanged
        cgEvent.flags = flags
        cgEvent.post(tap: .cghidEventTap)
    }
}
#endif

// MARK: - SPPW/1 Clipboard Channel (`kind = 10` `.clipboard`, bidirectional)

public enum SPPWClipboardFormat: UInt8, Sendable, Equatable {
    case utf8Text = 1
    case png = 2

    /// Largest clipboard item each side sends or accepts.
    public var maximumByteCount: Int {
        switch self {
        case .utf8Text: return 1 << 20
        case .png: return 8 << 20
        }
    }
}

/// One clipboard item: UTF-8 text or a PNG image.
public struct SPPWClipboardContent: Sendable, Equatable {
    public let format: SPPWClipboardFormat
    public let data: Data

    public init(format: SPPWClipboardFormat, data: Data) {
        self.format = format
        self.data = data
    }

    public init(text: String) {
        self.init(format: .utf8Text, data: Data(text.utf8))
    }

    public var text: String? {
        format == .utf8Text ? String(data: data, encoding: .utf8) : nil
    }

    /// FNV-1a 64-bit digest of format + bytes, used to stop echo loops between the two pasteboards.
    public var digest: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        hash = (hash ^ UInt64(format.rawValue)) &* 0x0000_0100_0000_01B3
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Clipboard datagram payload: 16-byte header (big-endian) + chunk bytes.
///
/// | Offset | Size | Field |
/// | 0 | 1 | `op` (0 subscribe, 1 chunk, 2 ack) |
/// | 1 | 1 | `format` (chunk) or `enabled` (subscribe) |
/// | 2 | 2 | `chunkIndex` |
/// | 4 | 2 | `chunkCount` |
/// | 6 | 2 | reserved (0) |
/// | 8 | 4 | `transferID` |
/// | 12 | 4 | `totalByteCount` |
public enum SPPWClipboardMessage: Sendable, Equatable {
    case subscribe(enabled: Bool)
    case chunk(transferID: UInt32, format: SPPWClipboardFormat, index: UInt16, count: UInt16, totalByteCount: UInt32, bytes: Data)
    case ack(transferID: UInt32)

    public static let headerByteCount = 16

    private enum Op: UInt8 {
        case subscribe = 0
        case chunk = 1
        case ack = 2
    }

    public func encoded() -> Data {
        var data = Data(count: Self.headerByteCount)
        func put16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(truncatingIfNeeded: value >> 8)
            data[offset + 1] = UInt8(truncatingIfNeeded: value)
        }
        func put32(_ value: UInt32, at offset: Int) {
            put16(UInt16(truncatingIfNeeded: value >> 16), at: offset)
            put16(UInt16(truncatingIfNeeded: value), at: offset + 2)
        }
        switch self {
        case let .subscribe(enabled):
            data[0] = Op.subscribe.rawValue
            data[1] = enabled ? 1 : 0
        case let .chunk(transferID, format, index, count, total, bytes):
            data[0] = Op.chunk.rawValue
            data[1] = format.rawValue
            put16(index, at: 2)
            put16(count, at: 4)
            put32(transferID, at: 8)
            put32(total, at: 12)
            data.append(bytes)
        case let .ack(transferID):
            data[0] = Op.ack.rawValue
            put32(transferID, at: 8)
        }
        return data
    }

    public init?(parsing payload: Data) {
        guard payload.count >= Self.headerByteCount, let op = Op(rawValue: payload[payload.startIndex]) else { return nil }
        let bytes = [UInt8](payload)
        func u16(_ offset: Int) -> UInt16 { (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1]) }
        func u32(_ offset: Int) -> UInt32 { (UInt32(u16(offset)) << 16) | UInt32(u16(offset + 2)) }
        switch op {
        case .subscribe:
            self = .subscribe(enabled: bytes[1] != 0)
        case .ack:
            self = .ack(transferID: u32(8))
        case .chunk:
            guard let format = SPPWClipboardFormat(rawValue: bytes[1]) else { return nil }
            let index = u16(2)
            let count = u16(4)
            let total = u32(12)
            guard count > 0, index < count, Int(total) <= format.maximumByteCount else { return nil }
            self = .chunk(
                transferID: u32(8),
                format: format,
                index: index,
                count: count,
                totalByteCount: total,
                bytes: Data(bytes[Self.headerByteCount...])
            )
        }
    }

    /// Splits `content` into chunk messages of at most `maxChunkBytes` each.
    public static func chunks(for content: SPPWClipboardContent, transferID: UInt32, maxChunkBytes: Int) -> [SPPWClipboardMessage] {
        let size = max(maxChunkBytes, 64)
        let total = content.data.count
        let count = max(1, (total + size - 1) / size)
        guard count <= Int(UInt16.max) else { return [] }
        return (0..<count).map { index in
            let start = content.data.startIndex + index * size
            let end = min(start + size, content.data.endIndex)
            return .chunk(
                transferID: transferID,
                format: content.format,
                index: UInt16(index),
                count: UInt16(count),
                totalByteCount: UInt32(total),
                bytes: Data(content.data[start..<end])
            )
        }
    }
}

/// Collects clipboard chunks (any order, duplicates allowed) into complete items.
public struct SPPWClipboardReassembler: Sendable {
    private struct Partial: Sendable {
        let format: SPPWClipboardFormat
        let count: Int
        let total: Int
        var chunks: [Data?]
        var received: Int
        var updatedNanos: UInt64
    }

    public static let maximumPartialTransfers = 4
    public static let staleAfterNanos: UInt64 = 10_000_000_000

    private var partials: [UInt32: Partial] = [:]
    private var completed: [UInt32] = []

    public init() {}

    public enum Result: Sendable, Equatable {
        /// Still waiting for chunks.
        case pending
        /// Already delivered earlier (a retransmission); acknowledge again.
        case duplicate
        case complete(SPPWClipboardContent)
        case invalid
    }

    public mutating func add(
        transferID: UInt32,
        format: SPPWClipboardFormat,
        index: UInt16,
        count: UInt16,
        totalByteCount: UInt32,
        bytes: Data,
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Result {
        if completed.contains(transferID) { return .duplicate }
        partials = partials.filter { nowNanos &- $0.value.updatedNanos < Self.staleAfterNanos || $0.key == transferID }
        var partial = partials[transferID] ?? Partial(
            format: format,
            count: Int(count),
            total: Int(totalByteCount),
            chunks: Array(repeating: nil, count: Int(count)),
            received: 0,
            updatedNanos: nowNanos
        )
        guard partial.format == format, partial.count == Int(count), partial.total == Int(totalByteCount),
              Int(index) < partial.count else { return .invalid }
        if partial.chunks[Int(index)] == nil {
            partial.chunks[Int(index)] = bytes
            partial.received += 1
        }
        partial.updatedNanos = nowNanos
        guard partial.received == partial.count else {
            partials[transferID] = partial
            if partials.count > Self.maximumPartialTransfers,
               let oldest = partials.min(by: { $0.value.updatedNanos < $1.value.updatedNanos })?.key {
                partials.removeValue(forKey: oldest)
            }
            return .pending
        }
        partials.removeValue(forKey: transferID)
        completed.append(transferID)
        if completed.count > 32 { completed.removeFirst() }
        var data = Data(capacity: partial.total)
        for chunk in partial.chunks { data.append(chunk ?? Data()) }
        guard data.count == partial.total else { return .invalid }
        return .complete(SPPWClipboardContent(format: format, data: data))
    }
}

/// Reliable clipboard transfer over `SPPW/1` datagrams, one per peer.
///
/// Outgoing items are sent as chunks and retransmitted (the receiver keeps partial chunks, so each
/// round fills the holes) until the peer acknowledges or the attempts run out. A newer item cancels
/// an older one still in flight. Items equal to the last one sent or received are not repeated,
/// which stops echo loops between the two pasteboards (and with Universal Clipboard).
public final class SPPWClipboardChannel: @unchecked Sendable {
    public enum Incoming: Sendable, Equatable {
        case none
        case subscription(enabled: Bool)
        case content(SPPWClipboardContent)
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sppw.clipboard.channel", qos: .utility)
    private let send: @Sendable (Data) -> Void
    private let maxChunkBytes: Int
    private let retransmitIntervalNanos: UInt64
    private let maxAttempts: Int
    private var nextTransferID = UInt32.random(in: 1...UInt32.max / 2)
    private var reassembler = SPPWClipboardReassembler()
    private var lastDigest: UInt64?
    private var pending: (id: UInt32, chunks: [Data], attempts: Int)?
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - maxChunkBytes: chunk payload per datagram (MTU − 40-byte header − 16-byte clipboard header).
    ///   - send: sends one clipboard payload (the caller adds the `SPPW/1` header for its peer).
    public init(
        maxChunkBytes: Int = 1100,
        retransmitIntervalNanos: UInt64 = 400_000_000,
        maxAttempts: Int = 5,
        send: @escaping @Sendable (Data) -> Void
    ) {
        self.maxChunkBytes = maxChunkBytes
        self.retransmitIntervalNanos = retransmitIntervalNanos
        self.maxAttempts = maxAttempts
        self.send = send
    }

    deinit {
        timer?.cancel()
    }

    /// Chunk payload size for a datagram budget (`mtu`).
    public static func chunkBytes(forMTU mtu: Int) -> Int {
        max(256, min(mtu, 9000) - SPPWDatagramHeader.byteCount - SPPWClipboardMessage.headerByteCount)
    }

    /// Sends a subscription change (receiver → server).
    public func sendSubscription(enabled: Bool) {
        send(SPPWClipboardMessage.subscribe(enabled: enabled).encoded())
    }

    /// Sends a local clipboard item to the peer. Returns `false` when it is empty, too large,
    /// or identical to the last item exchanged.
    @discardableResult
    public func offer(_ content: SPPWClipboardContent) -> Bool {
        guard !content.data.isEmpty, content.data.count <= content.format.maximumByteCount else { return false }
        let digest = content.digest
        lock.lock()
        guard digest != lastDigest else {
            lock.unlock()
            return false
        }
        lastDigest = digest
        let id = nextTransferID
        nextTransferID &+= 1
        if nextTransferID == 0 { nextTransferID = 1 }
        let chunks = SPPWClipboardMessage.chunks(for: content, transferID: id, maxChunkBytes: maxChunkBytes).map { $0.encoded() }
        pending = (id, chunks, 1)
        lock.unlock()
        transmit(chunks)
        scheduleRetransmit()
        return true
    }

    /// Records an item that is already on the local pasteboard (written from the peer or seen at
    /// start) so it is not sent back.
    public func noteLocalContent(_ content: SPPWClipboardContent) {
        lock.lock()
        lastDigest = content.digest
        lock.unlock()
    }

    /// Handles a received clipboard payload; returns a completed new item or a subscription change.
    public func receive(_ payload: Data, nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Incoming {
        guard let message = SPPWClipboardMessage(parsing: payload) else { return .none }
        switch message {
        case let .subscribe(enabled):
            return .subscription(enabled: enabled)
        case let .ack(transferID):
            lock.lock()
            if pending?.id == transferID { pending = nil }
            lock.unlock()
            return .none
        case let .chunk(transferID, format, index, count, total, bytes):
            lock.lock()
            let result = reassembler.add(
                transferID: transferID,
                format: format,
                index: index,
                count: count,
                totalByteCount: total,
                bytes: bytes,
                nowNanos: nowNanos
            )
            var delivered: SPPWClipboardContent?
            if case let .complete(content) = result, content.digest != lastDigest {
                lastDigest = content.digest
                delivered = content
            }
            lock.unlock()
            switch result {
            case .complete, .duplicate:
                send(SPPWClipboardMessage.ack(transferID: transferID).encoded())
            case .pending, .invalid:
                break
            }
            return delivered.map { .content($0) } ?? .none
        }
    }

    /// Stops retransmitting (disconnect / sync turned off).
    public func cancel() {
        lock.lock()
        pending = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    private func transmit(_ chunks: [Data]) {
        let send = self.send
        queue.async {
            for (index, chunk) in chunks.enumerated() {
                send(chunk)
                // Large images: short pauses keep socket buffers and Wi-Fi from dropping bursts.
                if index % 32 == 31 { usleep(1_000) }
            }
        }
    }

    private func scheduleRetransmit() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(retransmitIntervalNanos))
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.retransmitTick() }
        timer = source
        source.resume()
    }

    private func retransmitTick() {
        lock.lock()
        guard var current = pending, current.attempts < maxAttempts else {
            pending = nil
            timer?.cancel()
            timer = nil
            lock.unlock()
            return
        }
        current.attempts += 1
        pending = current
        lock.unlock()
        transmit(current.chunks)
    }
}

#if os(macOS)
import AppKit

/// Watches and writes the macOS general pasteboard for clipboard sync (`changeCount` polling).
/// Items marked concealed or transient by password managers (`org.nspasteboard.*`) are skipped.
public final class SPPWMacPasteboardBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sppw.clipboard.pasteboard", qos: .utility)
    private let pollInterval: DispatchTimeInterval
    private let onChange: @Sendable (SPPWClipboardContent) -> Void
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private static let skippedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    public init(pollInterval: DispatchTimeInterval = .milliseconds(500), onChange: @escaping @Sendable (SPPWClipboardContent) -> Void) {
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
    }

    /// Starts polling; only changes made after this call are reported.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// Writes an item received from the peer; the resulting change is not reported back.
    public func write(_ content: SPPWClipboardContent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content.format {
        case .utf8Text:
            pasteboard.setString(content.text ?? "", forType: .string)
        case .png:
            pasteboard.setData(content.data, forType: .png)
        }
        lock.lock()
        lastChangeCount = pasteboard.changeCount
        lock.unlock()
    }

    /// Reads the current pasteboard item (text first, then an image converted to PNG).
    public static func readCurrent() -> SPPWClipboardContent? {
        let pasteboard = NSPasteboard.general
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: skippedTypes) else { return nil }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let content = SPPWClipboardContent(text: text)
            return content.data.count <= SPPWClipboardFormat.utf8Text.maximumByteCount ? content : nil
        }
        if let png = pasteboard.data(forType: .png) {
            return png.count <= SPPWClipboardFormat.png.maximumByteCount ? SPPWClipboardContent(format: .png, data: png) : nil
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           png.count <= SPPWClipboardFormat.png.maximumByteCount {
            return SPPWClipboardContent(format: .png, data: png)
        }
        return nil
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        lock.lock()
        guard count != lastChangeCount else {
            lock.unlock()
            return
        }
        lastChangeCount = count
        lock.unlock()
        if let content = Self.readCurrent() {
            onChange(content)
        }
    }
}
#endif
