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

/// Requests extra execution time when the app moves to the background while streaming, so a
/// short trip to another app (or a notification) does not cut the stream immediately, and
/// logs what iOS allows: in-app ReplayKit capture pauses in the background, and the app is
/// suspended once the extra time runs out unless an audio session keeps it running.
@MainActor
final class IOSBackgroundStreamingGuard {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private let onEvent: @MainActor (String, Bool) -> Void

    init(onEvent: @escaping @MainActor (String, Bool) -> Void) {
        self.onEvent = onEvent
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
    }

    func invalidate() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        endTask()
    }

    private func enteredBackground() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "PyrowaveCast streaming") { [weak self] in
            MainActor.assumeIsolated {
                self?.onEvent("Background time expired: iOS may suspend streaming until the app returns to the foreground.", true)
                self?.endTask()
            }
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let seconds = remaining.isFinite ? "\(Int(remaining)) s" : "unlimited"
        onEvent("App in background (time available: \(seconds)). Keep PyrowaveCast in the foreground for uninterrupted streaming.", false)
    }

    private func enteringForeground() {
        if taskID != .invalid {
            onEvent("App back in the foreground.", false)
        }
        endTask()
    }

    private func endTask() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
