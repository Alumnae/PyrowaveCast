import CryptoKit
import Foundation
import Security
import CommonCrypto

// MARK: - SPPW/1 secure transport (PROTOCOL.md §7)
//
// Optional, switchable on both ends ("Encryption"). When on:
// 1. `secureHello` / `secureReply` (plaintext, kinds 11/12): X25519 ephemeral keys, Ed25519
//    device identities, nonces; the server signs the transcript.
// 2. Every later datagram travels in the AES-256-GCM envelope (header flag 0x8000): the 40-byte
//    header stays readable and is authenticated, a 64-bit counter prevents replays.
// 3. `secureAuth` (kind 13): the client signs the transcript; the server decides whether it
//    is trusted (paired), needs pairing, or is accepted without pairing ("open").
// 4. `pairing` (kind 14): CPace with the 5-digit PIN shown on the server, or the password of a
//    headless server. Success stores both device fingerprints, so later sessions need no PIN.
// 5. `secureNotice` (kind 15, plaintext): "unknown session, start again" or a mismatch of the
//    two toggles, which is reported to the user instead of silently falling back.
//
// Both engines sit between a UDP socket and the app: the app keeps sending and receiving the
// same plaintext `SPPW/1` datagrams as without encryption.

// MARK: Constants and envelope

public enum SPPWSecureKind {
    public static let secureHello: UInt8 = 11
    public static let secureReply: UInt8 = 12
    public static let secureAuth: UInt8 = 13
    public static let pairing: UInt8 = 14
    public static let secureNotice: UInt8 = 15
}

/// Reasons carried by `secureNotice`.
public enum SPPWSecureNoticeCode: UInt8, Sendable {
    /// The server has no session for this sender (it restarted): run the handshake again.
    case unknownSession = 0
    /// A plaintext client reached a server with encryption on.
    case encryptionRequired = 1
    /// A secure client reached a server with encryption off.
    case encryptionDisabled = 2
}

public enum SPPWSecureEnvelope {
    public static let headerByteCount = 40
    public static let sealedFlag: UInt16 = 0x8000
    /// Counter (8) + GCM tag (16) added to every sealed datagram.
    public static let overheadBytes = 24
    static let magic: UInt32 = 0x5350_5057
    static let protocolVersion: UInt8 = 1

    public static func kind(of datagram: Data) -> UInt8? {
        guard datagram.count >= headerByteCount else { return nil }
        let base = datagram.startIndex
        let magicValue = UInt32(datagram[base]) << 24 | UInt32(datagram[base + 1]) << 16
            | UInt32(datagram[base + 2]) << 8 | UInt32(datagram[base + 3])
        guard magicValue == magic else { return nil }
        return datagram[base + 5]
    }

    public static func isSealed(_ datagram: Data) -> Bool {
        guard datagram.count >= headerByteCount else { return false }
        let base = datagram.startIndex
        return datagram[base + 6] & UInt8(sealedFlag >> 8) != 0
    }

    /// A bare `SPPW/1` datagram (header with zero fields) for the security messages.
    public static func makeDatagram(kind: UInt8, payload: Data = Data()) -> Data {
        var data = Data(capacity: headerByteCount + payload.count)
        SPPWSecureEncoding.appendU32(magic, to: &data)
        data.append(protocolVersion)
        data.append(kind)
        data.append(Data(count: headerByteCount - 6))
        data.append(payload)
        return data
    }

    static func payload(of datagram: Data) -> Data {
        datagram.count > headerByteCount ? Data(datagram.dropFirst(headerByteCount)) : Data()
    }
}

/// One direction's AEAD state: key, 4-byte nonce salt, and either the send counter or the
/// receive replay window.
final class SPPWSecureDirection: @unchecked Sendable {
    private let key: SymmetricKey
    private let salt: Data
    private let lock = NSLock()
    private var nextCounter: UInt64 = 1
    private var window = SPPWReplayWindow()

    init(key: SymmetricKey, salt: Data) {
        self.key = key
        self.salt = salt
    }

    private func nonce(_ counter: UInt64) -> AES.GCM.Nonce? {
        var bytes = salt
        SPPWSecureEncoding.appendU64(counter, to: &bytes)
        return try? AES.GCM.Nonce(data: bytes)
    }

    /// Seals a plaintext datagram: header (flag set) ‖ counter ‖ ciphertext ‖ tag.
    func seal(_ datagram: Data) -> Data? {
        guard SPPWSecureEnvelope.kind(of: datagram) != nil else { return nil }
        lock.lock()
        let counter = nextCounter
        nextCounter &+= 1
        lock.unlock()
        var header = Data(datagram.prefix(SPPWSecureEnvelope.headerByteCount))
        header[header.startIndex + 6] |= UInt8(SPPWSecureEnvelope.sealedFlag >> 8)
        var aad = header
        SPPWSecureEncoding.appendU64(counter, to: &aad)
        guard let nonce = nonce(counter),
              let box = try? AES.GCM.seal(SPPWSecureEnvelope.payload(of: datagram), using: key, nonce: nonce, authenticating: aad)
        else { return nil }
        var out = aad
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// Opens a sealed datagram back into the plaintext one (flag cleared); `nil` when it is
    /// forged, damaged, or a replay.
    func open(_ datagram: Data) -> Data? {
        let headerCount = SPPWSecureEnvelope.headerByteCount
        guard datagram.count >= headerCount + SPPWSecureEnvelope.overheadBytes,
              SPPWSecureEnvelope.isSealed(datagram) else { return nil }
        let bytes = [UInt8](datagram)
        let counter = SPPWSecureEncoding.u64(bytes, at: headerCount)
        lock.lock()
        let fresh = window.wouldAccept(counter)
        lock.unlock()
        guard fresh, let nonce = nonce(counter) else { return nil }
        let aad = Data(bytes[0..<(headerCount + 8)])
        let ciphertext = Data(bytes[(headerCount + 8)..<(bytes.count - 16)])
        let tag = Data(bytes[(bytes.count - 16)...])
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? AES.GCM.open(box, using: key, authenticating: aad) else { return nil }
        lock.lock()
        let accepted = window.accept(counter)
        lock.unlock()
        guard accepted else { return nil }
        var header = Data(bytes[0..<headerCount])
        header[6] &= ~UInt8(SPPWSecureEnvelope.sealedFlag >> 8)
        header.append(plaintext)
        return header
    }
}

/// Keys for both directions, derived from the X25519 secret and the transcript hash.
struct SPPWSessionKeys {
    let clientToServer: SPPWSecureDirection
    let serverToClient: SPPWSecureDirection

    init(sharedSecret: SharedSecret, transcript: Data) {
        let material = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("SPPW/1 session keys".utf8),
            outputByteCount: 72
        ).withUnsafeBytes { Data($0) }
        clientToServer = SPPWSecureDirection(key: SymmetricKey(data: material[0..<32]), salt: material[64..<68])
        serverToClient = SPPWSecureDirection(key: SymmetricKey(data: material[32..<64]), salt: material[68..<72])
    }
}

// MARK: Identity, fingerprints, trust store

/// SHA-256 of a device's Ed25519 public key.
public struct SPPWFingerprint: Hashable, Sendable, Codable {
    public let bytes: Data

    public init(publicKey: Data) {
        bytes = Data(SHA256.hash(data: publicKey))
    }

    public init?(hex: String) {
        let clean = hex.filter(\.isHexDigit)
        guard clean.count == 64 else { return nil }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        bytes = data
    }

    public var hex: String { bytes.map { String(format: "%02X", $0) }.joined() }

    /// The first 16 bytes in eight groups of four hex digits, for comparing by eye.
    public var display: String {
        let digits = Array(hex.prefix(32))
        return stride(from: 0, to: digits.count, by: 4).map { String(digits[$0..<($0 + 4)]) }.joined(separator: " ")
    }

    /// The first two groups, for compact labels.
    public var short: String { String(display.prefix(9)) }
}

/// This device's long-term signing key.
public struct SPPWDeviceIdentity: @unchecked Sendable {
    let signingKey: Curve25519.Signing.PrivateKey
    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
    public var fingerprint: SPPWFingerprint { SPPWFingerprint(publicKey: publicKey) }

    public init() {
        signingKey = Curve25519.Signing.PrivateKey()
    }

    init(signingKey: Curve25519.Signing.PrivateKey) {
        self.signingKey = signingKey
    }

    func sign(_ data: Data) -> Data? {
        try? signingKey.signature(for: data)
    }
}

/// A device paired with this one.
public struct SPPWTrustedPeer: Codable, Sendable, Equatable, Identifiable {
    public let fingerprintHex: String
    public let publicKey: Data
    public var name: String
    public let pairedAt: Date
    public var lastSeen: Date

    public var id: String { fingerprintHex }
    public var fingerprint: SPPWFingerprint { SPPWFingerprint(publicKey: publicKey) }

    public init(publicKey: Data, name: String, pairedAt: Date = Date()) {
        self.fingerprintHex = SPPWFingerprint(publicKey: publicKey).hex
        self.publicKey = publicKey
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = pairedAt
    }
}

/// What a server keeps of its headless password: PBKDF2-HMAC-SHA256 with a random salt. The
/// password itself is never stored; the receiver derives the same value from what the user types
/// (the server sends salt and iterations in the pairing challenge) and both use it in CPace.
public struct SPPWPasswordVerifier: Codable, Sendable, Equatable {
    public static let defaultIterations = 200_000
    /// Bounds a receiver accepts from a server (a hostile one cannot make it spin for minutes).
    public static let iterationRange = 10_000...2_000_000

    public let salt: Data
    public let iterations: Int
    public let derived: Data

    public init(password: String, salt: Data = SPPWSecureRandom.bytes(16), iterations: Int = SPPWPasswordVerifier.defaultIterations) {
        self.salt = salt
        self.iterations = iterations
        self.derived = Self.derive(password: password, salt: salt, iterations: iterations)
    }

    /// PBKDF2-HMAC-SHA256 of the NFKC-normalised password, 32 bytes.
    public static func derive(password: String, salt: Data, iterations: Int) -> Data {
        let passwordBytes = [UInt8](SPPWCPace.normalizedSecret(password))
        let saltBytes = [UInt8](salt)
        var out = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            saltBytes.withUnsafeBufferPointer { sb in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    pw.count,
                    sb.baseAddress,
                    sb.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(clamping: iterations),
                    &out,
                    out.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(out)
    }
}

/// Identity key, paired devices and the headless password, as small files readable only by
/// this user (`0600` in a `0700` folder). Thread-safe.
public final class SPPWSecurityStore: @unchecked Sendable {
    public enum Role: String, Sendable {
        /// Clients this device (as a server) accepts.
        case clients
        /// Servers this device (as a receiver) trusts.
        case servers
    }

    public let directory: URL
    private let lock = NSLock()
    private var cachedIdentity: SPPWDeviceIdentity?
    private var cachedPeers: [Role: [SPPWTrustedPeer]] = [:]
    /// Called after the paired lists change (UI refresh).
    public var onChange: (@Sendable () -> Void)?

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/PyrowaveCast/Security` (the app container on iOS).
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PyrowaveCast", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
    }

    public static let shared = SPPWSecurityStore(directory: defaultDirectory())

    private func prepareDirectory() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func writePrivate(_ data: Data, to name: String) {
        prepareDirectory()
        let url = directory.appendingPathComponent(name)
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func read(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// This device's identity, created on first use.
    public var identity: SPPWDeviceIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        let identity: SPPWDeviceIdentity
        if let raw = read("identity.key"), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            identity = SPPWDeviceIdentity(signingKey: key)
        } else {
            identity = SPPWDeviceIdentity()
            writePrivate(identity.signingKey.rawRepresentation, to: "identity.key")
        }
        cachedIdentity = identity
        return identity
    }

    private func fileName(_ role: Role) -> String { "trusted-\(role.rawValue).json" }

    private func loadPeers(_ role: Role) -> [SPPWTrustedPeer] {
        if let cached = cachedPeers[role] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let peers = read(fileName(role)).flatMap { try? decoder.decode([SPPWTrustedPeer].self, from: $0) } ?? []
        cachedPeers[role] = peers
        return peers
    }

    private func savePeers(_ peers: [SPPWTrustedPeer], role: Role) {
        cachedPeers[role] = peers
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(peers) {
            writePrivate(data, to: fileName(role))
        }
    }

    public func trustedPeers(_ role: Role) -> [SPPWTrustedPeer] {
        lock.lock()
        defer { lock.unlock() }
        return loadPeers(role)
    }

    public func trustedPeer(_ role: Role, fingerprint: SPPWFingerprint) -> SPPWTrustedPeer? {
        lock.lock()
        defer { lock.unlock() }
        return loadPeers(role).first { $0.fingerprintHex == fingerprint.hex }
    }

    public func isTrusted(_ role: Role, fingerprint: SPPWFingerprint) -> Bool {
        trustedPeer(role, fingerprint: fingerprint) != nil
    }

    /// Adds (or renames) a paired device.
    public func trust(_ role: Role, publicKey: Data, name: String) {
        lock.lock()
        var peers = loadPeers(role)
        let fingerprint = SPPWFingerprint(publicKey: publicKey)
        if let index = peers.firstIndex(where: { $0.fingerprintHex == fingerprint.hex }) {
            peers[index].name = name
            peers[index].lastSeen = Date()
        } else {
            peers.append(SPPWTrustedPeer(publicKey: publicKey, name: name))
        }
        savePeers(peers, role: role)
        lock.unlock()
        onChange?()
    }

    /// Updates the last-seen date (at most once a minute, to keep writes rare).
    public func noteSeen(_ role: Role, fingerprint: SPPWFingerprint) {
        lock.lock()
        var peers = loadPeers(role)
        guard let index = peers.firstIndex(where: { $0.fingerprintHex == fingerprint.hex }),
              Date().timeIntervalSince(peers[index].lastSeen) > 60 else {
            lock.unlock()
            return
        }
        peers[index].lastSeen = Date()
        savePeers(peers, role: role)
        lock.unlock()
    }

    public func forget(_ role: Role, fingerprintHex: String) {
        lock.lock()
        let peers = loadPeers(role).filter { $0.fingerprintHex != fingerprintHex }
        savePeers(peers, role: role)
        lock.unlock()
        onChange?()
    }

    /// The headless password's verifier (salted PBKDF2), or `nil` when none is set.
    public var serverPasswordVerifier: SPPWPasswordVerifier? {
        lock.lock()
        defer { lock.unlock() }
        return read("server-password.json").flatMap { try? JSONDecoder().decode(SPPWPasswordVerifier.self, from: $0) }
    }

    public var hasServerPassword: Bool { serverPasswordVerifier != nil }

    /// Sets (or with `nil`/empty, removes) the password for headless pairing. Only the salted
    /// PBKDF2 value is written.
    public func setServerPassword(_ password: String?) {
        let verifier = password.flatMap { $0.isEmpty ? nil : SPPWPasswordVerifier(password: $0) }
        lock.lock()
        if let verifier, let data = try? JSONEncoder().encode(verifier) {
            writePrivate(data, to: "server-password.json")
        } else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("server-password.json"))
        }
        lock.unlock()
    }
}

// MARK: Pairing configuration and events

/// How a server with encryption on admits a client it does not know yet.
public enum SPPWPairingMode: UInt8, Sendable, CaseIterable, Codable {
    /// Any client is accepted (still encrypted). Clients may pair with a PIN to verify the server.
    case open = 0
    /// A 5-digit PIN appears on the server; the user types it on the client.
    case pin = 1
    /// A password set on the server (headless servers without a screen to show a PIN).
    case password = 2
}

/// The secret a client must enter to pair.
public enum SPPWPairingMethod: UInt8, Sendable {
    case pin = 1
    case password = 2
}

public struct SPPWServerSecurityConfiguration: Sendable, Equatable {
    public var encryptionEnabled: Bool
    public var pairingMode: SPPWPairingMode

    public init(encryptionEnabled: Bool = true, pairingMode: SPPWPairingMode = .pin) {
        self.encryptionEnabled = encryptionEnabled
        self.pairingMode = pairingMode
    }
}

/// A PIN for the server to show.
public struct SPPWPairingPINPrompt: Sendable, Equatable {
    public let pin: String
    public let clientName: String
    public let clientFingerprint: SPPWFingerprint
    public let expiresAt: Date

    public init(pin: String, clientName: String, clientFingerprint: SPPWFingerprint, expiresAt: Date) {
        self.pin = pin
        self.clientName = clientName
        self.clientFingerprint = clientFingerprint
        self.expiresAt = expiresAt
    }
}

public enum SPPWServerSecurityEvent: Sendable {
    case pinRequested(SPPWPairingPINPrompt)
    case pinCleared
    case paired(SPPWTrustedPeer)
    case clientAuthenticated(name: String, fingerprint: SPPWFingerprint, paired: Bool)
    case log(String)
}

// MARK: Server engine

/// Server side of the secure transport, one instance per listening socket. Thread-safe;
/// runs on the socket queues.
public final class SPPWServerSecurity: @unchecked Sendable {
    public static let pinLifetime: TimeInterval = 120
    public static let pinAttempts = 3
    /// Password guesses per client address, and in total, per `passwordWindow`.
    public static let passwordAttemptsPerHost = 5
    public static let passwordAttemptsTotal = 30
    public static let passwordWindow: TimeInterval = 300
    static let maximumSessions = 64
    static let sessionIdleLimit: TimeInterval = 600

    private enum State {
        case awaitingAuth
        case authenticated
        case ready
    }

    private struct PendingPairing {
        let clientShare: Data
        let expectedClientConfirm: Data
        let response: Data
    }

    private final class Session {
        let hello: Data
        let replyDatagram: Data
        let transcript: Data
        let keys: SPPWSessionKeys
        let clientPublicKey: Data
        let clientName: String
        var state: State = .awaitingAuth
        var lastSeen = Date()
        var authResponse: Data?
        var challengeResponse: Data?
        var pending: PendingPairing?
        var confirmRequest: Data?
        var confirmResponse: Data?

        var fingerprint: SPPWFingerprint { SPPWFingerprint(publicKey: clientPublicKey) }

        init(hello: Data, replyDatagram: Data, transcript: Data, keys: SPPWSessionKeys, clientPublicKey: Data, clientName: String) {
            self.hello = hello
            self.replyDatagram = replyDatagram
            self.transcript = transcript
            self.keys = keys
            self.clientPublicKey = clientPublicKey
            self.clientName = clientName
        }
    }

    private struct ActivePIN {
        let pin: String
        let peerKey: String
        let fingerprint: SPPWFingerprint
        let expiresAt: Date
        var attemptsLeft: Int
    }

    public let store: SPPWSecurityStore
    private let lock = NSLock()
    private var configuration: SPPWServerSecurityConfiguration
    private var serverName: String
    private var sessions: [String: Session] = [:]
    private var activePIN: ActivePIN?
    private var passwordFailures: [(host: String, at: Date)] = []
    private var lastNoticeSent: [String: Date] = [:]
    private let onEvent: @Sendable (SPPWServerSecurityEvent) -> Void
    /// Overridable for tests.
    var now: () -> Date = Date.init
    var makePIN: () -> String = SPPWServerSecurity.randomPIN

    public init(
        store: SPPWSecurityStore = .shared,
        configuration: SPPWServerSecurityConfiguration,
        serverName: String,
        onEvent: @escaping @Sendable (SPPWServerSecurityEvent) -> Void = { _ in }
    ) {
        self.store = store
        self.configuration = configuration
        self.serverName = serverName
        self.onEvent = onEvent
    }

    /// A uniformly random 5-digit PIN (leading zeros kept).
    public static func randomPIN() -> String {
        var value: UInt32 = 0
        repeat {
            _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        } while value >= UInt32.max - (UInt32.max % 100_000)
        return String(format: "%05u", value % 100_000)
    }

    public var currentConfiguration: SPPWServerSecurityConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    /// Applies new settings; existing secure sessions end (clients reconnect).
    public func update(_ newConfiguration: SPPWServerSecurityConfiguration) {
        lock.lock()
        let changed = newConfiguration != configuration
        configuration = newConfiguration
        if changed {
            sessions.removeAll()
        }
        let hadPIN = activePIN != nil
        if changed { activePIN = nil }
        lock.unlock()
        if changed && hadPIN { onEvent(.pinCleared) }
    }

    public func setServerName(_ name: String) {
        lock.lock()
        serverName = name
        lock.unlock()
    }

    /// Ends the sessions of a client whose pairing was removed.
    public func revoke(fingerprintHex: String) {
        lock.lock()
        sessions = sessions.filter { $0.value.fingerprint.hex != fingerprintHex || configuration.pairingMode == .open }
        lock.unlock()
    }

    /// Clears the PIN on screen (the user dismissed it).
    public func cancelPIN() {
        lock.lock()
        let had = activePIN != nil
        activePIN = nil
        lock.unlock()
        if had { onEvent(.pinCleared) }
    }

    // MARK: Datagram hooks

    /// Outgoing app datagram for `peerKey`: sealed when encryption is on (`nil` if the peer has
    /// no ready session), unchanged when it is off.
    public func outgoing(_ datagram: Data, to peerKey: String) -> Data? {
        lock.lock()
        let encrypted = configuration.encryptionEnabled
        let session = sessions[peerKey]
        lock.unlock()
        guard encrypted else { return datagram }
        guard let session, session.state == .ready else { return nil }
        return session.keys.serverToClient.seal(datagram)
    }

    /// Incoming datagram from `peerKey`. Returns the plaintext app datagram, or `nil` when it was
    /// a security message (answered through `reply`) or must be dropped.
    public func incoming(_ datagram: Data, from peerKey: String, reply: (Data) -> Void) -> Data? {
        guard let kind = SPPWSecureEnvelope.kind(of: datagram) else { return nil }
        lock.lock()
        let encrypted = configuration.encryptionEnabled
        lock.unlock()

        guard encrypted else {
            if kind == SPPWSecureKind.secureHello {
                sendNotice(.encryptionDisabled, to: peerKey, reply: reply)
                return nil
            }
            if SPPWSecureEnvelope.isSealed(datagram) || kind >= SPPWSecureKind.secureHello { return nil }
            return datagram
        }

        if kind == SPPWSecureKind.secureHello, !SPPWSecureEnvelope.isSealed(datagram) {
            handleHello(datagram, from: peerKey, reply: reply)
            return nil
        }
        guard SPPWSecureEnvelope.isSealed(datagram) else {
            // Plaintext app traffic is refused; tell a plaintext client why (its hello only).
            if kind == 1 { sendNotice(.encryptionRequired, to: peerKey, reply: reply) }
            return nil
        }
        lock.lock()
        let session = sessions[peerKey]
        lock.unlock()
        guard let session else {
            sendNotice(.unknownSession, to: peerKey, reply: reply)
            return nil
        }
        guard let plain = session.keys.clientToServer.open(datagram) else { return nil }
        lock.lock()
        session.lastSeen = now()
        let state = session.state
        lock.unlock()
        switch kind {
        case SPPWSecureKind.secureAuth:
            handleAuth(SPPWSecureEnvelope.payload(of: plain), session: session, peerKey: peerKey, reply: reply)
            return nil
        case SPPWSecureKind.pairing:
            handlePairing(SPPWSecureEnvelope.payload(of: plain), session: session, peerKey: peerKey, reply: reply)
            return nil
        case SPPWSecureKind.secureHello, SPPWSecureKind.secureReply, SPPWSecureKind.secureNotice:
            return nil
        default:
            return state == .ready ? plain : nil
        }
    }

    private func sendNotice(_ code: SPPWSecureNoticeCode, to peerKey: String, reply: (Data) -> Void) {
        lock.lock()
        let current = now()
        if let last = lastNoticeSent[peerKey], current.timeIntervalSince(last) < 0.5 {
            lock.unlock()
            return
        }
        lastNoticeSent[peerKey] = current
        if lastNoticeSent.count > 256 {
            lastNoticeSent = lastNoticeSent.filter { current.timeIntervalSince($0.value) < 10 }
        }
        lock.unlock()
        reply(SPPWSecureEnvelope.makeDatagram(kind: SPPWSecureKind.secureNotice, payload: Data([code.rawValue])))
    }

    private func sendSealed(_ kind: UInt8, _ payload: Data, session: Session, reply: (Data) -> Void) {
        if let sealed = session.keys.serverToClient.seal(SPPWSecureEnvelope.makeDatagram(kind: kind, payload: payload)) {
            reply(sealed)
        }
    }

    // MARK: Handshake

    private func handleHello(_ datagram: Data, from peerKey: String, reply: (Data) -> Void) {
        let hello = SPPWSecureEnvelope.payload(of: datagram)
        guard let parsed = SPPWSecureHello(parsing: hello) else { return }
        lock.lock()
        if let existing = sessions[peerKey], existing.hello == hello {
            // A retransmitted hello: same answer, same keys.
            existing.lastSeen = now()
            lock.unlock()
            reply(existing.replyDatagram)
            return
        }
        let mode = configuration.pairingMode
        let name = serverName
        lock.unlock()

        let identity = store.identity
        let clientFingerprint = SPPWFingerprint(publicKey: parsed.identityKey)
        let clientTrusted = store.isTrusted(.clients, fingerprint: clientFingerprint)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let clientEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: parsed.ephemeralKey),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: clientEphemeral) else { return }

        var body = Data([SPPWSecureEnvelope.protocolVersion, mode.rawValue, clientTrusted ? 1 : 0])
        body.append(ephemeral.publicKey.rawRepresentation)
        body.append(identity.publicKey)
        body.append(SPPWSecureRandom.bytes(16))
        SPPWSecureEncoding.appendShortString(name, to: &body)
        guard let signature = identity.sign(SPPWSecureTranscript.serverSignatureInput(hello: hello, replyBody: body)) else { return }
        let replyPayload = body + signature
        let transcript = SPPWSecureTranscript.hash(hello: hello, reply: replyPayload)
        let session = Session(
            hello: hello,
            replyDatagram: SPPWSecureEnvelope.makeDatagram(kind: SPPWSecureKind.secureReply, payload: replyPayload),
            transcript: transcript,
            keys: SPPWSessionKeys(sharedSecret: shared, transcript: transcript),
            clientPublicKey: parsed.identityKey,
            clientName: parsed.name
        )
        lock.lock()
        let current = now()
        sessions = sessions.filter { current.timeIntervalSince($0.value.lastSeen) < Self.sessionIdleLimit }
        if sessions.count >= Self.maximumSessions,
           let oldest = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            sessions.removeValue(forKey: oldest)
        }
        sessions[peerKey] = session
        lock.unlock()
        reply(session.replyDatagram)
    }

    private func handleAuth(_ payload: Data, session: Session, peerKey: String, reply: (Data) -> Void) {
        lock.lock()
        if let cached = session.authResponse {
            lock.unlock()
            sendSealed(SPPWSecureKind.secureAuth, cached, session: session, reply: reply)
            return
        }
        let mode = configuration.pairingMode
        lock.unlock()
        guard payload.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: session.clientPublicKey),
              key.isValidSignature(payload, for: SPPWSecureTranscript.clientSignatureInput(transcript: session.transcript))
        else {
            lock.lock()
            sessions.removeValue(forKey: peerKey)
            lock.unlock()
            onEvent(.log("Invalid client signature from \(peerKey)"))
            return
        }
        let paired = store.isTrusted(.clients, fingerprint: session.fingerprint)
        let accepted = paired || mode == .open
        let method: SPPWPairingMethod = mode == .password ? .password : .pin
        let response = Data([accepted ? 0 : 1, method.rawValue])
        lock.lock()
        session.authResponse = response
        session.state = accepted ? .ready : .authenticated
        lock.unlock()
        if paired {
            store.noteSeen(.clients, fingerprint: session.fingerprint)
        }
        onEvent(.clientAuthenticated(name: session.clientName, fingerprint: session.fingerprint, paired: paired))
        sendSealed(SPPWSecureKind.secureAuth, response, session: session, reply: reply)
    }

    // MARK: Pairing

    private enum PairingOp: UInt8 {
        case start = 0
        case challenge = 1
        case clientShare = 2
        case serverShare = 3
        case clientConfirm = 4
        case result = 5
    }

    /// Result codes of `pairing.result`.
    enum PairingResult: UInt8 {
        case success = 0
        case wrongSecret = 1
        case locked = 2
        case expired = 3
        case unavailable = 4
    }

    private func pairingMethod() -> SPPWPairingMethod {
        lock.lock()
        defer { lock.unlock() }
        return configuration.pairingMode == .password ? .password : .pin
    }

    private func handlePairing(_ payload: Data, session: Session, peerKey: String, reply: (Data) -> Void) {
        guard let opByte = payload.first, let op = PairingOp(rawValue: opByte) else { return }
        lock.lock()
        let authenticated = session.state != .awaitingAuth
        lock.unlock()
        guard authenticated else { return }
        let body = Data(payload.dropFirst())
        switch op {
        case .start:
            handlePairingStart(session: session, peerKey: peerKey, reply: reply)
        case .clientShare:
            handleClientShare(body, session: session, peerKey: peerKey, reply: reply)
        case .clientConfirm:
            handleClientConfirm(body, session: session, peerKey: peerKey, reply: reply)
        case .challenge, .serverShare, .result:
            break
        }
    }

    private func pairingResult(_ result: PairingResult, attemptsLeft: Int) -> Data {
        Data([PairingOp.result.rawValue, result.rawValue, UInt8(clamping: max(attemptsLeft, 0))])
    }

    private func handlePairingStart(session: Session, peerKey: String, reply: (Data) -> Void) {
        let method = pairingMethod()
        var attemptsLeft = Self.passwordAttemptsPerHost
        var prompt: SPPWPairingPINPrompt?
        lock.lock()
        let current = now()
        if method == .pin {
            if let pin = activePIN, pin.peerKey == peerKey, pin.fingerprint == session.fingerprint,
               pin.expiresAt > current, pin.attemptsLeft > 0 {
                attemptsLeft = pin.attemptsLeft
            } else {
                let pin = ActivePIN(
                    pin: makePIN(),
                    peerKey: peerKey,
                    fingerprint: session.fingerprint,
                    expiresAt: current.addingTimeInterval(Self.pinLifetime),
                    attemptsLeft: Self.pinAttempts
                )
                activePIN = pin
                attemptsLeft = pin.attemptsLeft
                prompt = SPPWPairingPINPrompt(pin: pin.pin, clientName: session.clientName, clientFingerprint: pin.fingerprint, expiresAt: pin.expiresAt)
            }
        } else {
            attemptsLeft = passwordAttemptsLeftLocked(host: Self.host(of: peerKey))
        }
        var response = Data([PairingOp.challenge.rawValue, method.rawValue, UInt8(clamping: attemptsLeft)])
        if method == .password, let verifier = store.serverPasswordVerifier {
            response.append(verifier.salt)
            SPPWSecureEncoding.appendU32(UInt32(clamping: verifier.iterations), to: &response)
        }
        session.challengeResponse = response
        lock.unlock()
        if let prompt {
            onEvent(.pinRequested(prompt))
            onEvent(.log("Pairing requested by \(session.clientName) (\(session.fingerprint.short))"))
        }
        sendSealed(SPPWSecureKind.pairing, response, session: session, reply: reply)
    }

    static func host(of peerKey: String) -> String {
        if peerKey.hasPrefix("["), let end = peerKey.range(of: "]:", options: .backwards) {
            return String(peerKey[peerKey.index(after: peerKey.startIndex)..<end.lowerBound])
        }
        if let colon = peerKey.lastIndex(of: ":"), peerKey.filter({ $0 == ":" }).count == 1 {
            return String(peerKey[..<colon])
        }
        return peerKey
    }

    private func passwordAttemptsLeftLocked(host: String) -> Int {
        let current = now()
        passwordFailures = passwordFailures.filter { current.timeIntervalSince($0.at) < Self.passwordWindow }
        let hostFailures = passwordFailures.filter { $0.host == host }.count
        let left = min(Self.passwordAttemptsPerHost - hostFailures, Self.passwordAttemptsTotal - passwordFailures.count)
        return max(left, 0)
    }

    private func handleClientShare(_ share: Data, session: Session, peerKey: String, reply: (Data) -> Void) {
        guard share.count == 32 else { return }
        lock.lock()
        if let pending = session.pending, pending.clientShare == share {
            lock.unlock()
            sendSealed(SPPWSecureKind.pairing, pending.response, session: session, reply: reply)
            return
        }
        let method: SPPWPairingMethod = configuration.pairingMode == .password ? .password : .pin
        let current = now()
        var secret: Data?
        var failure: (PairingResult, Int)?
        var cleared = false
        switch method {
        case .pin:
            if var pin = activePIN, pin.peerKey == peerKey, pin.fingerprint == session.fingerprint {
                if pin.expiresAt <= current {
                    activePIN = nil
                    cleared = true
                    failure = (.expired, 0)
                } else if pin.attemptsLeft <= 0 {
                    failure = (.locked, 0)
                } else {
                    // Each share is one guess, counted before the answer goes out.
                    pin.attemptsLeft -= 1
                    activePIN = pin
                    secret = SPPWCPace.normalizedSecret(pin.pin)
                }
            } else {
                failure = (.expired, 0)
            }
        case .password:
            let host = Self.host(of: peerKey)
            if passwordAttemptsLeftLocked(host: host) <= 0 {
                failure = (.locked, 0)
            } else if let verifier = store.serverPasswordVerifier {
                // Counted as a failure until the confirmation proves otherwise.
                passwordFailures.append((host, current))
                secret = verifier.derived
            } else {
                failure = (.unavailable, 0)
            }
        }
        lock.unlock()
        if cleared { onEvent(.pinCleared) }
        if let failure {
            sendSealed(SPPWSecureKind.pairing, pairingResult(failure.0, attemptsLeft: failure.1), session: session, reply: reply)
            return
        }
        guard let secret,
              let party = try? SPPWCPace.start(secret: secret, sessionID: session.transcript),
              let isk = try? SPPWCPace.finish(
                party,
                peerShare: share,
                sessionID: session.transcript,
                initiatorShare: share,
                responderShare: party.share
              ) else { return }
        let confirmations = SPPWSecureTranscript.pairingConfirmations(isk: isk, transcript: session.transcript)
        var response = Data([PairingOp.serverShare.rawValue])
        response.append(party.share)
        response.append(confirmations.server)
        lock.lock()
        session.pending = PendingPairing(clientShare: share, expectedClientConfirm: confirmations.client, response: response)
        session.confirmRequest = nil
        session.confirmResponse = nil
        lock.unlock()
        sendSealed(SPPWSecureKind.pairing, response, session: session, reply: reply)
    }

    private func handleClientConfirm(_ confirm: Data, session: Session, peerKey: String, reply: (Data) -> Void) {
        lock.lock()
        if let request = session.confirmRequest, request == confirm, let cached = session.confirmResponse {
            lock.unlock()
            sendSealed(SPPWSecureKind.pairing, cached, session: session, reply: reply)
            return
        }
        guard let pending = session.pending else {
            lock.unlock()
            return
        }
        let method: SPPWPairingMethod = configuration.pairingMode == .password ? .password : .pin
        let matches = SPPWSecureTranscript.constantTimeEqual(confirm, pending.expectedClientConfirm)
        var response: Data
        var cleared = false
        var paired = false
        if matches {
            session.state = .ready
            paired = true
            if method == .pin, activePIN?.fingerprint == session.fingerprint {
                activePIN = nil
                cleared = true
            }
            if method == .password {
                let host = Self.host(of: peerKey)
                if let index = passwordFailures.lastIndex(where: { $0.host == host }) {
                    passwordFailures.remove(at: index)
                }
            }
            response = pairingResult(.success, attemptsLeft: 0)
        } else if method == .pin {
            let left = activePIN?.attemptsLeft ?? 0
            if left <= 0 {
                activePIN = nil
                cleared = true
                response = pairingResult(.locked, attemptsLeft: 0)
            } else {
                response = pairingResult(.wrongSecret, attemptsLeft: left)
            }
        } else {
            let left = passwordAttemptsLeftLocked(host: Self.host(of: peerKey))
            response = pairingResult(left > 0 ? .wrongSecret : .locked, attemptsLeft: left)
        }
        session.pending = nil
        session.confirmRequest = confirm
        session.confirmResponse = response
        lock.unlock()
        if paired {
            store.trust(.clients, publicKey: session.clientPublicKey, name: session.clientName)
            if let peer = store.trustedPeer(.clients, fingerprint: session.fingerprint) {
                onEvent(.paired(peer))
            }
            onEvent(.log("Abbinato \(session.clientName) (\(session.fingerprint.short))"))
        } else {
            onEvent(.log("Pairing failed for \(session.clientName): wrong secret"))
        }
        if cleared { onEvent(.pinCleared) }
        sendSealed(SPPWSecureKind.pairing, response, session: session, reply: reply)
    }
}

// MARK: Client engine

/// How the receiver ended up talking to the server.
public enum SPPWServerTrustLevel: Sendable, Equatable {
    /// Paired: the server proved it knows the PIN/password (now or in an earlier pairing).
    case paired
    /// Encrypted, but the server accepts anyone and was not verified ("open" mode).
    case unverified
    /// Encryption off on this receiver.
    case plaintext
}

public struct SPPWServerSecurityInfo: Sendable, Equatable {
    public let name: String
    public let fingerprint: SPPWFingerprint?
    public let trust: SPPWServerTrustLevel
}

public struct SPPWPairingRequest: Sendable, Equatable {
    public let method: SPPWPairingMethod
    public let serverName: String
    public let serverFingerprint: SPPWFingerprint
    public let attemptsLeft: Int
    /// The previous PIN/password was wrong (or the PIN expired and a new one is on screen).
    public let previousAttemptFailed: Bool
}

public enum SPPWSecurityFailure: Sendable, Equatable {
    case serverRequiresEncryption
    case serverEncryptionDisabled
    case badServerSignature
    case denied
    case pairingLocked
    case pairingUnavailable
    case cancelled
}

public enum SPPWClientSecurityEvent: Sendable, Equatable {
    case secured(SPPWServerSecurityInfo)
    case needsSecret(SPPWPairingRequest)
    case paired(SPPWServerSecurityInfo)
    case failed(SPPWSecurityFailure)
}

/// Receiver side of the secure transport, one instance per connection attempt. Thread-safe.
public final class SPPWClientSecurity: @unchecked Sendable {
    private enum State: Equatable {
        case idle
        case helloSent
        case authSent
        case pairingStarted
        case awaitingSecret
        case shareSent
        case confirmSent
        case ready
        case failed
    }

    public let encryptionEnabled: Bool
    private let store: SPPWSecurityStore
    private let deviceName: String
    private let lock = NSLock()
    private var state: State = .idle
    private var hello = Data()
    private var helloDatagram = Data()
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var transcript = Data()
    private var keys: SPPWSessionKeys?
    private var serverName = ""
    private var serverPublicKey = Data()
    private var pairingMethod: SPPWPairingMethod = .pin
    private var cpace: SPPWCPace.Party?
    private var serverVerified = false
    /// Last security message (plaintext kind + payload) to retransmit while waiting.
    private var lastRequest: (kind: UInt8, payload: Data)?
    private var queued: [Data] = []
    private var retransmitTimer: DispatchSourceTimer?
    private var sendRaw: (@Sendable (Data) -> Void)?
    private let onEvent: @Sendable (SPPWClientSecurityEvent) -> Void
    private let queue = DispatchQueue(label: "sppw.security.client", qos: .userInitiated)

    public init(
        store: SPPWSecurityStore = .shared,
        encryptionEnabled: Bool,
        deviceName: String,
        onEvent: @escaping @Sendable (SPPWClientSecurityEvent) -> Void = { _ in }
    ) {
        self.store = store
        self.encryptionEnabled = encryptionEnabled
        self.deviceName = deviceName
        self.onEvent = onEvent
    }

    deinit {
        retransmitTimer?.cancel()
    }

    /// True while the user is being asked for the PIN or password (callers suspend timeouts).
    public var isAwaitingUser: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .awaitingSecret
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .ready || !encryptionEnabled
    }

    /// Attaches the raw transport and starts the handshake (no-op with encryption off).
    public func start(sendRaw: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        self.sendRaw = sendRaw
        lock.unlock()
        guard encryptionEnabled else {
            onEvent(.secured(SPPWServerSecurityInfo(name: "", fingerprint: nil, trust: .plaintext)))
            return
        }
        beginHandshake()
        startRetransmitTimer()
    }

    public func stop() {
        lock.lock()
        retransmitTimer?.cancel()
        retransmitTimer = nil
        sendRaw = nil
        queued.removeAll()
        lock.unlock()
    }

    private func beginHandshake() {
        let identity = store.identity
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var payload = Data([SPPWSecureEnvelope.protocolVersion, 0])
        payload.append(ephemeral.publicKey.rawRepresentation)
        payload.append(identity.publicKey)
        payload.append(SPPWSecureRandom.bytes(16))
        SPPWSecureEncoding.appendShortString(deviceName, to: &payload)
        let datagram = SPPWSecureEnvelope.makeDatagram(kind: SPPWSecureKind.secureHello, payload: payload)
        lock.lock()
        self.ephemeral = ephemeral
        hello = payload
        helloDatagram = datagram
        keys = nil
        cpace = nil
        serverVerified = false
        lastAttemptFailed = false
        lastRequest = nil
        state = .helloSent
        let send = sendRaw
        lock.unlock()
        send?(datagram)
    }

    private func startRetransmitTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.retransmit() }
        lock.lock()
        retransmitTimer?.cancel()
        retransmitTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func retransmit() {
        lock.lock()
        let current = state
        let request = lastRequest
        let datagram = helloDatagram
        let send = sendRaw
        let direction = keys?.clientToServer
        lock.unlock()
        switch current {
        case .helloSent:
            send?(datagram)
        case .authSent, .pairingStarted, .shareSent, .confirmSent:
            if let request, let direction,
               let sealed = direction.seal(SPPWSecureEnvelope.makeDatagram(kind: request.kind, payload: request.payload)) {
                send?(sealed)
            }
        case .idle, .awaitingSecret, .ready, .failed:
            break
        }
    }

    private func sendRequest(kind: UInt8, payload: Data, newState: State) {
        lock.lock()
        state = newState
        lastRequest = (kind, payload)
        let direction = keys?.clientToServer
        let send = sendRaw
        lock.unlock()
        if let direction, let sealed = direction.seal(SPPWSecureEnvelope.makeDatagram(kind: kind, payload: payload)) {
            send?(sealed)
        }
    }

    private func fail(_ failure: SPPWSecurityFailure) {
        lock.lock()
        state = .failed
        lastRequest = nil
        queued.removeAll()
        lock.unlock()
        onEvent(.failed(failure))
    }

    // MARK: Datagram hooks

    /// Outgoing app datagram: sealed when ready, unchanged with encryption off, otherwise queued
    /// until the session is ready (`nil`; the newest 32 are kept).
    public func outgoing(_ datagram: Data) -> Data? {
        guard encryptionEnabled else { return datagram }
        lock.lock()
        if state == .ready, let direction = keys?.clientToServer {
            lock.unlock()
            return direction.seal(datagram)
        }
        if state != .failed {
            queued.append(datagram)
            if queued.count > 32 { queued.removeFirst(queued.count - 32) }
        }
        lock.unlock()
        return nil
    }

    /// Incoming datagram: the plaintext app datagram, or `nil` for security messages and drops.
    public func incoming(_ datagram: Data) -> Data? {
        guard let kind = SPPWSecureEnvelope.kind(of: datagram) else { return nil }
        let sealed = SPPWSecureEnvelope.isSealed(datagram)
        if !sealed && kind == SPPWSecureKind.secureNotice {
            handleNotice(SPPWSecureEnvelope.payload(of: datagram))
            return nil
        }
        guard encryptionEnabled else {
            return sealed || kind >= SPPWSecureKind.secureHello ? nil : datagram
        }
        if !sealed {
            if kind == SPPWSecureKind.secureReply {
                handleReply(SPPWSecureEnvelope.payload(of: datagram))
            }
            return nil
        }
        lock.lock()
        let direction = keys?.serverToClient
        let current = state
        lock.unlock()
        guard let direction, let plain = direction.open(datagram) else { return nil }
        switch kind {
        case SPPWSecureKind.secureAuth:
            handleAuthResponse(SPPWSecureEnvelope.payload(of: plain))
            return nil
        case SPPWSecureKind.pairing:
            handlePairing(SPPWSecureEnvelope.payload(of: plain))
            return nil
        case SPPWSecureKind.secureHello, SPPWSecureKind.secureReply, SPPWSecureKind.secureNotice:
            return nil
        default:
            return current == .ready ? plain : nil
        }
    }

    private func handleNotice(_ payload: Data) {
        guard let code = payload.first.flatMap(SPPWSecureNoticeCode.init(rawValue:)) else { return }
        switch code {
        case .unknownSession:
            guard encryptionEnabled else { return }
            lock.lock()
            let current = state
            lock.unlock()
            // The server restarted or forgot us: start again (answers to an old hello are ignored).
            if current == .ready || current == .authSent || current == .confirmSent || current == .shareSent || current == .pairingStarted {
                beginHandshake()
            }
        case .encryptionRequired:
            if !encryptionEnabled { fail(.serverRequiresEncryption) }
        case .encryptionDisabled:
            if encryptionEnabled { fail(.serverEncryptionDisabled) }
        }
    }

    private func handleReply(_ payload: Data) {
        lock.lock()
        guard state == .helloSent, let ephemeral else {
            lock.unlock()
            return
        }
        let hello = self.hello
        lock.unlock()
        guard let reply = SPPWSecureReply(parsing: payload),
              let serverKey = try? Curve25519.Signing.PublicKey(rawRepresentation: reply.identityKey),
              serverKey.isValidSignature(reply.signature, for: SPPWSecureTranscript.serverSignatureInput(hello: hello, replyBody: reply.body)),
              let serverEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.ephemeralKey),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: serverEphemeral)
        else {
            fail(.badServerSignature)
            return
        }
        let transcript = SPPWSecureTranscript.hash(hello: hello, reply: payload)
        guard let signature = store.identity.sign(SPPWSecureTranscript.clientSignatureInput(transcript: transcript)) else { return }
        lock.lock()
        self.transcript = transcript
        keys = SPPWSessionKeys(sharedSecret: shared, transcript: transcript)
        serverName = reply.name
        serverPublicKey = reply.identityKey
        replyMode = reply.mode
        lock.unlock()
        sendRequest(kind: SPPWSecureKind.secureAuth, payload: signature, newState: .authSent)
    }

    private func serverInfo(_ trust: SPPWServerTrustLevel) -> SPPWServerSecurityInfo {
        lock.lock()
        defer { lock.unlock() }
        return SPPWServerSecurityInfo(name: serverName, fingerprint: SPPWFingerprint(publicKey: serverPublicKey), trust: trust)
    }

    private func becomeReady(_ trust: SPPWServerTrustLevel) {
        lock.lock()
        state = .ready
        lastRequest = nil
        let pending = queued
        queued.removeAll()
        let direction = keys?.clientToServer
        let send = sendRaw
        lock.unlock()
        let info = serverInfo(trust)
        onEvent(trust == .paired && serverVerified ? .paired(info) : .secured(info))
        if let direction, let send {
            for datagram in pending {
                if let sealed = direction.seal(datagram) { send(sealed) }
            }
        }
    }

    private func handleAuthResponse(_ payload: Data) {
        lock.lock()
        guard state == .authSent, payload.count >= 2 else {
            lock.unlock()
            return
        }
        pairingMethod = SPPWPairingMethod(rawValue: payload[payload.startIndex + 1]) ?? .pin
        let serverFingerprint = SPPWFingerprint(publicKey: serverPublicKey)
        lock.unlock()
        let serverKnown = store.isTrusted(.servers, fingerprint: serverFingerprint)
        lock.lock()
        let mode = replyMode
        lock.unlock()
        switch payload[payload.startIndex] {
        case 0 where serverKnown:
            store.noteSeen(.servers, fingerprint: serverFingerprint)
            becomeReady(.paired)
        case 0 where mode == .open:
            // An open server accepts anyone: encrypted, but the server is not verified.
            becomeReady(.unverified)
        case 0:
            // It knows us but we do not know it (we forgot it): verify it with a PIN first.
            sendRequest(kind: SPPWSecureKind.pairing, payload: Data([0]), newState: .pairingStarted)
        case 1:
            sendRequest(kind: SPPWSecureKind.pairing, payload: Data([0]), newState: .pairingStarted)
        default:
            fail(.denied)
        }
    }

    private var replyMode: SPPWPairingMode = .pin

    private func handlePairing(_ payload: Data) {
        guard let op = payload.first else { return }
        let body = [UInt8](payload.dropFirst())
        switch op {
        case 1 where body.count >= 2:
            // Challenge: ask the user.
            lock.lock()
            guard state == .pairingStarted else {
                lock.unlock()
                return
            }
            state = .awaitingSecret
            lastRequest = nil
            let method = SPPWPairingMethod(rawValue: body[0]) ?? pairingMethod
            pairingMethod = method
            if method == .password, body.count >= 2 + 16 + 4 {
                passwordSalt = Data(body[2..<18])
                passwordIterations = Int(UInt32(body[18]) << 24 | UInt32(body[19]) << 16 | UInt32(body[20]) << 8 | UInt32(body[21]))
            } else {
                passwordSalt = nil
            }
            let request = SPPWPairingRequest(
                method: method,
                serverName: serverName,
                serverFingerprint: SPPWFingerprint(publicKey: serverPublicKey),
                attemptsLeft: Int(body[1]),
                previousAttemptFailed: lastAttemptFailed
            )
            lastAttemptFailed = false
            lock.unlock()
            onEvent(.needsSecret(request))
        case 3 where body.count == 64:
            lock.lock()
            guard state == .shareSent, let party = cpace else {
                lock.unlock()
                return
            }
            let transcript = self.transcript
            lock.unlock()
            let serverShare = Data(body[0..<32])
            let serverConfirm = Data(body[32..<64])
            guard let isk = try? SPPWCPace.finish(
                party,
                peerShare: serverShare,
                sessionID: transcript,
                initiatorShare: party.share,
                responderShare: serverShare
            ) else { return }
            let confirmations = SPPWSecureTranscript.pairingConfirmations(isk: isk, transcript: transcript)
            lock.lock()
            serverVerified = SPPWSecureTranscript.constantTimeEqual(serverConfirm, confirmations.server)
            lock.unlock()
            sendRequest(kind: SPPWSecureKind.pairing, payload: Data([4]) + confirmations.client, newState: .confirmSent)
        case 5 where body.count >= 2:
            lock.lock()
            guard state == .confirmSent || state == .shareSent else {
                lock.unlock()
                return
            }
            let verified = serverVerified
            let publicKey = serverPublicKey
            let name = serverName
            lock.unlock()
            let code = SPPWServerSecurity.PairingResult(rawValue: body[0])
            switch code {
            case .success where verified:
                store.trust(.servers, publicKey: publicKey, name: name)
                becomeReady(.paired)
            case .success:
                // The server says yes but never proved it knows the secret: not the real one.
                fail(.badServerSignature)
            case .wrongSecret:
                askAgain(attemptsLeft: Int(body[1]))
            case .expired, .locked:
                if pairingMethodIs(.pin) {
                    // A new PIN is shown on the server for the next try.
                    lock.lock()
                    lastAttemptFailed = true
                    lock.unlock()
                    sendRequest(kind: SPPWSecureKind.pairing, payload: Data([0]), newState: .pairingStarted)
                } else {
                    fail(.pairingLocked)
                }
            case .unavailable, .none:
                fail(.pairingUnavailable)
            }
        default:
            break
        }
    }

    private var lastAttemptFailed = false
    private var passwordSalt: Data?
    private var passwordIterations = SPPWPasswordVerifier.defaultIterations

    private func pairingMethodIs(_ method: SPPWPairingMethod) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pairingMethod == method
    }

    private func askAgain(attemptsLeft: Int) {
        lock.lock()
        state = .awaitingSecret
        lastRequest = nil
        let request = SPPWPairingRequest(
            method: pairingMethod,
            serverName: serverName,
            serverFingerprint: SPPWFingerprint(publicKey: serverPublicKey),
            attemptsLeft: attemptsLeft,
            previousAttemptFailed: true
        )
        lock.unlock()
        onEvent(.needsSecret(request))
    }

    /// The PIN or password the user typed (derived off the caller's thread: PBKDF2 takes a moment).
    public func provideSecret(_ secret: String) {
        queue.async { [weak self] in self?.applySecret(secret) }
    }

    /// Waits until work handed to the engine's queue (a typed secret) is done. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func applySecret(_ secret: String) {
        lock.lock()
        guard state == .awaitingSecret else {
            lock.unlock()
            return
        }
        let transcript = self.transcript
        let method = pairingMethod
        let salt = passwordSalt
        let iterations = passwordIterations
        lock.unlock()
        let secretBytes: Data
        if method == .password {
            // The server keeps only salted PBKDF2 of its password: derive the same value here.
            guard let salt, SPPWPasswordVerifier.iterationRange.contains(iterations) else {
                fail(.pairingUnavailable)
                return
            }
            secretBytes = SPPWPasswordVerifier.derive(password: secret, salt: salt, iterations: iterations)
        } else {
            secretBytes = SPPWCPace.normalizedSecret(secret)
        }
        guard let party = try? SPPWCPace.start(secret: secretBytes, sessionID: transcript) else { return }
        lock.lock()
        cpace = party
        serverVerified = false
        lock.unlock()
        sendRequest(kind: SPPWSecureKind.pairing, payload: Data([2]) + party.share, newState: .shareSent)
    }

    /// The user closed the PIN prompt.
    public func cancelPairing() {
        fail(.cancelled)
    }

}

/// Holds the client security layer of a transport without a socket hook (`NWConnection`),
/// read from network queues.
public final class SPPWClientSecurityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var security: SPPWClientSecurity?

    public init() {}

    public var current: SPPWClientSecurity? {
        get { lock.lock(); defer { lock.unlock() }; return security }
        set { lock.lock(); security = newValue; lock.unlock() }
    }

    /// Outgoing datagram: sealed, unchanged without a security layer, `nil` while queued.
    public func seal(_ datagram: Data) -> Data? {
        guard let security = current else { return datagram }
        return security.outgoing(datagram)
    }

    /// Incoming datagram: the plaintext app datagram, or `nil`.
    public func open(_ datagram: Data) -> Data? {
        guard let security = current else { return datagram }
        return security.incoming(datagram)
    }
}

// MARK: Messages and transcript

struct SPPWSecureHello {
    let ephemeralKey: Data
    let identityKey: Data
    let name: String

    init?(parsing payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 + 32 + 32 + 16 + 1, bytes[0] == SPPWSecureEnvelope.protocolVersion else { return nil }
        ephemeralKey = Data(bytes[2..<34])
        identityKey = Data(bytes[34..<66])
        var offset = 82
        guard let name = SPPWSecureEncoding.readShortString(bytes, offset: &offset), offset == bytes.count else { return nil }
        self.name = name
    }
}

struct SPPWSecureReply {
    let mode: SPPWPairingMode
    let clientTrusted: Bool
    let ephemeralKey: Data
    let identityKey: Data
    let name: String
    let body: Data
    let signature: Data

    init?(parsing payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3 + 32 + 32 + 16 + 1 + 64, bytes[0] == SPPWSecureEnvelope.protocolVersion,
              let mode = SPPWPairingMode(rawValue: bytes[1]) else { return nil }
        self.mode = mode
        clientTrusted = bytes[2] != 0
        ephemeralKey = Data(bytes[3..<35])
        identityKey = Data(bytes[35..<67])
        var offset = 83
        guard let name = SPPWSecureEncoding.readShortString(bytes, offset: &offset), offset + 64 == bytes.count else { return nil }
        self.name = name
        body = Data(bytes[0..<offset])
        signature = Data(bytes[offset...])
    }
}

enum SPPWSecureTranscript {
    static func serverSignatureInput(hello: Data, replyBody: Data) -> Data {
        var data = SPPWSecureEncoding.lengthPrefixed(Data("SPPW/1 server signature".utf8))
        data.append(SPPWSecureEncoding.lengthPrefixed(hello))
        data.append(SPPWSecureEncoding.lengthPrefixed(replyBody))
        return Data(SHA256.hash(data: data))
    }

    static func hash(hello: Data, reply: Data) -> Data {
        var data = SPPWSecureEncoding.lengthPrefixed(Data("SPPW/1 transcript".utf8))
        data.append(SPPWSecureEncoding.lengthPrefixed(hello))
        data.append(SPPWSecureEncoding.lengthPrefixed(reply))
        return Data(SHA256.hash(data: data))
    }

    static func clientSignatureInput(transcript: Data) -> Data {
        var data = SPPWSecureEncoding.lengthPrefixed(Data("SPPW/1 client signature".utf8))
        data.append(SPPWSecureEncoding.lengthPrefixed(transcript))
        return Data(SHA256.hash(data: data))
    }

    static func pairingConfirmations(isk: SymmetricKey, transcript: Data) -> (server: Data, client: Data) {
        func mac(_ label: String) -> Data {
            var message = SPPWSecureEncoding.lengthPrefixed(Data(label.utf8))
            message.append(SPPWSecureEncoding.lengthPrefixed(transcript))
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: isk))
        }
        return (mac("SPPW/1 pairing server"), mac("SPPW/1 pairing client"))
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

public enum SPPWSecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}
