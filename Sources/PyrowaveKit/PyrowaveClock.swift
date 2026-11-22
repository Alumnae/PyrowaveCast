import Foundation

/// Monotonic timing that compiles on iOS 15.
///
/// Swift's `ContinuousClock`, `Duration`, and `Task.sleep(for:)` are annotated
/// `iOS 16.0+`. The shared codec and streaming sources are compiled both by
/// SwiftPM for macOS and directly into the iOS app target, so they use this
/// `DispatchTime`-based shim instead. It mirrors the small subset of the
/// standard API those sources rely on:
///
///   - `PyrowaveClock.now` / `PyrowaveClock.Instant`
///   - `instant.duration(to:)` returning a `PyrowaveDuration`
///   - `duration.components` (`seconds` / `attoseconds`)
///   - `PyrowaveDuration.seconds/milliseconds/nanoseconds` factories
///   - `Comparable` duration comparisons (`> .seconds(2)`)
///
/// For sleeping, use `Task.sleep(nanoseconds:)` directly — it is available on
/// every supported OS and avoids the `Duration` overload entirely.
enum PyrowaveClock {
    struct Instant: Equatable, Comparable, Sendable {
        /// Monotonic uptime in nanoseconds.
        let uptimeNanoseconds: UInt64

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
        }

        func duration(to end: Instant) -> PyrowaveDuration {
            PyrowaveDuration(nanoseconds: end.uptimeNanoseconds &- uptimeNanoseconds)
        }

        func milliseconds(to end: Instant) -> Double {
            Double(end.uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000
        }
    }

    static var now: Instant {
        Instant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

struct PyrowaveDuration: Equatable, Comparable, Sendable {
    let nanosecondCount: UInt64

    init(nanoseconds: UInt64) { nanosecondCount = nanoseconds }

    static func seconds(_ value: Double) -> PyrowaveDuration {
        PyrowaveDuration(nanoseconds: UInt64(max(0, value * 1_000_000_000)))
    }

    static func milliseconds(_ value: Double) -> PyrowaveDuration {
        PyrowaveDuration(nanoseconds: UInt64(max(0, value * 1_000_000)))
    }

    static func nanoseconds(_ value: Int64) -> PyrowaveDuration {
        PyrowaveDuration(nanoseconds: UInt64(max(0, value)))
    }

    static func < (lhs: PyrowaveDuration, rhs: PyrowaveDuration) -> Bool {
        lhs.nanosecondCount < rhs.nanosecondCount
    }

    /// Mirrors `Duration.components` so existing metrics code keeps working.
    var components: (seconds: Int64, attoseconds: Int64) {
        (
            Int64(nanosecondCount / 1_000_000_000),
            Int64((nanosecondCount % 1_000_000_000) * 1_000_000_000)
        )
    }

    var inSeconds: Double { Double(nanosecondCount) / 1_000_000_000 }
}
