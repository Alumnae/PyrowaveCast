import CryptoKit
import Foundation
import Network

// MARK: - Background file transfer for large clipboard items (PROTOCOL.md §8)
//
// Files over the inline limit, and folders, do not travel on the clipboard channel. The clipboard
// carries a small *offer* (`SPPWClipboardFormat.fileOffer`): entry names and sizes, a TCP port, a
// token and a fresh AES-256 key. The side that copied starts a TCP listener for that offer only;
// the other side connects to it (at the address it already uses for SPPW/1), downloads the entries
// in 256 KB pieces straight to disk, and the listener closes when it is done or expires.
//
// - Encrypted records (AES-256-GCM, key from the offer), so the data is as private as the offer:
//   with SPPW/1 encryption on, the offer itself travels sealed.
// - Background network service class (Wi-Fi background access category) and a 25 MB/s cap, so the
//   transfer yields to the video.
// - Resume: after a dropped connection the downloader reconnects and asks from the byte it has.

public enum SPPWFileTransferLimits {
    /// Files up to this total (and no folders) keep travelling inline on the clipboard channel.
    public static let inlineByteLimit = 4 << 20
    public static let maximumEntries = 20_000
    /// Data record payload.
    public static let chunkBytes = 256 << 10
    /// Sender pacing ceiling.
    public static let maximumBytesPerSecond = 25 << 20
    /// The listener of an offer closes after this long without a download.
    public static let offerLifetime: TimeInterval = 30 * 60
    public static let maximumResumeAttempts = 8
}

// MARK: Offer

/// The clipboard placeholder for files sent in the background.
public struct SPPWFileTransferOffer: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Path relative to the copied items, `/`-separated; top-level items have one component.
        public let path: String
        public let isDirectory: Bool
        public let size: UInt64

        public init(path: String, isDirectory: Bool, size: UInt64) {
            self.path = path
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    public let token: Data
    public let key: Data
    public let port: UInt16
    public let entries: [Entry]

    public var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.size } }

    /// Top-level names, for labels and the text placeholder.
    public var topLevelNames: [String] {
        entries.compactMap { $0.path.contains("/") ? nil : $0.path }
    }

    public init(token: Data, key: Data, port: UInt16, entries: [Entry]) {
        self.token = token
        self.key = key
        self.port = port
        self.entries = entries
    }

    /// Splits a relative path into safe components, or `nil` if any is empty, `.`/`..`, or unsafe.
    public static func safeComponents(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        var result: [String] = []
        for part in parts {
            guard part != ".", part != "..", let clean = SPPWClipboardFiles.sanitizedName(part), clean == part else { return nil }
            result.append(clean)
        }
        return result
    }

    /// `16 token ‖ 32 key ‖ UInt16 port ‖ UInt32 count`, then per entry
    /// `UInt8 isDirectory ‖ UInt16 pathBytes ‖ path ‖ UInt64 size`.
    public func encoded() -> Data? {
        guard token.count == 16, key.count == 32, !entries.isEmpty, entries.count <= SPPWFileTransferLimits.maximumEntries else { return nil }
        var data = token + key
        SPPWSecureEncoding.appendU16(port, to: &data)
        SPPWSecureEncoding.appendU32(UInt32(entries.count), to: &data)
        for entry in entries {
            let path = Data(entry.path.utf8)
            guard path.count <= Int(UInt16.max) else { return nil }
            data.append(entry.isDirectory ? 1 : 0)
            SPPWSecureEncoding.appendU16(UInt16(path.count), to: &data)
            data.append(path)
            SPPWSecureEncoding.appendU64(entry.size, to: &data)
        }
        return data.count <= SPPWClipboardFormat.fileOffer.maximumByteCount ? data : nil
    }

    public init?(decoding payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 54 else { return nil }
        token = Data(bytes[0..<16])
        key = Data(bytes[16..<48])
        port = UInt16(bytes[48]) << 8 | UInt16(bytes[49])
        let count = Int(UInt32(bytes[50]) << 24 | UInt32(bytes[51]) << 16 | UInt32(bytes[52]) << 8 | UInt32(bytes[53]))
        guard port > 0, (1...SPPWFileTransferLimits.maximumEntries).contains(count) else { return nil }
        var offset = 54
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 3 <= bytes.count else { return nil }
            let isDirectory = bytes[offset] != 0
            let length = Int(UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset + 2]))
            offset += 3
            guard offset + length + 8 <= bytes.count else { return nil }
            let path = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            offset += length
            let size = SPPWSecureEncoding.u64(bytes, at: offset)
            offset += 8
            guard Self.safeComponents(path) != nil else { return nil }
            entries.append(Entry(path: path, isDirectory: isDirectory, size: isDirectory ? 0 : size))
        }
        guard offset == bytes.count else { return nil }
        self.entries = entries
    }
}

// MARK: Record framing and encryption

/// `UInt32 length ‖ AES-GCM(ciphertext ‖ tag)` records, nonce `direction(4) ‖ counter(8)`.
final class SPPWTransferCipher: @unchecked Sendable {
    static let downloaderToSender: UInt32 = 0x4450_5755 // "DPWU"
    static let senderToDownloader: UInt32 = 0x5550_5744

    private let key: SymmetricKey
    private let sendDirection: UInt32
    private let receiveDirection: UInt32
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var buffer = Data()
    private let lock = NSLock()

    init(key: Data, isSender: Bool) {
        self.key = SymmetricKey(data: key)
        sendDirection = isSender ? Self.senderToDownloader : Self.downloaderToSender
        receiveDirection = isSender ? Self.downloaderToSender : Self.senderToDownloader
    }

    private func nonce(_ direction: UInt32, _ counter: UInt64) -> AES.GCM.Nonce? {
        var bytes = Data()
        SPPWSecureEncoding.appendU32(direction, to: &bytes)
        SPPWSecureEncoding.appendU64(counter, to: &bytes)
        return try? AES.GCM.Nonce(data: bytes)
    }

    func seal(_ plaintext: Data) -> Data? {
        lock.lock()
        sendCounter += 1
        let counter = sendCounter
        lock.unlock()
        guard let nonce = nonce(sendDirection, counter),
              let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce) else { return nil }
        var record = Data()
        SPPWSecureEncoding.appendU32(UInt32(box.ciphertext.count + 16), to: &record)
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }

    /// Adds received bytes; returns the complete records, or `nil` on a forged/damaged one.
    func feed(_ data: Data) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var records: [Data] = []
        while buffer.count >= 4 {
            let base = buffer.startIndex
            let length = Int(UInt32(buffer[base]) << 24 | UInt32(buffer[base + 1]) << 16 | UInt32(buffer[base + 2]) << 8 | UInt32(buffer[base + 3]))
            guard length >= 16, length <= SPPWFileTransferLimits.chunkBytes + 1024 else { return nil }
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer[(base + 4)..<(base + 4 + length)])
            buffer.removeFirst(4 + length)
            receiveCounter += 1
            guard let nonce = nonce(receiveDirection, receiveCounter),
                  let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16)),
                  let plaintext = try? AES.GCM.open(box, using: key) else { return nil }
            records.append(plaintext)
        }
        return records
    }
}

enum SPPWTransferRecord {
    case hello(token: Data)
    case get(index: UInt32, offset: UInt64)
    case data(index: UInt32, offset: UInt64, bytes: Data)
    case endOfEntry(index: UInt32)
    case failure(code: UInt8)
    case done

    func encoded() -> Data {
        var data = Data()
        switch self {
        case let .hello(token):
            data.append(0)
            data.append(token)
        case let .get(index, offset):
            data.append(1)
            SPPWSecureEncoding.appendU32(index, to: &data)
            SPPWSecureEncoding.appendU64(offset, to: &data)
        case let .data(index, offset, bytes):
            data.append(2)
            SPPWSecureEncoding.appendU32(index, to: &data)
            SPPWSecureEncoding.appendU64(offset, to: &data)
            data.append(bytes)
        case let .endOfEntry(index):
            data.append(3)
            SPPWSecureEncoding.appendU32(index, to: &data)
        case let .failure(code):
            data.append(contentsOf: [4, code])
        case .done:
            data.append(5)
        }
        return data
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let type = bytes.first else { return nil }
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]) }
        switch type {
        case 0 where bytes.count == 17: self = .hello(token: Data(bytes[1...]))
        case 1 where bytes.count == 13: self = .get(index: u32(1), offset: SPPWSecureEncoding.u64(bytes, at: 5))
        case 2 where bytes.count >= 13: self = .data(index: u32(1), offset: SPPWSecureEncoding.u64(bytes, at: 5), bytes: Data(bytes[13...]))
        case 3 where bytes.count == 5: self = .endOfEntry(index: u32(1))
        case 4 where bytes.count == 2: self = .failure(code: bytes[1])
        case 5 where bytes.count == 1: self = .done
        default: return nil
        }
    }
}

// MARK: Progress registry

public struct SPPWFileTransferStatus: Sendable, Equatable, Identifiable {
    public enum Direction: Sendable, Equatable { case upload, download }
    public enum State: Sendable, Equatable {
        case waiting
        case running
        case finished
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let direction: Direction
    public let title: String
    public var totalBytes: UInt64
    public var doneBytes: UInt64
    public var state: State

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : (state == .finished ? 1 : 0)
    }

    public var isActive: Bool { state == .waiting || state == .running }
}

/// All background transfers of this process, for progress UI and cancellation. Thread-safe.
public final class SPPWFileTransfers: @unchecked Sendable {
    public static let shared = SPPWFileTransfers()

    private let lock = NSLock()
    private var statuses: [UUID: SPPWFileTransferStatus] = [:]
    private var order: [UUID] = []
    private var cancelHandlers: [UUID: @Sendable () -> Void] = [:]
    private var observers: [UUID: @Sendable ([SPPWFileTransferStatus]) -> Void] = [:]
    private var senders: [SPPWFileTransferSender] = []
    /// Running downloads, held until they finish (their callbacks only hold them weakly).
    private var downloaders: [UUID: SPPWFileTransferDownloader] = [:]

    init() {}

    /// Latest transfers first (finished ones stay listed until cleared or replaced).
    public var all: [SPPWFileTransferStatus] {
        lock.lock()
        defer { lock.unlock() }
        return order.reversed().compactMap { statuses[$0] }
    }

    /// Calls `observer` (on any queue) whenever a transfer changes. Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ observer: @escaping @Sendable ([SPPWFileTransferStatus]) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        observer(all)
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        let handler = cancelHandlers[id]
        lock.unlock()
        handler?()
    }

    /// Removes finished, failed and cancelled transfers from the list.
    public func clearFinished() {
        lock.lock()
        order = order.filter { statuses[$0]?.isActive == true }
        statuses = statuses.filter { $0.value.isActive }
        lock.unlock()
        notify()
    }

    func register(_ status: SPPWFileTransferStatus, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        statuses[status.id] = status
        order.append(status.id)
        cancelHandlers[status.id] = cancel
        // Keep the list short: drop the oldest finished entries.
        while order.count > 20, let index = order.firstIndex(where: { statuses[$0]?.isActive != true }) {
            let id = order.remove(at: index)
            statuses.removeValue(forKey: id)
            cancelHandlers.removeValue(forKey: id)
        }
        lock.unlock()
        notify()
    }

    func update(_ id: UUID, _ change: (inout SPPWFileTransferStatus) -> Void) {
        lock.lock()
        guard var status = statuses[id] else {
            lock.unlock()
            return
        }
        change(&status)
        statuses[id] = status
        if !status.isActive { cancelHandlers.removeValue(forKey: id) }
        lock.unlock()
        notify()
    }

    private var lastNotify: UInt64 = 0

    /// Progress updates are throttled to ~10 per second; state changes always go out.
    func updateProgress(_ id: UUID, doneBytes: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        statuses[id]?.doneBytes = doneBytes
        let due = now &- lastNotify > 100_000_000
        if due { lastNotify = now }
        lock.unlock()
        if due { notify() }
    }

    private func notify() {
        lock.lock()
        let list = order.reversed().compactMap { statuses[$0] }
        let targets = Array(observers.values)
        lock.unlock()
        targets.forEach { $0(list) }
    }

    func keep(_ sender: SPPWFileTransferSender) {
        lock.lock()
        senders.append(sender)
        // At most a few offers stay open: older ones close.
        var closing: [SPPWFileTransferSender] = []
        while senders.count > 3 { closing.append(senders.removeFirst()) }
        lock.unlock()
        closing.forEach { $0.close(reason: .cancelled) }
    }

    func keep(_ downloader: SPPWFileTransferDownloader) {
        lock.lock()
        downloaders[downloader.id] = downloader
        lock.unlock()
    }

    func release(_ downloader: SPPWFileTransferDownloader) {
        lock.lock()
        downloaders.removeValue(forKey: downloader.id)
        lock.unlock()
    }

    func release(_ sender: SPPWFileTransferSender) {
        lock.lock()
        senders.removeAll { $0 === sender }
        lock.unlock()
    }

    // MARK: Entry points

    /// Builds an offer for `urls` (files and folders) and opens its listener. `nil` when there is
    /// nothing readable or too many entries.
    public func offer(_ urls: [URL]) -> SPPWFileTransferOffer? {
        guard let sender = SPPWFileTransferSender(urls: urls, registry: self) else { return nil }
        keep(sender)
        return sender.offer
    }

    /// Downloads an offer from `host` into a fresh folder under `directory`; `completion` gets the
    /// top-level items (on any queue) or `nil` if it failed or was cancelled.
    @discardableResult
    public func download(
        _ offer: SPPWFileTransferOffer,
        from host: String,
        into directory: URL,
        completion: @escaping @Sendable ([URL]?) -> Void
    ) -> UUID {
        let downloader = SPPWFileTransferDownloader(offer: offer, host: host, directory: directory, registry: self, completion: completion)
        keep(downloader)
        downloader.start()
        return downloader.id
    }

    /// Downloads one entry (and, for a folder, everything under it) to `directory`, for lazy
    /// pastes (`NSItemProvider` on iOS).
    @discardableResult
    public func download(
        _ offer: SPPWFileTransferOffer,
        topLevelItem name: String,
        from host: String,
        into directory: URL,
        completion: @escaping @Sendable (URL?) -> Void
    ) -> UUID {
        let downloader = SPPWFileTransferDownloader(
            offer: offer,
            host: host,
            directory: directory,
            registry: self,
            onlyTopLevel: name
        ) { urls in
            completion(urls?.first)
        }
        keep(downloader)
        downloader.start()
        return downloader.id
    }
}

private func transferParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    // Wi-Fi background access category: the video keeps priority on the air.
    parameters.serviceClass = .background
    parameters.includePeerToPeer = true
    return parameters
}

private func formatTitle(_ names: [String], count: Int) -> String {
    guard let first = names.first else { return "\(count)" }
    return names.count > 1 ? "\(first) +\(names.count - 1)" : first
}

// MARK: Sender

final class SPPWFileTransferSender: @unchecked Sendable {
    enum CloseReason { case finished, cancelled, expired }

    private struct Item {
        let entry: SPPWFileTransferOffer.Entry
        let url: URL?
    }

    let id = UUID()
    private(set) var offer: SPPWFileTransferOffer!
    private let items: [Item]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sppw.transfer.sender", qos: .utility)
    private let token = SPPWSecureRandom.bytes(16)
    private let key = SPPWSecureRandom.bytes(32)
    private weak var registry: SPPWFileTransfers?
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var served: UInt64 = 0
    private var closed = false

    init?(urls: [URL], registry: SPPWFileTransfers) {
        var items: [Item] = []
        let fileManager = FileManager.default
        var usedTopLevel: Set<String> = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true,
                  var name = SPPWClipboardFiles.sanitizedName(url.lastPathComponent) else { continue }
            var suffix = 2
            let base = name
            while usedTopLevel.contains(name.lowercased()) { name = "\(base) \(suffix)"; suffix += 1 }
            usedTopLevel.insert(name.lowercased())
            if values.isDirectory == true {
                items.append(Item(entry: .init(path: name, isDirectory: true, size: 0), url: nil))
                guard let walker = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: []
                ) else { continue }
                // Compare resolved paths (/var vs /private/var) to get each child's relative path.
                let rootComponents = url.resolvingSymlinksInPath().pathComponents
                for case let child as URL in walker {
                    guard let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                          childValues.isSymbolicLink != true else { continue }
                    let childComponents = child.resolvingSymlinksInPath().pathComponents
                    guard childComponents.count > rootComponents.count,
                          Array(childComponents.prefix(rootComponents.count)) == rootComponents else { continue }
                    let relative = Array(childComponents.dropFirst(rootComponents.count))
                    guard !relative.isEmpty,
                          relative.allSatisfy({ SPPWClipboardFiles.sanitizedName($0) == $0 && $0 != "." && $0 != ".." }) else {
                        if childValues.isDirectory == true { walker.skipDescendants() }
                        continue
                    }
                    let path = ([name] + relative).joined(separator: "/")
                    if childValues.isDirectory == true {
                        items.append(Item(entry: .init(path: path, isDirectory: true, size: 0), url: nil))
                    } else if childValues.isRegularFile == true {
                        items.append(Item(entry: .init(path: path, isDirectory: false, size: UInt64(childValues.fileSize ?? 0)), url: child))
                    }
                    if items.count > SPPWFileTransferLimits.maximumEntries { return nil }
                }
            } else if values.isRegularFile == true {
                items.append(Item(entry: .init(path: name, isDirectory: false, size: UInt64(values.fileSize ?? 0)), url: url))
            }
        }
        guard !items.isEmpty, items.count <= SPPWFileTransferLimits.maximumEntries,
              let listener = try? NWListener(using: transferParameters(), on: .any) else { return nil }
        self.items = items
        self.listener = listener
        self.registry = registry
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let port = listener.port?.rawValue, port > 0 else {
            listener.cancel()
            return nil
        }
        listener.stateUpdateHandler = nil
        offer = SPPWFileTransferOffer(token: token, key: key, port: port, entries: items.map(\.entry))
        guard offer.encoded() != nil else {
            listener.cancel()
            return nil
        }
        let names = offer.topLevelNames
        registry.register(
            SPPWFileTransferStatus(id: id, direction: .upload, title: formatTitle(names, count: items.count), totalBytes: offer.totalBytes, doneBytes: 0, state: .waiting)
        ) { [weak self] in self?.close(reason: .cancelled) }
        queue.asyncAfter(deadline: .now() + SPPWFileTransferLimits.offerLifetime) { [weak self] in
            self?.close(reason: .expired)
        }
    }

    func close(reason: CloseReason) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let open = connections
        connections.removeAll()
        lock.unlock()
        listener.cancel()
        open.forEach { $0.cancel() }
        registry?.update(id) { status in
            switch reason {
            case .finished:
                status.state = .finished
                status.doneBytes = status.totalBytes
            case .cancelled: status.state = .cancelled
            case .expired: status.state = status.state == .running ? .failed("expired") : .cancelled
            }
        }
        registry?.release(self)
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard !closed, connections.count < 4 else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections.append(connection)
        lock.unlock()
        let session = SenderSession(connection: connection, cipher: SPPWTransferCipher(key: key, isSender: true), owner: self)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let connection else { return }
                self.lock.lock()
                self.connections.removeAll { $0 === connection }
                self.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)
        session.receive()
    }

    fileprivate func url(for index: UInt32) -> URL? {
        guard Int(index) < items.count else { return nil }
        return items[Int(index)].url
    }

    fileprivate func validToken(_ candidate: Data) -> Bool {
        SPPWSecureTranscript.constantTimeEqual(candidate, token)
    }

    fileprivate func noteServed(_ bytes: Int) {
        lock.lock()
        served += UInt64(bytes)
        let total = served
        lock.unlock()
        registry?.update(id) { if $0.state == .waiting { $0.state = .running } }
        registry?.updateProgress(id, doneBytes: total)
    }

    fileprivate func finished() {
        close(reason: .finished)
    }

    /// One downloader connection: answers `get` requests one at a time.
    private final class SenderSession: @unchecked Sendable {
        let connection: NWConnection
        let cipher: SPPWTransferCipher
        weak var owner: SPPWFileTransferSender?
        var authenticated = false
        var pacer = SPPWTransferPacer(bytesPerSecond: SPPWFileTransferLimits.maximumBytesPerSecond)

        init(connection: NWConnection, cipher: SPPWTransferCipher, owner: SPPWFileTransferSender) {
            self.connection = connection
            self.cipher = cipher
            self.owner = owner
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    guard let records = cipher.feed(data) else {
                        connection.cancel()
                        return
                    }
                    for record in records { handle(record) }
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                receive()
            }
        }

        private func send(_ record: SPPWTransferRecord, completion: (@Sendable () -> Void)? = nil) {
            guard let sealed = cipher.seal(record.encoded()) else { return }
            connection.send(content: sealed, completion: .contentProcessed { error in
                if error == nil { completion?() }
            })
        }

        private func handle(_ plaintext: Data) {
            guard let record = SPPWTransferRecord(plaintext) else {
                connection.cancel()
                return
            }
            switch record {
            case let .hello(token):
                authenticated = owner?.validToken(token) == true
                if !authenticated { connection.cancel() }
            case let .get(index, offset) where authenticated:
                stream(index: index, from: offset)
            case .done where authenticated:
                owner?.finished()
            default:
                connection.cancel()
            }
        }

        private func stream(index: UInt32, from offset: UInt64) {
            guard let url = owner?.url(for: index), let handle = try? FileHandle(forReadingFrom: url) else {
                send(.failure(code: 1))
                return
            }
            do {
                try handle.seek(toOffset: offset)
            } catch {
                try? handle.close()
                send(.failure(code: 1))
                return
            }
            sendChunk(handle: handle, index: index, offset: offset)
        }

        /// Reads and sends one chunk, the next one only after the network took it (backpressure).
        private func sendChunk(handle: FileHandle, index: UInt32, offset: UInt64) {
            let chunk = (try? handle.read(upToCount: SPPWFileTransferLimits.chunkBytes)) ?? Data()
            guard !chunk.isEmpty else {
                try? handle.close()
                send(.endOfEntry(index: index))
                return
            }
            let delay = pacer.delay(forSending: chunk.count)
            let next = offset + UInt64(chunk.count)
            let work: @Sendable () -> Void = { [self] in
                send(.data(index: index, offset: offset, bytes: chunk)) { [self] in
                    owner?.noteServed(chunk.count)
                    sendChunk(handle: handle, index: index, offset: next)
                }
            }
            if delay > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                work()
            }
        }
    }
}

/// Token bucket for the sender's byte rate.
struct SPPWTransferPacer: Sendable {
    let bytesPerSecond: Double
    private var allowanceBytes: Double
    private var lastNanos: UInt64

    init(bytesPerSecond: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.bytesPerSecond = Double(bytesPerSecond)
        allowanceBytes = Double(bytesPerSecond) / 10
        lastNanos = now
    }

    /// Seconds to wait before sending `bytes` (0 when within the budget).
    mutating func delay(forSending bytes: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double {
        let elapsed = Double(now &- lastNanos) / 1e9
        lastNanos = now
        allowanceBytes = min(allowanceBytes + elapsed * bytesPerSecond, bytesPerSecond / 10)
        allowanceBytes -= Double(bytes)
        return allowanceBytes >= 0 ? 0 : -allowanceBytes / bytesPerSecond
    }
}

// MARK: Downloader

final class SPPWFileTransferDownloader: @unchecked Sendable {
    let id = UUID()
    private let offer: SPPWFileTransferOffer
    private let host: String
    private let folder: URL
    private let onlyTopLevel: String?
    private let completion: @Sendable ([URL]?) -> Void
    private weak var registry: SPPWFileTransfers?
    private let queue = DispatchQueue(label: "sppw.transfer.downloader", qos: .utility)
    private var connection: NWConnection?
    private var cipher: SPPWTransferCipher?
    private var indices: [Int]
    private var position = 0
    private var output: FileHandle?
    private var written: UInt64 = 0
    private var doneBefore: UInt64 = 0
    private var attempts = 0
    /// Connections closed before any record arrived: a wrong key or token (or a sender gone).
    private var silentCloses = 0
    private var receivedOnConnection = false
    private var finished = false
    private let total: UInt64

    init(
        offer: SPPWFileTransferOffer,
        host: String,
        directory: URL,
        registry: SPPWFileTransfers,
        onlyTopLevel: String? = nil,
        completion: @escaping @Sendable ([URL]?) -> Void
    ) {
        self.offer = offer
        self.host = host
        self.folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.onlyTopLevel = onlyTopLevel
        self.completion = completion
        self.registry = registry
        indices = offer.entries.indices.filter { index in
            guard let onlyTopLevel else { return true }
            let path = offer.entries[index].path
            return path == onlyTopLevel || path.hasPrefix(onlyTopLevel + "/")
        }
        total = indices.reduce(0) { $0 + offer.entries[$1].size }
        let title = onlyTopLevel ?? formatTitle(offer.topLevelNames, count: offer.entries.count)
        registry.register(
            SPPWFileTransferStatus(id: id, direction: .download, title: title, totalBytes: total, doneBytes: 0, state: .waiting)
        ) { [weak self] in self?.cancel() }
    }

    func start() {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                fail("folder")
                return
            }
            connect()
        }
    }

    private func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            connection?.cancel()
            try? output?.close()
            try? FileManager.default.removeItem(at: folder)
            registry?.update(id) { $0.state = .cancelled }
            registry?.release(self)
            completion(nil)
        }
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        try? output?.close()
        try? FileManager.default.removeItem(at: folder)
        registry?.update(id) { $0.state = .failed(reason) }
        registry?.release(self)
        completion(nil)
    }

    private func connect() {
        guard !finished else { return }
        guard let port = NWEndpoint.Port(rawValue: offer.port) else {
            fail("port")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: transferParameters())
        let cipher = SPPWTransferCipher(key: offer.key, isSender: false)
        receivedOnConnection = false
        self.connection = connection
        self.cipher = cipher
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.send(.hello(token: self.offer.token))
                    self.requestCurrent()
                }
            case .failed, .waiting:
                connection.cancel()
                self.queue.async { self.retry(after: connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, cipher: cipher)
    }

    /// Reconnects and resumes from the bytes already on disk.
    private func retry(after old: NWConnection) {
        guard !finished, connection === old else { return }
        if !receivedOnConnection {
            silentCloses += 1
            if silentCloses >= 3 {
                fail("refused")
                return
            }
        }
        attempts += 1
        guard attempts <= SPPWFileTransferLimits.maximumResumeAttempts else {
            fail("network")
            return
        }
        try? output?.close()
        output = nil
        queue.asyncAfter(deadline: .now() + min(Double(attempts), 5)) { [weak self] in self?.connect() }
    }

    private func send(_ record: SPPWTransferRecord) {
        guard let sealed = cipher?.seal(record.encoded()) else { return }
        connection?.send(content: sealed, completion: .idempotent)
    }

    private func receive(on connection: NWConnection, cipher: SPPWTransferCipher) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connection === connection, !self.finished else { return }
                if let data, !data.isEmpty {
                    guard let records = cipher.feed(data) else {
                        self.fail("integrity")
                        return
                    }
                    if !records.isEmpty { self.receivedOnConnection = true }
                    for record in records {
                        self.handle(record)
                        if self.finished { return }
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                    self.retry(after: connection)
                    return
                }
                self.receive(on: connection, cipher: cipher)
            }
        }
    }

    private func localURL(_ entry: SPPWFileTransferOffer.Entry) -> URL? {
        guard let components = SPPWFileTransferOffer.safeComponents(entry.path) else { return nil }
        return components.reduce(folder) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    /// Creates folders up to the next file and asks for it (from what is already on disk).
    private func requestCurrent() {
        while position < indices.count {
            let entry = offer.entries[indices[position]]
            guard let url = localURL(entry) else {
                fail("path")
                return
            }
            if entry.isDirectory {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                position += 1
                continue
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                fail("write")
                return
            }
            let existing = (try? handle.seekToEnd()) ?? 0
            if existing >= entry.size {
                try? handle.close()
                doneBefore += entry.size
                markQuarantined(url)
                position += 1
                continue
            }
            output = handle
            written = existing
            registry?.update(id) { $0.state = .running }
            send(.get(index: UInt32(indices[position]), offset: existing))
            return
        }
        complete()
    }

    private func handle(_ plaintext: Data) {
        guard let record = SPPWTransferRecord(plaintext) else {
            fail("protocol")
            return
        }
        switch record {
        case let .data(index, offset, bytes):
            guard position < indices.count, index == UInt32(indices[position]), offset == written, let output else {
                fail("protocol")
                return
            }
            do {
                try output.write(contentsOf: bytes)
            } catch {
                fail("write")
                return
            }
            written += UInt64(bytes.count)
            attempts = 0
            registry?.updateProgress(id, doneBytes: doneBefore + written)
        case let .endOfEntry(index):
            guard position < indices.count, index == UInt32(indices[position]) else {
                fail("protocol")
                return
            }
            let entry = offer.entries[indices[position]]
            try? output?.close()
            output = nil
            guard written == entry.size else {
                fail("size")
                return
            }
            if let url = localURL(entry) { markQuarantined(url) }
            doneBefore += written
            written = 0
            position += 1
            requestCurrent()
        case .failure:
            fail("sender")
        default:
            fail("protocol")
        }
    }

    private func markQuarantined(_ url: URL) {
        #if os(macOS)
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "PyrowaveCast",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String
        ]
        try? url.setResourceValues(values)
        #endif
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        if onlyTopLevel == nil {
            // Only full downloads end the sender's offer; a lazy per-item paste may need more.
            send(.done)
        }
        let topLevel: [URL]
        if let onlyTopLevel {
            topLevel = [folder.appendingPathComponent(onlyTopLevel)]
        } else {
            topLevel = offer.topLevelNames.map { folder.appendingPathComponent($0) }
        }
        let connection = self.connection
        queue.asyncAfter(deadline: .now() + 0.5) { connection?.cancel() }
        registry?.update(id) {
            $0.state = .finished
            $0.doneBytes = $0.totalBytes
        }
        registry?.release(self)
        completion(topLevel)
    }
}

#if os(macOS)
import CoreServices
#endif
