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

    /// Starts a channel for a new control session; `send` transmits one clipboard payload.
    func start(mtu: Int, enabled: Bool, send: @escaping @Sendable (Data) -> Void) {
        let newChannel = SPPWClipboardChannel(maxChunkBytes: SPPWClipboardChannel.chunkBytes(forMTU: mtu), send: send)
        lock.lock()
        channel?.cancel()
        channel = newChannel
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
    static func write(_ content: SPPWClipboardContent) {
        let item: [String: Any]
        switch content.format {
        case .utf8Text:
            guard let text = content.text else { return }
            item = [UTType.utf8PlainText.identifier: text]
        case .png:
            item = [UTType.png.identifier: content.data]
        }
        UIPasteboard.general.setItems([item], options: [.localOnly: true])
    }

    /// Loads the first text or image from pasted item providers (`UIPasteControl`).
    static func content(from providers: [NSItemProvider]) async -> SPPWClipboardContent? {
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
