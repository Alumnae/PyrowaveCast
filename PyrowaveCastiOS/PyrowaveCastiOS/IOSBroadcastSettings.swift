import Foundation

/// Settings shared by the app and its Broadcast Upload Extension.
///
/// They meet in the `group.com.pyrowavecast.ios` App Group when the signing profile grants
/// it; without the App Group each side reads its own defaults and the extension uses the
/// default port, so broadcasting still works.
enum IOSBroadcastSettings {
    static let appGroup = "group.com.pyrowavecast.ios"
    static let defaultPort: UInt16 = 9888
    /// Bundle identifier of the extension, for `RPSystemBroadcastPickerView.preferredExtension`.
    static var extensionBundleIdentifier: String {
        appBundleIdentifier + ".broadcast"
    }

    private static var appBundleIdentifier: String {
        let identifier = Bundle.main.bundleIdentifier ?? "com.pyrowavecast.ios"
        // Inside the extension the bundle identifier is "<app>.broadcast".
        return identifier.hasSuffix(".broadcast") ? String(identifier.dropLast(".broadcast".count)) : identifier
    }

    /// True when the signing profile grants the App Group, so the extension sees the app's port.
    static var isShared: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    private static var shared: UserDefaults? {
        isShared ? UserDefaults(suiteName: appGroup) : nil
    }

    /// The port the broadcast server listens on: the app's port when shared, else the default.
    static var port: UInt16 {
        get {
            let stored = shared?.integer(forKey: "broadcastPort") ?? 0
            return (1...65_534).contains(stored) ? UInt16(stored) : defaultPort
        }
        set {
            shared?.set(Int(newValue), forKey: "broadcastPort")
        }
    }
}
