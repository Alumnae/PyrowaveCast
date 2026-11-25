import CryptoKit
import Foundation
import Testing
@testable import SPPWCommon

// MARK: - Field arithmetic and Elligator 2

private func randomField() -> SPPWField25519 {
    SPPWField25519(littleEndian: SPPWSecureRandom.bytes(32))
}

@Test func fieldArithmeticIdentities() {
    for _ in 0..<20 {
        let a = randomField()
        let b = randomField()
        #expect((a + b) - b == a)
        #expect(a - a == .zero)
        #expect(a * .one == a)
        #expect(a * b == b * a)
        if !a.isZero {
            #expect(a * a.inverse() == .one)
        }
        // A square is always a quadratic residue.
        #expect(a.squared().isSquare)
    }
    // p − 1 ≡ −1: (−1)·(−1) = 1, and −1 is not a square modulo 2^255 − 19 (p ≡ 5 mod 8).
    let minusOne = -SPPWField25519.one
    #expect(minusOne * minusOne == .one)
    #expect(!SPPWField25519(2).isSquare)
    // Values at or above p reduce: p itself is zero.
    var pBytes = Data(repeating: 0xFF, count: 32)
    pBytes[0] = 0xED
    pBytes[31] = 0x7F
    #expect(SPPWField25519(littleEndian: pBytes).isZero)
}

@Test func elligatorMapsOntoTheCurve() throws {
    for _ in 0..<20 {
        let u = SPPWElligator2.map(randomField())
        #expect(SPPWElligator2.curveRightHandSide(u).isSquare)
        // CryptoKit accepts it as an X25519 point and multiplies it to a non-zero result.
        let point = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: u.littleEndianBytes)
        let shared = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: point)
        #expect(shared.withUnsafeBytes { Data($0) }.contains { $0 != 0 })
    }
    #expect(SPPWElligator2.curveRightHandSide(SPPWElligator2.map(.zero)).isSquare)
}

// MARK: - CPace

@Test func cpaceAgreesOnlyWithTheSameSecret() throws {
    let sid = SPPWSecureRandom.bytes(32)
    let pin = SPPWCPace.normalizedSecret("04217")
    let client = try SPPWCPace.start(secret: pin, sessionID: sid)
    let server = try SPPWCPace.start(secret: pin, sessionID: sid)
    let k1 = try SPPWCPace.finish(client, peerShare: server.share, sessionID: sid, initiatorShare: client.share, responderShare: server.share)
    let k2 = try SPPWCPace.finish(server, peerShare: client.share, sessionID: sid, initiatorShare: client.share, responderShare: server.share)
    #expect(k1 == k2)

    let wrong = try SPPWCPace.start(secret: SPPWCPace.normalizedSecret("04218"), sessionID: sid)
    let k3 = try SPPWCPace.finish(wrong, peerShare: server.share, sessionID: sid, initiatorShare: wrong.share, responderShare: server.share)
    let k4 = try SPPWCPace.finish(server, peerShare: wrong.share, sessionID: sid, initiatorShare: wrong.share, responderShare: server.share)
    #expect(k3 != k4)

    // Same PIN, other session: other generator, so shares cannot be replayed across sessions.
    #expect(SPPWCPace.generator(secret: pin, sessionID: sid) != SPPWCPace.generator(secret: pin, sessionID: SPPWSecureRandom.bytes(32)))
    // A low-order share is refused.
    #expect(throws: SPPWCPaceError.self) {
        _ = try SPPWCPace.finish(server, peerShare: Data(count: 32), sessionID: sid, initiatorShare: Data(count: 32), responderShare: server.share)
    }
}

@Test func cpaceNormalizesUnicodePasswords() {
    // "é" precomposed and decomposed type the same password.
    #expect(SPPWCPace.normalizedSecret("caf\u{E9}") == SPPWCPace.normalizedSecret("cafe\u{301}"))
}

// MARK: - Replay window and envelope

@Test func replayWindowAcceptsEachCounterOnce() {
    var window = SPPWReplayWindow()
    func accept(_ counter: UInt64) -> Bool { window.accept(counter) }
    #expect(!accept(0))
    #expect(accept(5))
    #expect(accept(3))
    #expect(!accept(5))
    #expect(accept(2_000))
    // Older than the window.
    #expect(!accept(5 + 1))
    #expect(accept(2_000 - 1000))
    #expect(!accept(2_000 - 1024))
}

private func sampleDatagram(kind: UInt8 = 3, payload: Data = Data("frame bytes".utf8)) -> Data {
    var datagram = SPPWSecureEnvelope.makeDatagram(kind: kind, payload: payload)
    datagram[8] = 0x12 // streamID byte, kept in the clear and authenticated
    return datagram
}

@Test func envelopeSealsOpensAndRejectsTampering() throws {
    let key = SymmetricKey(size: .bits256)
    let salt = Data([1, 2, 3, 4])
    let sender = SPPWSecureDirection(key: key, salt: salt)
    let receiver = SPPWSecureDirection(key: key, salt: salt)
    let plain = sampleDatagram()
    let sealed = try #require(sender.seal(plain))
    #expect(sealed.count == plain.count + SPPWSecureEnvelope.overheadBytes)
    #expect(SPPWSecureEnvelope.isSealed(sealed))
    #expect(SPPWSecureEnvelope.kind(of: sealed) == 3)
    #expect(!sealed.contains(Data("frame bytes".utf8)))
    #expect(receiver.open(sealed) == plain)
    // Replay.
    #expect(receiver.open(sealed) == nil)
    // Tampered header, payload, or counter.
    for index in [8, 45, sealed.count - 1] {
        var tampered = try #require(sender.seal(plain))
        tampered[index] ^= 0x01
        #expect(receiver.open(tampered) == nil)
    }
    // Other key.
    let stranger = SPPWSecureDirection(key: SymmetricKey(size: .bits256), salt: salt)
    #expect(receiver.open(try #require(stranger.seal(plain))) == nil)
}

// MARK: - Handshake and pairing (in memory)

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func temporaryStore() -> SPPWSecurityStore {
    SPPWSecurityStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("sppw-security-tests-\(UUID().uuidString)", isDirectory: true))
}

/// A server and a client engine wired back to back, delivering datagrams synchronously.
private final class Link: @unchecked Sendable {
    let server: SPPWServerSecurity
    var client: SPPWClientSecurity!
    let serverEvents = Box<[SPPWServerSecurityEvent]>([])
    let clientEvents = Box<[SPPWClientSecurityEvent]>([])
    let toServerApp = Box<[Data]>([])
    let toClientApp = Box<[Data]>([])
    let lock = NSLock()
    var pending: [(toServer: Bool, data: Data)] = []
    var shown: String?
    let peerKey = "192.168.1.20:50000"
    /// Drops every datagram sent to the server whose index is listed (loss simulation).
    var dropToServer: Set<Int> = []
    private var toServerCount = 0

    init(serverStore: SPPWSecurityStore, clientStore: SPPWSecurityStore, server config: SPPWServerSecurityConfiguration, clientEncryption: Bool = true) {
        let serverEvents = self.serverEvents
        server = SPPWServerSecurity(store: serverStore, configuration: config, serverName: "Studio Mac") { event in
            serverEvents.value.append(event)
        }
        makeClient(store: clientStore, encryption: clientEncryption)
    }

    func makeClient(store: SPPWSecurityStore, encryption: Bool = true) {
        let clientEvents = self.clientEvents
        client = SPPWClientSecurity(store: store, encryptionEnabled: encryption, deviceName: "iPad") { event in
            clientEvents.value.append(event)
        }
    }

    func start() {
        client.start { [weak self] data in self?.enqueue(toServer: true, data) }
        pump()
    }

    func enqueue(toServer: Bool, _ data: Data) {
        lock.lock()
        pending.append((toServer, data))
        lock.unlock()
    }

    /// Delivers queued datagrams until the link is quiet.
    func pump() {
        client.waitUntilIdle()
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                lock.unlock()
                return
            }
            let next = pending.removeFirst()
            lock.unlock()
            if next.toServer {
                toServerCount += 1
                if dropToServer.contains(toServerCount) { continue }
                if let plain = server.incoming(next.data, from: peerKey, reply: { enqueue(toServer: false, $0) }) {
                    toServerApp.value.append(plain)
                }
            } else if let plain = client.incoming(next.data) {
                toClientApp.value.append(plain)
            }
        }
    }

    /// App-level send from the client (sealed once ready, queued before).
    func clientSend(_ datagram: Data) {
        if let out = client.outgoing(datagram) { enqueue(toServer: true, out) }
        pump()
    }

    func serverSend(_ datagram: Data) {
        if let out = server.outgoing(datagram, to: peerKey) { enqueue(toServer: false, out) }
        pump()
    }

    var lastPIN: String? {
        for event in serverEvents.value.reversed() {
            if case let .pinRequested(prompt) = event { return prompt.pin }
        }
        return nil
    }

    var lastClientEvent: SPPWClientSecurityEvent? { clientEvents.value.last }
}

private let clientHello = SPPWSecureEnvelope.makeDatagram(kind: 1, payload: Data(repeating: 7, count: 22))

@Test func pinPairingThenReconnectWithoutPIN() throws {
    let serverStore = temporaryStore()
    let clientStore = temporaryStore()
    let link = Link(serverStore: serverStore, clientStore: clientStore, server: .init(encryptionEnabled: true, pairingMode: .pin))
    link.start()
    // The app's hello waits until the session is ready.
    link.clientSend(clientHello)
    #expect(link.toServerApp.value.isEmpty)
    guard case let .needsSecret(request) = link.lastClientEvent else {
        Issue.record("expected a PIN prompt, got \(String(describing: link.lastClientEvent))"); return
    }
    #expect(request.method == .pin)
    #expect(request.serverName == "Studio Mac")
    #expect(request.serverFingerprint == serverStore.identity.fingerprint)
    let pin = try #require(link.lastPIN)
    #expect(pin.count == 5 && pin.allSatisfy(\.isNumber))

    link.client.provideSecret(pin)
    link.pump()
    guard case let .paired(info) = link.lastClientEvent else {
        Issue.record("expected paired, got \(String(describing: link.lastClientEvent))"); return
    }
    #expect(info.trust == .paired)
    // The queued hello went through, decrypted, unchanged.
    #expect(link.toServerApp.value == [clientHello])
    #expect(serverStore.isTrusted(.clients, fingerprint: clientStore.identity.fingerprint))
    #expect(clientStore.isTrusted(.servers, fingerprint: serverStore.identity.fingerprint))

    // Both directions now encrypted end to end.
    let frame = sampleDatagram()
    link.serverSend(frame)
    #expect(link.toClientApp.value == [frame])

    // A new connection (new engine, same stores): no PIN this time.
    let second = Link(serverStore: serverStore, clientStore: clientStore, server: .init(encryptionEnabled: true, pairingMode: .pin))
    second.start()
    second.clientSend(clientHello)
    #expect(second.toServerApp.value == [clientHello])
    guard case let .secured(again) = second.lastClientEvent else {
        Issue.record("expected secured, got \(String(describing: second.lastClientEvent))"); return
    }
    #expect(again.trust == .paired)
    #expect(second.lastPIN == nil)
}

@Test func wrongPINIsRefusedAndLimited() throws {
    let link = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: true, pairingMode: .pin))
    link.start()
    let pin = try #require(link.lastPIN)
    let wrong = pin == "00000" ? "11111" : "00000"
    link.client.provideSecret(wrong)
    link.pump()
    guard case let .needsSecret(retry) = link.lastClientEvent else {
        Issue.record("expected another prompt"); return
    }
    #expect(retry.previousAttemptFailed)
    #expect(retry.attemptsLeft == 2)
    #expect(link.toServerApp.value.isEmpty)
    // Two more wrong guesses use up the PIN: the server shows a new one.
    link.client.provideSecret(wrong)
    link.pump()
    link.client.provideSecret(wrong)
    link.pump()
    let renewed = try #require(link.lastPIN)
    guard case let .needsSecret(fresh) = link.lastClientEvent else {
        Issue.record("expected a prompt for the new PIN"); return
    }
    #expect(fresh.previousAttemptFailed)
    #expect(fresh.attemptsLeft == SPPWServerSecurity.pinAttempts)
    link.client.provideSecret(renewed)
    link.pump()
    guard case .paired = link.lastClientEvent else {
        Issue.record("expected paired with the new PIN"); return
    }
}

@Test func passwordPairingForHeadlessServers() throws {
    let serverStore = temporaryStore()
    serverStore.setServerPassword("correct horse")
    let link = Link(serverStore: serverStore, clientStore: temporaryStore(), server: .init(encryptionEnabled: true, pairingMode: .password))
    link.start()
    guard case let .needsSecret(request) = link.lastClientEvent else {
        Issue.record("expected a password prompt"); return
    }
    #expect(request.method == .password)
    #expect(link.lastPIN == nil)
    link.client.provideSecret("wrong horse")
    link.pump()
    guard case let .needsSecret(retry) = link.lastClientEvent else {
        Issue.record("expected a second prompt"); return
    }
    #expect(retry.attemptsLeft == SPPWServerSecurity.passwordAttemptsPerHost - 1)
    link.client.provideSecret("correct horse")
    link.pump()
    guard case .paired = link.lastClientEvent else {
        Issue.record("expected paired"); return
    }
}

@Test func passwordModeWithoutPasswordIsUnavailable() {
    let link = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: true, pairingMode: .password))
    link.start()
    link.client.provideSecret("anything")
    link.pump()
    #expect(link.lastClientEvent == .failed(.pairingUnavailable))
}

@Test func openModeEncryptsWithoutPairing() {
    let link = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: true, pairingMode: .open))
    link.start()
    link.clientSend(clientHello)
    #expect(link.toServerApp.value == [clientHello])
    guard case let .secured(info) = link.lastClientEvent else {
        Issue.record("expected secured"); return
    }
    #expect(info.trust == .unverified)
}

@Test func encryptionTogglesMustMatch() {
    // Client on, server off: refused with a clear reason, never downgraded.
    let a = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: false, pairingMode: .pin))
    a.start()
    #expect(a.lastClientEvent == .failed(.serverEncryptionDisabled))
    a.clientSend(clientHello)
    #expect(a.toServerApp.value.isEmpty)

    // Client off, server on.
    let b = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: true, pairingMode: .pin), clientEncryption: false)
    b.start()
    b.clientSend(clientHello)
    #expect(b.toServerApp.value.isEmpty)
    #expect(b.lastClientEvent == .failed(.serverRequiresEncryption))

    // Both off: plain SPPW/1 as before.
    let c = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: false, pairingMode: .pin), clientEncryption: false)
    c.start()
    c.clientSend(clientHello)
    #expect(c.toServerApp.value == [clientHello])
    c.serverSend(sampleDatagram())
    #expect(c.toClientApp.value == [sampleDatagram()])
}

@Test func serverRestartTriggersANewHandshake() throws {
    let serverStore = temporaryStore()
    let clientStore = temporaryStore()
    let link = Link(serverStore: serverStore, clientStore: clientStore, server: .init(encryptionEnabled: true, pairingMode: .open))
    link.start()
    link.clientSend(clientHello)
    #expect(link.toServerApp.value.count == 1)
    // New settings drop all sessions (like a restart): the next datagram gets "unknown session",
    // the client runs the handshake again and its traffic flows again.
    link.server.update(.init(encryptionEnabled: true, pairingMode: .open))
    link.server.update(.init(encryptionEnabled: true, pairingMode: .pin))
    link.server.update(.init(encryptionEnabled: true, pairingMode: .open))
    link.clientSend(clientHello)
    link.clientSend(clientHello)
    #expect(link.toServerApp.value.count == 2)
}

@Test func lostHandshakeDatagramsAreRetransmitted() throws {
    let link = Link(serverStore: temporaryStore(), clientStore: temporaryStore(), server: .init(encryptionEnabled: true, pairingMode: .open))
    link.dropToServer = [1, 2] // the first hello and its first retransmission
    link.start()
    #expect(link.client.isReady == false)
    // The client's 0.5 s timer resends; wait for it.
    let deadline = Date().addingTimeInterval(3)
    while !link.client.isReady && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        link.pump()
    }
    #expect(link.client.isReady)
}

@Test func forgedServerReplyIsRejected() throws {
    let clientStore = temporaryStore()
    let events = Box<[SPPWClientSecurityEvent]>([])
    let sent = Box<[Data]>([])
    let client = SPPWClientSecurity(store: clientStore, encryptionEnabled: true, deviceName: "Mac") { events.value.append($0) }
    client.start { sent.value.append($0) }
    // A real server answers, then the reply is altered in flight (e.g. someone swaps the name).
    let server = SPPWServerSecurity(store: temporaryStore(), configuration: .init(encryptionEnabled: true, pairingMode: .open), serverName: "Real")
    var reply = Data()
    _ = server.incoming(try #require(sent.value.first), from: "10.0.0.2:1") { reply = $0 }
    reply[reply.count - 70] ^= 0x01
    _ = client.incoming(reply)
    #expect(events.value.last == .failed(.badServerSignature))
    client.stop()
}

@Test func storeKeepsIdentityAndPeersAcrossInstances() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sppw-store-\(UUID().uuidString)", isDirectory: true)
    let first = SPPWSecurityStore(directory: directory)
    let fingerprint = first.identity.fingerprint
    first.trust(.clients, publicKey: Data(repeating: 9, count: 32), name: "iPhone")
    first.setServerPassword("secret")
    let second = SPPWSecurityStore(directory: directory)
    #expect(second.identity.fingerprint == fingerprint)
    #expect(second.trustedPeers(.clients).map(\.name) == ["iPhone"])
    #expect(second.serverPasswordVerifier?.derived == SPPWPasswordVerifier.derive(password: "secret", salt: second.serverPasswordVerifier?.salt ?? Data(), iterations: second.serverPasswordVerifier?.iterations ?? 0))
    // Only the salted PBKDF2 value is on disk, never the password.
    let stored = (try? Data(contentsOf: directory.appendingPathComponent("server-password.json"))) ?? Data()
    #expect(!stored.isEmpty && stored.range(of: Data("secret".utf8)) == nil)
    let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("identity.key").path)
    #expect((attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    second.forget(.clients, fingerprintHex: SPPWFingerprint(publicKey: Data(repeating: 9, count: 32)).hex)
    #expect(SPPWSecurityStore(directory: directory).trustedPeers(.clients).isEmpty)
    try? FileManager.default.removeItem(at: directory)
}

@Test func fingerprintFormatting() throws {
    let fingerprint = SPPWFingerprint(publicKey: Data(repeating: 1, count: 32))
    #expect(fingerprint.display.split(separator: " ").count == 8)
    #expect(fingerprint.short.count == 9)
    #expect(SPPWFingerprint(hex: fingerprint.hex) == fingerprint)
    #expect(SPPWServerSecurity.randomPIN().count == 5)
    #expect(SPPWServerSecurity.host(of: "192.168.1.2:5000") == "192.168.1.2")
    #expect(SPPWServerSecurity.host(of: "[fe80::1]:5000") == "fe80::1")
}
