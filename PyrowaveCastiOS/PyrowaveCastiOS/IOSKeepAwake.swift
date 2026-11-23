import BackgroundTasks
import UIKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif

/// Keeps the device awake while the server streams or the receiver is connected.
///
/// iOS auto-lock (the idle timer) locks the screen after the configured delay; a locked
/// device backgrounds the app and iOS suspends it shortly after, which stopped the stream
/// "after some time". Server and receiver can run at the same time in the unified app, so
/// each acquires its own token and the idle timer stays disabled while any token is held.
@MainActor
final class IOSKeepAwake {
    static let shared = IOSKeepAwake()

    enum Holder: String {
        case server
        case receiver
    }

    private var holders = Set<Holder>()
    private let activity = SPPWStreamingActivity(reason: "PyrowaveCast streaming")

    private init() {}

    func acquire(_ holder: Holder) {
        holders.insert(holder)
        apply()
    }

    func release(_ holder: Holder) {
        holders.remove(holder)
        apply()
    }

    private func apply() {
        let keepAwake = !holders.isEmpty
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        if keepAwake {
            if !activity.isActive {
                activity.begin(keepDisplayAwake: true)
            }
        } else {
            activity.end()
        }
    }
}

/// Keeps the iOS server streaming while the app is in the background.
///
/// iOS refuses Metal command buffers from background apps and suspends the app about 30 s
/// after it leaves the screen, so the PyroWave encoder stopped as soon as the user switched
/// app. While the server runs, the guard keeps a continued-processing background task
/// (`BGContinuedProcessingTask`, iOS 26+) with background GPU access where the device and the
/// `com.apple.developer.background-tasks.continued-processing.gpu` entitlement allow it: the
/// encoder keeps running and iOS shows the task's progress (frames sent) in a Live Activity.
///
/// Without background GPU (older iOS, unsupported device, missing entitlement, or the task
/// expired) the guard tells the server to pause video in the background instead of failing
/// every frame on the GPU, keeps the session alive as long as iOS allows, and resumes video
/// (and lets the model restart a stopped capture) when the app returns to the foreground.
@MainActor
final class IOSBackgroundStreamingGuard {
    struct Snapshot {
        var framesSent: Int
        var connectedClients: Int
        var megabitsPerSecond: Double
    }

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private let onEvent: @MainActor (String, Bool) -> Void
    private let onVideoAllowedChanged: @MainActor (Bool) -> Void
    private let onForegroundChanged: @MainActor (Bool) -> Void
    private let snapshot: @MainActor () -> Snapshot
    /// `IOSContinuedStreamingTask` on iOS 26+ (stored untyped for the iOS 17 deployment target).
    private var continuedTask: AnyObject?
    private var isInBackground = false
    private var videoAllowed = true

    /// - Parameters:
    ///   - onVideoAllowedChanged: false while video must pause (background without GPU access).
    ///   - onForegroundChanged: true when the app returns to the foreground, false when it leaves.
    ///   - snapshot: server counters shown as the background task's progress.
    init(
        onEvent: @escaping @MainActor (String, Bool) -> Void,
        onVideoAllowedChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onForegroundChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        snapshot: @escaping @MainActor () -> Snapshot = { Snapshot(framesSent: 0, connectedClients: 0, megabitsPerSecond: 0) }
    ) {
        self.onEvent = onEvent
        self.onVideoAllowedChanged = onVideoAllowedChanged
        self.onForegroundChanged = onForegroundChanged
        self.snapshot = snapshot
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringForeground() }
        })
        // Continued-processing tasks can only be submitted while the app is in the
        // foreground, so the server asks for one as soon as it starts.
        startContinuedTask()
    }

    func invalidate() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        endTask()
        if #available(iOS 26.0, *), let task = continuedTask as? IOSContinuedStreamingTask {
            task.finish()
        }
        continuedTask = nil
    }

    /// True while a continued-processing task with background GPU access is running.
    private var hasBackgroundGPU: Bool {
        if #available(iOS 26.0, *), let task = continuedTask as? IOSContinuedStreamingTask {
            return task.isRunningWithGPU
        }
        return false
    }

    private var hasContinuedTask: Bool {
        if #available(iOS 26.0, *), let task = continuedTask as? IOSContinuedStreamingTask {
            return task.isRunning
        }
        return false
    }

    private func startContinuedTask() {
        guard #available(iOS 26.0, *) else {
            onEvent("Background streaming needs iOS 26 or later: video pauses while PyrowaveCast is not on screen.", false)
            return
        }
        guard UIApplication.shared.applicationState != .background else { return }
        if let task = continuedTask as? IOSContinuedStreamingTask, task.isRunning || task.isSubmitting { return }
        let task = IOSContinuedStreamingTask(
            snapshot: snapshot,
            onEvent: onEvent,
            onStateChange: { [weak self] in self?.updateVideoAllowed() }
        )
        continuedTask = task
        task.submit()
    }

    private func updateVideoAllowed() {
        let allowed = !isInBackground || hasBackgroundGPU
        if isInBackground && !hasContinuedTask {
            beginShortBackgroundTask()
        }
        guard allowed != videoAllowed else { return }
        videoAllowed = allowed
        onVideoAllowedChanged(allowed)
    }

    private func enteredBackground() {
        isInBackground = true
        onForegroundChanged(false)
        if hasBackgroundGPU {
            onEvent("App in background: streaming continues with background GPU access.", false)
        } else {
            onEvent(hasContinuedTask
                ? "App in background without background GPU access: video paused, the session stays connected and resumes when PyrowaveCast returns to the foreground."
                : "App in background: video paused until PyrowaveCast returns to the foreground.", false)
        }
        updateVideoAllowed()
    }

    private func enteringForeground() {
        isInBackground = false
        endTask()
        updateVideoAllowed()
        onForegroundChanged(true)
        // An expired or refused task can only be requested again from the foreground.
        startContinuedTask()
    }

    /// Without a continued-processing task: the classic ~30 s of extra time, so a quick
    /// trip to another app does not drop the session.
    private func beginShortBackgroundTask() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "PyrowaveCast streaming") { [weak self] in
            MainActor.assumeIsolated {
                self?.onEvent("Background time expired: iOS may suspend streaming until the app returns to the foreground.", true)
                self?.endTask()
            }
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let seconds = remaining.isFinite ? "\(Int(remaining)) s" : "unlimited"
        onEvent("Extra background time available: \(seconds).", false)
    }

    private func endTask() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}

/// One `BGContinuedProcessingTask` for a running server. It asks for background GPU access
/// when the device supports it (falling back to a CPU-only task when the GPU request is
/// refused, e.g. without the entitlement) and reports frames sent as progress, which iOS
/// requires: a task whose progress stalls may be expired.
@available(iOS 26.0, *)
@MainActor
final class IOSContinuedStreamingTask {
    private let snapshot: @MainActor () -> IOSBackgroundStreamingGuard.Snapshot
    private let onEvent: @MainActor (String, Bool) -> Void
    private let onStateChange: @MainActor () -> Void
    private var task: BGContinuedProcessingTask?
    private var progressTimer: Timer?
    private var finished = false
    private var hasGPU = false
    private(set) var isSubmitting = false

    var isRunning: Bool { task != nil }
    var isRunningWithGPU: Bool { task != nil && hasGPU }

    /// Permitted in Info.plist as `$(PRODUCT_BUNDLE_IDENTIFIER).streaming.*`; each request
    /// gets a unique suffix because an identifier may be registered only once per launch.
    private static var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "com.pyrowavecast.ios") + ".streaming."
    }

    init(
        snapshot: @escaping @MainActor () -> IOSBackgroundStreamingGuard.Snapshot,
        onEvent: @escaping @MainActor (String, Bool) -> Void,
        onStateChange: @escaping @MainActor () -> Void
    ) {
        self.snapshot = snapshot
        self.onEvent = onEvent
        self.onStateChange = onStateChange
    }

    func submit() {
        let wantsGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        if !wantsGPU {
            onEvent("This device has no background GPU access: video pauses in the background, the session stays connected.", false)
        }
        submit(withGPU: wantsGPU)
    }

    private func submit(withGPU: Bool) {
        let identifier = Self.identifierPrefix + UUID().uuidString.prefix(8)
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: DispatchQueue.main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let self, !self.finished else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.started(task, withGPU: withGPU)
            }
        }
        guard registered else {
            onEvent("Background task identifier not permitted (BGTaskSchedulerPermittedIdentifiers): video pauses in the background.", true)
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: SPPWLocalization.tr("server.background.title"),
            subtitle: SPPWLocalization.tr("server.background.subtitle_waiting")
        )
        // Run now or not at all: a queued task would start long after the user left.
        request.strategy = .fail
        if withGPU {
            request.requiredResources = .gpu
        }
        isSubmitting = true
        Self.submit(request) { [weak self] error in
            guard let self else { return }
            self.isSubmitting = false
            guard let error else { return }
            if withGPU && !self.finished {
                self.onEvent("Background GPU access refused (\(error.localizedDescription)); check the continued-processing GPU entitlement. Retrying without GPU: video will pause in the background.", true)
                self.submit(withGPU: false)
            } else {
                self.onEvent("Background task refused: \(error.localizedDescription). Video pauses in the background.", true)
                self.onStateChange()
            }
        }
    }

    private static func submit(
        _ request: BGContinuedProcessingTaskRequest,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        if #available(iOS 27.0, *) {
            BGTaskScheduler.shared.submitTaskRequest(request) { error in
                let message = error.map { $0 as NSError }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(message) }
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(request)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private func started(_ task: BGContinuedProcessingTask, withGPU: Bool) {
        self.task = task
        hasGPU = withGPU
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.expired() }
            }
        }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
        reportProgress()
        onEvent(withGPU
            ? "Background streaming active (background GPU access granted)."
            : "Background task active without GPU: the session stays connected in the background, video pauses.", false)
        onStateChange()
    }

    /// Frames sent as monotonically increasing progress; the total stays ahead so the
    /// task never looks finished, and keeps moving so it never looks stalled.
    private func reportProgress() {
        guard let task else { return }
        let now = snapshot()
        let completed = Int64(max(now.framesSent, 0))
        task.progress.totalUnitCount = completed * 2 + 100
        task.progress.completedUnitCount = completed
        let subtitle = SPPWLocalization.tr(
            "server.background.subtitle_fmt",
            now.connectedClients,
            String(format: "%.1f", now.megabitsPerSecond)
        )
        task.updateTitle(SPPWLocalization.tr("server.background.title"), subtitle: subtitle)
    }

    private func expired() {
        guard let task else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        self.task = nil
        hasGPU = false
        task.setTaskCompleted(success: false)
        onEvent("iOS ended background streaming (system conditions or the user stopped it): video pauses in the background until PyrowaveCast returns to the foreground.", true)
        onStateChange()
    }

    /// The server stopped: completes the task and removes its Live Activity.
    func finish() {
        finished = true
        progressTimer?.invalidate()
        progressTimer = nil
        task?.setTaskCompleted(success: true)
        task = nil
        hasGPU = false
    }
}
