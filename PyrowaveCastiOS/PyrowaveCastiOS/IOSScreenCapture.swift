import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ReplayKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

@MainActor
final class IOSScreenCaptureCoordinator: NSObject {
    private let recorder = RPScreenRecorder.shared()
    private let converter = IOSNV12Converter()
    private var continuation: AsyncStream<IOSSendablePixelBuffer>.Continuation?
    private var isCapturing = false
    private var scPickerCoordinator: AnyObject?
    /// Called on the main actor when the system capture stops on its own (ScreenCaptureKit
    /// `didStopWithError`, e.g. while the app was in the background), not after `stop()`.
    var onCaptureStopped: (@MainActor (String) -> Void)?

    /// `audioHandler` receives the captured app/system audio (ScreenCaptureKit `.audio` on
    /// iOS 27, ReplayKit `.audioApp` otherwise) on a capture queue.
    func start(
        width: Int,
        height: Int,
        audioHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil
    ) async throws -> AsyncStream<IOSSendablePixelBuffer> {
        let targetWidth = max(width, 2) & ~1
        let targetHeight = max(height, 2) & ~1

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            let pickerCoordinator = IOSScreenCaptureKitCoordinator(converter: converter, audioHandler: audioHandler)
            pickerCoordinator.onStopped = { [weak self] reason in
                self?.onCaptureStopped?(reason)
            }
            self.scPickerCoordinator = pickerCoordinator
            do {
                let stream = try await pickerCoordinator.start(width: targetWidth, height: targetHeight)
                isCapturing = true
                return stream
            } catch {
                self.scPickerCoordinator = nil
                if error is CancellationError {
                    throw error
                }
                // Fall back to ReplayKit in-app screen capture if SCContentSharingPicker is unavailable.
            }
        }
        #endif

        guard recorder.isAvailable else {
            throw NSError(
                domain: "PyroWaveServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ReplayKit screen capture is not available on this device"]
            )
        }
        if recorder.isRecording {
            try? await stopCaptureInternal()
        }

        let (stream, continuation) = AsyncStream<IOSSendablePixelBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        self.recorder.isMicrophoneEnabled = false

        let converter = self.converter
        try await withCheckedThrowingContinuation { (startCont: CheckedContinuation<Void, Error>) in
            recorder.startCapture(
                handler: { sampleBuffer, sampleType, error in
                    guard error == nil else { return }
                    if sampleType == .audioApp {
                        audioHandler?(sampleBuffer)
                        return
                    }
                    guard sampleType == .video,
                          let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                          let normalized = converter.normalizeToNV12(
                              sourceBuffer,
                              targetWidth: targetWidth,
                              targetHeight: targetHeight
                          ) else {
                        return
                    }
                    continuation.yield(IOSSendablePixelBuffer(
                        buffer: normalized,
                        captureTimestampNanoseconds: SPPWCaptureClock.captureNanoseconds(of: sampleBuffer)
                    ))
                },
                completionHandler: { error in
                    if let error {
                        startCont.resume(throwing: error)
                    } else {
                        startCont.resume(returning: ())
                    }
                }
            )
        }

        isCapturing = true
        return stream
    }

    func stop() async {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *), let pickerCoordinator = scPickerCoordinator as? IOSScreenCaptureKitCoordinator {
            scPickerCoordinator = nil
            await pickerCoordinator.stop()
        }
        #endif
        if isCapturing || recorder.isRecording {
            try? await stopCaptureInternal()
        }
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }

    private func stopCaptureInternal() async throws {
        guard recorder.isRecording else { return }
        try await withCheckedThrowingContinuation { (stopCont: CheckedContinuation<Void, Error>) in
            recorder.stopCapture { error in
                if let error {
                    stopCont.resume(throwing: error)
                } else {
                    stopCont.resume(returning: ())
                }
            }
        }
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
@MainActor
private final class IOSScreenCaptureKitCoordinator: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    private let picker = SCContentSharingPicker.shared
    private let outputQueue = DispatchQueue(label: "com.pyrowavecast.ios.capture-output", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.pyrowavecast.ios.capture-audio", qos: .userInteractive)
    private let converter: IOSNV12Converter
    private let audioHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var captureStream: SCStream?
    private var output: IOSScreenOutput?
    private var continuation: AsyncStream<IOSSendablePixelBuffer>.Continuation?
    private var outputStream: AsyncStream<IOSSendablePixelBuffer>?
    private var startContinuation: CheckedContinuation<AsyncStream<IOSSendablePixelBuffer>, Error>?
    private var requestedWidth = 1920
    private var requestedHeight = 1080
    var onStopped: (@MainActor (String) -> Void)?

    init(converter: IOSNV12Converter, audioHandler: (@Sendable (CMSampleBuffer) -> Void)?) {
        self.converter = converter
        self.audioHandler = audioHandler
        super.init()
    }

    func start(width: Int, height: Int) async throws -> AsyncStream<IOSSendablePixelBuffer> {
        requestedWidth = max(width, 2) & ~1
        requestedHeight = max(height, 2) & ~1
        let (stream, continuation) = AsyncStream<IOSSendablePixelBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        outputStream = stream
        self.continuation = continuation

        picker.isActive = true
        var pickerConfiguration = picker.defaultConfiguration
        pickerConfiguration.showsMicrophoneControl = false
        picker.defaultConfiguration = pickerConfiguration
        picker.add(self)

        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            picker.present()
        }
    }

    func stop() async {
        picker.remove(self)
        picker.isActive = false
        if let captureStream, captureStream.isCapturing {
            try? await captureStream.stopCapture()
        }
        captureStream = nil
        output = nil
        continuation?.finish()
        continuation = nil
        outputStream = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let selection = IOSPickerSelection(filter: filter, stream: stream)
        Task { @MainActor [weak self] in
            await self?.startSelectedCapture(selection)
        }
    }

    private func startSelectedCapture(_ selection: IOSPickerSelection) async {
        do {
            let configuration = SCStreamConfiguration()
            configuration.width = requestedWidth
            configuration.height = requestedHeight
            if audioHandler != nil {
                // 48 kHz stereo matches SPPW/1 audio, so the packetizer needs no resampling.
                configuration.capturesAudio = true
                configuration.sampleRate = SPPWAudioPacketHeader.sampleRate
                configuration.channelCount = SPPWAudioPacketHeader.channelCount
                configuration.excludesCurrentProcessAudio = true
            }
            // Note: SCStream.updateConfiguration(_:) is unavailable on iOS, so size/audio
            // settings are applied when constructing the SCStream for the picker selection.
            let selectedStream = selection.stream ?? SCStream(
                filter: selection.filter,
                configuration: configuration,
                delegate: self
            )
            let converter = self.converter
            let frameContinuation = self.continuation
            let targetWidth = self.requestedWidth
            let targetHeight = self.requestedHeight
            let audioCallback = audioHandler
            let frameOutput = IOSScreenOutput { type, sampleBuffer in
                if type == .audio {
                    audioCallback?(sampleBuffer)
                    return
                }
                guard type == .screen,
                      let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      let normalized = converter.normalizeToNV12(
                          sourceBuffer,
                          targetWidth: targetWidth,
                          targetHeight: targetHeight
                      ) else { return }
                frameContinuation?.yield(IOSSendablePixelBuffer(
                    buffer: normalized,
                    captureTimestampNanoseconds: SPPWCaptureClock.captureNanoseconds(of: sampleBuffer)
                ))
            }
            try selectedStream.addStreamOutput(
                frameOutput,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
            if audioCallback != nil {
                try selectedStream.addStreamOutput(
                    frameOutput,
                    type: .audio,
                    sampleHandlerQueue: audioQueue
                )
            }
            if !selectedStream.isCapturing {
                try await selectedStream.startCapture()
            }
            captureStream = selectedStream
            output = frameOutput
            if let result = startContinuation {
                startContinuation = nil
                result.resume(returning: outputStream!)
            }
        } catch {
            startContinuation?.resume(throwing: error)
            startContinuation = nil
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.startContinuation?.resume(throwing: CancellationError())
            self?.startContinuation = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.startContinuation?.resume(throwing: error)
            self?.startContinuation = nil
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let reason = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasCapturing = self.captureStream != nil
            self.continuation?.finish()
            self.continuation = nil
            self.captureStream = nil
            if wasCapturing {
                self.onStopped?(reason)
            }
        }
    }
}

@available(iOS 27.0, *)
private struct IOSPickerSelection: @unchecked Sendable {
    let filter: SCContentFilter
    let stream: SCStream?
}

@available(iOS 27.0, *)
private final class IOSScreenOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: @Sendable (SCStreamOutputType, CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (SCStreamOutputType, CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        handler(type, sampleBuffer)
    }
}
#endif
