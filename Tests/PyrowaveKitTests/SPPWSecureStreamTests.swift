import Foundation
import Testing
import PyrowaveServerKit
@testable import SPPWCommon

/// End to end over real UDP sockets: a `StreamServer` streaming its test card with encryption
/// and PIN pairing on, and a receiver socket with the client security layer.
@Test func encryptedStreamWithPINPairingOverUDP() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sppw-e2e-\(UUID().uuidString)", isDirectory: true)
    let serverStore = SPPWSecurityStore(directory: base.appendingPathComponent("server"))
    let clientStore = SPPWSecurityStore(directory: base.appendingPathComponent("client"))
    defer { try? FileManager.default.removeItem(at: base) }

    let pins = LockedBox<[String]>([])
    let serverSecurity = SPPWServerSecurity(
        store: serverStore,
        configuration: .init(encryptionEnabled: true, pairingMode: .pin),
        serverName: "Test server"
    ) { event in
        if case let .pinRequested(prompt) = event { pins.mutate { $0.append(prompt.pin) } }
    }
    let server = StreamServer(testContentMode: .card, security: serverSecurity)
    let port = UInt16.random(in: 40_000...49_000)
    try await server.start(port: port)

    let kinds = LockedBox<[UInt8]>([])
    let events = LockedBox<[SPPWClientSecurityEvent]>([])
    let clientSecurity = SPPWClientSecurity(store: clientStore, encryptionEnabled: true, deviceName: "Test receiver") { event in
        events.mutate { $0.append(event) }
    }
    let socket = try SPPWUDPClientSocket(host: "127.0.0.1", port: port)
    socket.start(datagramHandler: { data in
        if let kind = SPPWSecureEnvelope.kind(of: data) { kinds.mutate { $0.append(kind) } }
    })
    socket.attachSecurity(clientSecurity)

    var config = Data()
    for value: UInt16 in [0, 0, 30] { config.append(UInt8(value >> 8)); config.append(UInt8(value & 0xFF)) }
    config.append(contentsOf: [1, 1])
    for byte in withUnsafeBytes(of: UInt32(20_000_000).bigEndian, Array.init) { config.append(byte) }
    for value: UInt16 in [5_000, 10, 1_200, 12] { config.append(UInt8(value >> 8)); config.append(UInt8(value & 0xFF)) }
    config.append(contentsOf: [0, 0])
    let hello = SPPWSecureEnvelope.makeDatagram(kind: 1, payload: config)

    var answeredPIN = false
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if !answeredPIN, clientSecurity.isAwaitingUser, let pin = pins.value.last {
            clientSecurity.provideSecret(pin)
            answeredPIN = true
        }
        if !kinds.value.contains(2) { socket.send(hello) }
        if kinds.value.contains(3) { break }
        try await Task.sleep(for: .milliseconds(200))
    }
    socket.stop()
    await server.stop()

    #expect(pins.value.count == 1)
    #expect(events.value.contains { if case .paired = $0 { return true } else { return false } })
    #expect(kinds.value.contains(2), "server hello received through the encrypted session")
    #expect(kinds.value.contains(3), "video fragments received and decrypted")
    #expect(serverStore.isTrusted(.clients, fingerprint: clientStore.identity.fingerprint))
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
