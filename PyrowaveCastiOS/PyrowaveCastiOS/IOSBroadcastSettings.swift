import Foundation
#if canImport(SPPWCommon)
import SPPWCommon
#endif

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

    // MARK: Security (shared with the extension through the App Group when available)

    /// Identity, paired devices and the headless password. In the App Group container when it
    /// exists, so the broadcast server uses the same identity and pairings as the app.
    static let securityStore: SPPWSecurityStore = {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return SPPWSecurityStore(directory: container
                .appendingPathComponent("Library/Application Support/PyrowaveCast/Security", isDirectory: true))
        }
        return SPPWSecurityStore.shared
    }()

    private static var settingsDefaults: UserDefaults { shared ?? .standard }

    static var encryptionEnabled: Bool {
        get { settingsDefaults.object(forKey: "serverEncryptionEnabled") as? Bool ?? true }
        set { settingsDefaults.set(newValue, forKey: "serverEncryptionEnabled") }
    }

    static var pairingMode: SPPWPairingMode {
        get { SPPWPairingMode(rawValue: UInt8(settingsDefaults.integer(forKey: "serverPairingMode"))) ?? .pin }
        set { settingsDefaults.set(Int(newValue.rawValue), forKey: "serverPairingMode") }
    }

    /// Settings for the broadcast server. Without the App Group the extension cannot show a PIN
    /// anywhere (it has no screen and the app cannot read it), so it stays encrypted but open.
    static var broadcastSecurityConfiguration: SPPWServerSecurityConfiguration {
        let mode = pairingMode
        return SPPWServerSecurityConfiguration(
            encryptionEnabled: encryptionEnabled,
            pairingMode: isShared || mode == .password ? mode : .open
        )
    }

    /// The PIN the broadcast server is showing, for the app to display (App Group only).
    static var broadcastPIN: SPPWPairingPINPrompt? {
        get {
            guard let shared, let pin = shared.string(forKey: "broadcastPIN"),
                  let name = shared.string(forKey: "broadcastPINClient"),
                  let hex = shared.string(forKey: "broadcastPINFingerprint"),
                  let fingerprint = SPPWFingerprint(hex: hex) else { return nil }
            let expires = Date(timeIntervalSince1970: shared.double(forKey: "broadcastPINExpires"))
            guard expires > Date() else { return nil }
            return SPPWPairingPINPrompt(pin: pin, clientName: name, clientFingerprint: fingerprint, expiresAt: expires)
        }
        set {
            guard let shared else { return }
            if let newValue {
                shared.set(newValue.pin, forKey: "broadcastPIN")
                shared.set(newValue.clientName, forKey: "broadcastPINClient")
                shared.set(newValue.clientFingerprint.hex, forKey: "broadcastPINFingerprint")
                shared.set(newValue.expiresAt.timeIntervalSince1970, forKey: "broadcastPINExpires")
            } else {
                shared.removeObject(forKey: "broadcastPIN")
            }
        }
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
