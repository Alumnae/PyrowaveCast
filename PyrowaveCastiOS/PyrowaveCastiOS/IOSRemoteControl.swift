import Foundation
import UIKit
import UniformTypeIdentifiers
#if canImport(SPPWCommon)
import SPPWCommon
#endif

// MARK: - Remote control (iOS receiver → macOS server)

/// How touches on the video drive the Mac pointer.
enum IOSRemoteInputMode: String, CaseIterable, Sendable {
    /// Relative pointer like a Mac trackpad: one finger moves, tap clicks, two fingers scroll.
    case trackpad
    /// The finger is the pointer: touches click and drag where they land.
    case directTouch
}

/// Thread-safe clipboard sync state shared by the main actor (UI, pasteboard) and the
/// background UDP receive path.
final class IOSClipboardSession: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: SPPWClipboardChannel?
    private var host: String?

    /// The Mac's address, where large files offered through the clipboard are downloaded from.
    var peerHost: String? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }

    /// Starts a channel for a new control session; `send` transmits one clipboard payload.
    func start(mtu: Int, enabled: Bool, peerHost: String?, send: @escaping @Sendable (Data) -> Void) {
        let newChannel = SPPWClipboardChannel(maxChunkBytes: SPPWClipboardChannel.chunkBytes(forMTU: mtu), send: send)
        lock.lock()
        channel?.cancel()
        channel = newChannel
        host = peerHost
        lock.unlock()
        newChannel.sendSubscription(enabled: enabled)
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        let current = channel
        lock.unlock()
        if !enabled { current?.cancel() }
        current?.sendSubscription(enabled: enabled)
    }

    func stop() {
        lock.lock()
        channel?.cancel()
        channel = nil
        lock.unlock()
    }

    @discardableResult
    func offer(_ content: SPPWClipboardContent) -> Bool {
        lock.lock()
        let current = channel
        lock.unlock()
        return current?.offer(content) ?? false
    }

    /// Background path: returns a completed item from the Mac, if any.
    func receive(_ payload: Data) -> SPPWClipboardContent? {
        lock.lock()
        let current = channel
        lock.unlock()
        if case let .content(content) = current?.receive(payload) {
            return content
        }
        return nil
    }
}

/// `UIPasteboard` side of clipboard sync.
///
/// - Mac → iPhone: writes are free (no permission prompt) and use `localOnly`, so Universal
///   Clipboard does not bounce the item back to the Mac and replace its richer original.
/// - iPhone → Mac: the pasteboard is only read on an explicit user action (`UIPasteControl` in
///   the dock, which iOS allows without the paste prompt).
/// - With Universal Clipboard (same Apple ID, Handoff on) copies already travel by themselves;
///   the channel's digest check drops the duplicates, so the two paths never fight.
@MainActor
enum IOSClipboardBridge {
    static func write(_ content: SPPWClipboardContent, peerHost: String?) {
        if content.format == .fileOffer {
            writeOffer(content, peerHost: peerHost)
            return
        }
        let items: [[String: Any]]
        switch content.format {
        case .utf8Text:
            guard let text = content.text else { return }
            items = [[UTType.utf8PlainText.identifier: text]]
        case .png:
            items = [[UTType.png.identifier: content.data]]
        case .files:
            // Files copied on the Mac: one pasteboard item per file, typed by its extension.
            guard let container = SPPWClipboardFiles(decoding: content.data) else { return }
            items = container.files.map { file in
                let type = UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
                return [type.identifier: file.data]
            }
        case .fileOffer:
            return
        }
        guard !items.isEmpty else { return }
        UIPasteboard.general.setItems(items, options: [.localOnly: true])
    }

    /// Large files and folders copied on the Mac: one lazy item per top-level entry. Nothing is
    /// downloaded until an app actually pastes it; then the entry streams over the background
    /// transfer channel into a temporary folder (progress shows in the paste UI).
    private static func writeOffer(_ content: SPPWClipboardContent, peerHost: String?) {
        guard let offer = SPPWFileTransferOffer(decoding: content.data), let peerHost else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PyrowaveCast Transfers", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let topLevel = offer.entries.filter { !$0.path.contains("/") }
        let providers: [NSItemProvider] = topLevel.map { entry in
            let size = entry.isDirectory
                ? offer.entries.filter { $0.path.hasPrefix(entry.path + "/") }.reduce(0) { $0 + $1.size }
                : entry.size
            let type: UTType = entry.isDirectory ? .folder : (UTType(filenameExtension: (entry.path as NSString).pathExtension) ?? .data)
            let provider = NSItemProvider()
            provider.suggestedName = entry.path
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                let progress = Progress(totalUnitCount: Int64(clamping: max(size, 1)))
                let watcher = IOSTransferProgressWatcher(progress: progress)
                let id = SPPWFileTransfers.shared.download(offer, topLevelItem: entry.path, from: peerHost, into: directory) { url in
                    watcher.stop()
                    if let url {
                        completion(url, false, nil)
                    } else {
                        completion(nil, false, CocoaError(.fileReadUnknown))
                    }
                }
                watcher.start(transferID: id)
                progress.cancellationHandler = { SPPWFileTransfers.shared.cancel(id) }
                return progress
            }
            return provider
        }
        guard !providers.isEmpty else { return }
        UIPasteboard.general.setItemProviders(providers, localOnly: true, expirationDate: Date().addingTimeInterval(SPPWFileTransferLimits.offerLifetime))
    }

    /// The type of a provider that carries a file (a document or folder from Files), not text,
    /// a link or an image.
    static func fileType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.compactMap(UTType.init).first { type in
            (type.conforms(to: .data) || type.conforms(to: .directory))
                && !type.conforms(to: .text) && !type.conforms(to: .image) && !type.conforms(to: .url)
        }
    }

    /// Copies the files of `providers` out of their temporary locations (they vanish when the
    /// load handler returns) into a fresh outgoing folder.
    private static func loadFiles(_ providers: [(NSItemProvider, UTType)]) async -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PyrowaveCast Outgoing", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let batch = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, (provider, type)) in providers.enumerated() {
            let suggestedName = provider.suggestedName
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, _ in
                    guard let source else {
                        continuation.resume(returning: nil)
                        return
                    }
                    var name = SPPWClipboardFiles.sanitizedName(suggestedName ?? source.lastPathComponent) ?? "File \(index + 1)"
                    if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                        name += "." + ext
                    }
                    let target = batch.appendingPathComponent(name)
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.copyItem(at: source, to: target)
                        continuation.resume(returning: target)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    /// Files from the iPhone: inline up to the small-item limit, otherwise an offer for the
    /// background transfer (the Mac downloads them from this iPhone right away).
    private static func filesContent(_ urls: [URL]) -> SPPWClipboardContent? {
        guard !urls.isEmpty else { return nil }
        var total = 0
        var inline = urls.count <= SPPWClipboardFiles.maximumFileCount
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile != true { inline = false }
            total += values?.fileSize ?? 0
        }
        if inline && total <= SPPWFileTransferLimits.inlineByteLimit {
            let files = urls.compactMap { url in
                (try? Data(contentsOf: url)).map { SPPWClipboardFiles.File(name: url.lastPathComponent, data: $0) }
            }
            if let encoded = SPPWClipboardFiles(files: files).encoded() {
                return SPPWClipboardContent(format: .files, data: encoded)
            }
        }
        guard let offer = SPPWFileTransfers.shared.offer(urls), let encoded = offer.encoded() else { return nil }
        return SPPWClipboardContent(format: .fileOffer, data: encoded)
    }

    /// Loads files, else text, else an image from pasteboard item providers.
    static func content(from providers: [NSItemProvider]) async -> SPPWClipboardContent? {
        let files = providers.compactMap { provider in fileType(of: provider).map { (provider, $0) } }
        if !files.isEmpty, let content = filesContent(await loadFiles(files)) {
            return content
        }
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            if let text = await loadText(provider), !text.isEmpty {
                return SPPWClipboardContent(text: text)
            }
        }
        for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
            if let png = await loadPNG(provider), png.count <= SPPWClipboardFormat.png.maximumByteCount {
                return SPPWClipboardContent(format: .png, data: png)
            }
        }
        return nil
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { String($0) })
            }
        }
    }

    private static func loadPNG(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: (object as? UIImage)?.pngData())
            }
        }
    }
}


/// Mirrors a background transfer's byte count into the `Progress` handed to the paste UI.
final class IOSTransferProgressWatcher: @unchecked Sendable {
    private let progress: Progress
    private let lock = NSLock()
    private var observer: UUID?

    init(progress: Progress) {
        self.progress = progress
    }

    func start(transferID: UUID) {
        let progress = self.progress
        let token = SPPWFileTransfers.shared.addObserver { statuses in
            guard let status = statuses.first(where: { $0.id == transferID }) else { return }
            progress.completedUnitCount = Int64(clamping: status.doneBytes)
        }
        lock.lock()
        observer = token
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let token = observer
        observer = nil
        lock.unlock()
        if let token { SPPWFileTransfers.shared.removeObserver(token) }
    }
}
