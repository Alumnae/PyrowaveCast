import Foundation
import Network
import PyrowaveServerKit
import SPPWCommon

// MARK: - Main entry point

let defaultPort: UInt16 = 9888

var requestedPort = defaultPort
var testMode = false
var testImagePath: String?
var testVideoPath: String?
var fullChroma444 = false
var remoteControl = false
var encryption = true
var pairingMode: SPPWPairingMode = .pin
var passwordFile: String?
var setPassword = false
var listPaired = false
var forgetFingerprint: String?
let args = CommandLine.arguments.dropFirst()
var argIter = args.makeIterator()
while let arg = argIter.next() {
    if arg == "--port" || arg == "-p" {
        if let portStr = argIter.next(), let p = UInt16(portStr) {
            requestedPort = p
        }
    } else if arg == "--test" {
        testMode = true
    } else if arg == "--test-image" {
        if let path = argIter.next() {
            testImagePath = path
            testMode = true
        }
    } else if arg == "--test-video" {
        if let path = argIter.next() {
            testVideoPath = path
            testMode = true
        }
    } else if arg == "--chroma444" {
        fullChroma444 = true
    } else if arg == "--remote-control" {
        remoteControl = true
    } else if arg == "--no-encryption" {
        encryption = false
    } else if arg == "--pairing" {
        switch argIter.next() {
        case "pin": pairingMode = .pin
        case "password": pairingMode = .password
        case "open": pairingMode = .open
        default:
            fputs("--pairing expects pin, password or open\n", stderr)
            exit(2)
        }
    } else if arg == "--password-file" {
        passwordFile = argIter.next()
        pairingMode = .password
    } else if arg == "--set-password" {
        setPassword = true
    } else if arg == "--list-paired" {
        listPaired = true
    } else if arg == "--forget" {
        forgetFingerprint = argIter.next()
    } else if arg == "--help" || arg == "-h" {
        print("""
        PyrowaveKit SPPW/1 Server

        Usage: pyrowave-server [--port <PORT>] [--test] [--test-image <PATH>] [--test-video <PATH>] [--chroma444] [--remote-control]
                               [--no-encryption] [--pairing pin|password|open] [--password-file <PATH>]
               pyrowave-server --set-password | --list-paired | --forget <FINGERPRINT>

        Default port: \(defaultPort) (UDP)

        Protocol: SPPW/1 (ScreenSpan PyroWire)
        Transport: UDP
        Video: YCbCr 4:2:0 PyroWave v1 (4:4:4 with --chroma444)
        Codec: upstream PyroWave Metal implementation
               (https://github.com/Themaister/pyrowave)

        Without --test the server captures the screen via ScreenCaptureKit,
        which requires the macOS screen recording permission.

        With --test the server streams generated content instead and never
        touches ScreenCaptureKit, so no permission is required:
          --test              animated broadcast test card
          --test-image PATH   a still image (PNG, JPEG, ...)
          --test-video PATH   a video file, played back in a loop

        --chroma444 captures the screen with full resolution chroma
        (ScreenCaptureKit 10-bit 4:4:4) and encodes PyroWave 4:4:4: sharper
        coloured text and UI at a higher bitrate and GPU cost. Test content
        always stays 4:2:0.

        Security (on by default; receivers must have "Encryption" on too):
          --no-encryption     plain SPPW/1, no pairing (must match the receivers)
          --pairing pin       a new receiver pairs with a 5-digit PIN printed here
          --pairing password  a new receiver pairs with the server password
                              (headless servers; set it with --set-password)
          --pairing open      any receiver is accepted (still encrypted)
          --password-file P   read the password from file P (implies --pairing password)
          --set-password      read a new password from standard input and save it
          --list-paired       print the paired receivers
          --forget FP         remove the paired receiver whose fingerprint starts with FP
        Paired receivers and this server's identity are stored in
        ~/Library/Application Support/PyrowaveCast/Security.
        """)
        exit(0)
    }
}

let port = requestedPort
let securityStore = SPPWSecurityStore.shared

if setPassword {
    print("New pairing password (input is not echoed if read from a terminal): ", terminator: "")
    let password: String?
    if isatty(STDIN_FILENO) != 0, let raw = getpass("") {
        password = String(cString: raw)
    } else {
        password = readLine(strippingNewline: true)
    }
    guard let password, !password.isEmpty else {
        fputs("No password given.\n", stderr)
        exit(1)
    }
    securityStore.setServerPassword(password)
    print("Password saved. Start the server with --pairing password.")
    exit(0)
}
if listPaired {
    print("Server fingerprint: \(securityStore.identity.fingerprint.display)")
    let peers = securityStore.trustedPeers(.clients)
    if peers.isEmpty { print("No paired receivers.") }
    for peer in peers {
        print("\(peer.fingerprint.display)  \(peer.name)  paired \(peer.pairedAt.formatted())")
    }
    exit(0)
}
if let forgetFingerprint {
    let prefix = forgetFingerprint.filter(\.isHexDigit).uppercased()
    let matches = securityStore.trustedPeers(.clients).filter { $0.fingerprintHex.hasPrefix(prefix) }
    guard prefix.count >= 4, matches.count == 1, let match = matches.first else {
        fputs("Give at least 4 hex digits that match exactly one paired receiver (--list-paired).\n", stderr)
        exit(1)
    }
    securityStore.forget(.clients, fingerprintHex: match.fingerprintHex)
    print("Removed \(match.name) (\(match.fingerprint.short)).")
    exit(0)
}
if let passwordFile {
    guard let contents = try? String(contentsOfFile: passwordFile, encoding: .utf8) else {
        fputs("Cannot read \(passwordFile).\n", stderr)
        exit(1)
    }
    let password = contents.trimmingCharacters(in: .newlines)
    guard !password.isEmpty else {
        fputs("\(passwordFile) is empty.\n", stderr)
        exit(1)
    }
    securityStore.setServerPassword(password)
}
if encryption && pairingMode == .password && !securityStore.hasServerPassword {
    fputs("--pairing password needs a password: run with --set-password first, or pass --password-file.\n", stderr)
    exit(1)
}

let security = SPPWServerSecurity(
    store: securityStore,
    configuration: SPPWServerSecurityConfiguration(encryptionEnabled: encryption, pairingMode: pairingMode),
    serverName: ProcessInfo.processInfo.hostName
) { event in
    switch event {
    case let .pinRequested(prompt):
        print("""

        ┌──────────────────────────────────────────┐
          Pairing PIN for \(prompt.clientName): \(prompt.pin)
          Receiver fingerprint: \(prompt.clientFingerprint.short)
          Valid for \(Int(SPPWServerSecurity.pinLifetime)) s
        └──────────────────────────────────────────┘
        """)
    case .pinCleared:
        print("Pairing PIN cleared.")
    case let .paired(peer):
        print("Paired with \(peer.name) (\(peer.fingerprint.short)).")
    case let .clientAuthenticated(name, fingerprint, paired):
        print("Secure session with \(name) (\(fingerprint.short))\(paired ? ", paired" : "").")
    case let .log(text):
        print(text)
    }
}

// The test content mode decides what the server streams. It is deliberately
// separate from the screen capture path so that --test never triggers a
// Screen Recording permission prompt.
let testContentMode: TestContentMode?
if testVideoPath != nil {
    testContentMode = .video(URL(fileURLWithPath: testVideoPath!))
} else if testImagePath != nil {
    testContentMode = .image(URL(fileURLWithPath: testImagePath!))
} else if testMode {
    testContentMode = .card
} else {
    testContentMode = nil
}

if let testContentMode {
    print("Starting PyrowaveKit SPPW/1 server (TEST MODE) on UDP port \(port)...")
    switch testContentMode {
    case .card:
        print("Streaming an animated test card. No screen recording permission needed.")
    case .image(let url):
        print("Streaming the still image \(url.path). No screen recording permission needed.")
    case .video(let url):
        print("Streaming the video \(url.path). No screen recording permission needed.")
    }
} else {
    print("Starting PyrowaveKit SPPW/1 server on UDP port \(port)...")
    print("Note: Screen recording permission will be requested on first capture.")
}

let server = StreamServer(
    testContentMode: testContentMode,
    fullChroma444: fullChroma444,
    remoteInputEnabled: remoteControl,
    security: security
)

Task {
    do {
        try await server.start(port: port)
    } catch {
        fputs("Failed to start server: \(error)\n", stderr)
        exit(1)
    }
}

dispatchMain()
