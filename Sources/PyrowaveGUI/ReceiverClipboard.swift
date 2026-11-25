import Foundation
#if canImport(SPPWCommon)
import SPPWCommon
#endif

#if os(macOS)
/// Clipboard sync for the macOS receiver (`kind = 10`): the local pasteboard and the remote Mac's
/// pasteboard follow each other while remote control and sync are both on.
///
/// Thread-safe: the main actor starts and stops it, the UDP queue delivers payloads, and the
/// pasteboard poller offers local changes from its own queue. One channel is kept across
/// reconnects (re-created only when the MTU changes), so an item already exchanged is not resent
/// after every `serverHello`.
final class ReceiverClipboardSession: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: SPPWClipboardChannel?
    private var channelMTU = 0
    private var transport: (@Sendable (Data) -> Void)?
    private var peerHost: String?
    private var active = false
    private lazy var bridge = SPPWMacPasteboardBridge { [weak self] content in
        self?.offerLocal(content)
    }

    /// Starts (or refreshes) the session for a new control stream. `transport` sends one
    /// clipboard payload to the server (the `SPPW/1` header is added by the caller).
    func start(mtu: Int, enabled: Bool, peerHost: String?, transport: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        self.transport = transport
        self.peerHost = peerHost
        if channel == nil || channelMTU != mtu {
            channel?.cancel()
            channelMTU = mtu
            channel = SPPWClipboardChannel(maxChunkBytes: SPPWClipboardChannel.chunkBytes(forMTU: mtu)) { [weak self] payload in
                self?.currentTransport()?(payload)
            }
        }
        lock.unlock()
        setEnabled(enabled)
    }

    /// Turns sync on or off for the running session and tells the server.
    func setEnabled(_ enabled: Bool) {
        lock.lock()
        guard let channel, transport != nil else {
            active = false
            lock.unlock()
            bridge.stop()
            return
        }
        active = enabled
        lock.unlock()
        channel.sendSubscription(enabled: enabled)
        if enabled {
            bridge.start()
            // The receiver's own pasteboard: what was copied here before connecting can be
            // pasted on the remote Mac right away.
            if let current = SPPWMacPasteboardBridge.readCurrent() {
                channel.offer(current)
            }
        } else {
            bridge.stop()
            channel.cancel()
        }
    }

    /// Disconnect: stops polling and retransmissions; the channel (and its echo digest) stays.
    func stop() {
        lock.lock()
        active = false
        transport = nil
        let current = channel
        lock.unlock()
        bridge.stop()
        current?.cancel()
    }

    /// UDP queue: handles a clipboard payload from the server and writes a completed item
    /// to the local pasteboard. Returns the item for logging.
    func receive(_ payload: Data) -> SPPWClipboardContent? {
        lock.lock()
        let current = active ? channel : nil
        let host = peerHost
        lock.unlock()
        guard case let .content(content) = current?.receive(payload) else { return nil }
        bridge.write(content, peerHost: host)
        return content
    }

    private func offerLocal(_ content: SPPWClipboardContent) {
        lock.lock()
        let current = active ? channel : nil
        lock.unlock()
        current?.offer(content)
    }

    private func currentTransport() -> (@Sendable (Data) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return transport
    }
}
#endif
