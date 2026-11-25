import CryptoKit
import Foundation
import Testing
@testable import SPPWCommon

@Test func fileOfferRoundTripAndPathSafety() throws {
    let offer = SPPWFileTransferOffer(
        token: Data(repeating: 1, count: 16),
        key: Data(repeating: 2, count: 32),
        port: 50123,
        entries: [
            .init(path: "Progetto", isDirectory: true, size: 0),
            .init(path: "Progetto/a.mov", isDirectory: false, size: 5_000_000_000),
            .init(path: "note.txt", isDirectory: false, size: 12)
        ]
    )
    let encoded = try #require(offer.encoded())
    #expect(SPPWFileTransferOffer(decoding: encoded) == offer)
    #expect(offer.totalBytes == 5_000_000_012)
    #expect(offer.topLevelNames == ["Progetto", "note.txt"])
    #expect(SPPWFileTransferOffer(decoding: encoded.dropLast()) == nil)
    for unsafe in ["../x", "a/../b", "/etc/passwd", "a//b", ".", "a/.hidden/../x"] {
        #expect(SPPWFileTransferOffer.safeComponents(unsafe) == nil, "\(unsafe)")
    }
    #expect(SPPWFileTransferOffer.safeComponents("Progetto/sub/file.txt") == ["Progetto", "sub", "file.txt"])
}

@Test func transferPacerHoldsTheRate() {
    var pacer = SPPWTransferPacer(bytesPerSecond: 10_000_000, now: 0)
    // The initial allowance (0.1 s) goes out at once, then each 1 MB waits 0.1 s.
    #expect(pacer.delay(forSending: 1_000_000, now: 0) == 0)
    let wait = pacer.delay(forSending: 1_000_000, now: 0)
    #expect(abs(wait - 0.1) < 0.001)
}

private func makeTree(_ root: URL) throws -> [URL] {
    let fm = FileManager.default
    let folder = root.appendingPathComponent("Progetto", isDirectory: true)
    try fm.createDirectory(at: folder.appendingPathComponent("sub/empty", isDirectory: true), withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: folder.appendingPathComponent("sub/a.txt"))
    try Data().write(to: folder.appendingPathComponent("zero.bin"))
    var big = Data(count: 64 << 20)
    big.withUnsafeMutableBytes { buffer in
        for index in stride(from: 0, to: buffer.count, by: 4096) { buffer[index] = UInt8(truncatingIfNeeded: index / 4096) }
    }
    let bigURL = root.appendingPathComponent("video.mov")
    try big.write(to: bigURL)
    return [folder, bigURL]
}

private func digest(_ url: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: url)))
}

@Test func backgroundTransferMovesAFolderTreeAndALargeFileOverTCP() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sppw-transfer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let urls = try makeTree(source)

    let registry = SPPWFileTransfers()
    let offer = try #require(registry.offer(urls))
    #expect(offer.entries.contains { $0.path == "Progetto/sub/empty" && $0.isDirectory })
    #expect(offer.totalBytes == UInt64(64 << 20) + 5)
    // The offer travels through the clipboard channel as bytes.
    let encodedOffer = try #require(offer.encoded())
    let received = try #require(SPPWFileTransferOffer(decoding: encodedOffer))

    let started = Date()
    let result: [URL]? = await withCheckedContinuation { continuation in
        registry.download(received, from: "127.0.0.1", into: base.appendingPathComponent("dest", isDirectory: true)) {
            continuation.resume(returning: $0)
        }
    }
    let seconds = Date().timeIntervalSince(started)
    let items = try #require(result)
    #expect(items.map(\.lastPathComponent) == ["Progetto", "video.mov"])
    #expect(try digest(items[1]) == digest(urls[1]))
    #expect(try Data(contentsOf: items[0].appendingPathComponent("sub/a.txt")) == Data("hello".utf8))
    #expect(FileManager.default.fileExists(atPath: items[0].appendingPathComponent("sub/empty").path))
    #expect((try? Data(contentsOf: items[0].appendingPathComponent("zero.bin")))?.isEmpty == true)
    // Paced: 64 MiB at the 25 MiB/s cap takes about 2.5 s.
    #expect(seconds > 2 && seconds < 20, "took \(seconds) s")
    try await Task.sleep(for: .milliseconds(300))
    let statuses = registry.all
    #expect(statuses.contains { $0.direction == .download && $0.state == .finished })
    #expect(statuses.contains { $0.direction == .upload && $0.state == .finished })
}

@Test func lazyDownloadOfOneTopLevelItem() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sppw-transfer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let urls = try makeTree(source)
    let registry = SPPWFileTransfers()
    let offer = try #require(registry.offer(urls))
    let item: URL? = await withCheckedContinuation { continuation in
        registry.download(offer, topLevelItem: "Progetto", from: "127.0.0.1", into: base.appendingPathComponent("dest")) {
            continuation.resume(returning: $0)
        }
    }
    let folder = try #require(item)
    #expect(try Data(contentsOf: folder.appendingPathComponent("sub/a.txt")) == Data("hello".utf8))
    // Only that item was fetched: the large file is not next to it.
    #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("video.mov").path))
    // The offer stays open for the other items.
    #expect(registry.all.contains { $0.direction == .upload && $0.isActive })
}

@Test func wrongKeyIsRefused() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sppw-transfer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let file = base.appendingPathComponent("secret.txt")
    try Data(repeating: 7, count: 10 << 20).write(to: file)
    let registry = SPPWFileTransfers()
    let offer = try #require(registry.offer([file]))
    let forged = SPPWFileTransferOffer(token: offer.token, key: SPPWSecureRandom.bytes(32), port: offer.port, entries: offer.entries)
    let result: [URL]? = await withCheckedContinuation { continuation in
        registry.download(forged, from: "127.0.0.1", into: base.appendingPathComponent("dest")) {
            continuation.resume(returning: $0)
        }
    }
    #expect(result == nil)
}
