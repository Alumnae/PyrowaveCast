import Darwin
import Dispatch
import Foundation
import Network

// MARK: - POSIX UDP Socket Buffer Tuning (SO_SNDBUF / SO_RCVBUF / DSCP CS4)

public struct SPPWSocketBufferMetrics: Sendable, Equatable {
    public let requestedSendBytes: Int
    public let requestedReceiveBytes: Int
    public let sendBufferBytes: Int
    public let receiveBufferBytes: Int
    public let dscpConfigured: Bool

    public var actualSendBytes: Int { sendBufferBytes }
    public var actualReceiveBytes: Int { receiveBufferBytes }

    public init(
        requestedSendBytes: Int = 0,
        requestedReceiveBytes: Int = 0,
        sendBufferBytes: Int,
        receiveBufferBytes: Int,
        dscpConfigured: Bool
    ) {
        self.requestedSendBytes = requestedSendBytes
        self.requestedReceiveBytes = requestedReceiveBytes
        self.sendBufferBytes = sendBufferBytes
        self.receiveBufferBytes = receiveBufferBytes
        self.dscpConfigured = dscpConfigured
    }
}

public enum SPPWSocketBufferTuning {
    /// Target 4 MB socket buffer on macOS and 2 MB on iOS, falling back gracefully
    /// to whatever `kern.ipc.maxsockbuf` permits on the host OS.
    #if os(iOS)
    public static let defaultTargetSendBufferBytes = 2 * 1024 * 1024
    public static let defaultTargetReceiveBufferBytes = 2 * 1024 * 1024
    #else
    public static let defaultTargetSendBufferBytes = 4 * 1024 * 1024
    public static let defaultTargetReceiveBufferBytes = 4 * 1024 * 1024
    #endif

    public static var defaultSendBufferBytes: Int { defaultTargetSendBufferBytes }
    public static var defaultReceiveBufferBytes: Int { defaultTargetReceiveBufferBytes }

    /// DSCP CS4 (`0x20 << 2 = 0x80`, real-time interactive video, maps to WMM `AC_VI` on Wi-Fi).
    public static let dscpInteractiveVideo: Int32 = 0x80
    public static let dscpInteractiveVideoCS4: Int32 = 0x80

    private static let fallbackSteps: [Int] = [
        4 * 1024 * 1024,
        2 * 1024 * 1024,
        1 * 1024 * 1024,
        512 * 1024,
        256 * 1024
    ]

    /// Applies `SO_SNDBUF`, `SO_RCVBUF`, `SO_NOSIGPIPE`, and `IP_TOS` / `IPV6_TCLASS` (`CS4`)
    /// to a POSIX UDP socket descriptor.
    @discardableResult
    public static func tuneUDPSocket(
        fd: Int32,
        isIPv6: Bool,
        targetSendBytes: Int = defaultTargetSendBufferBytes,
        targetReceiveBytes: Int = defaultTargetReceiveBufferBytes,
        dscpClass: Int32 = dscpInteractiveVideo
    ) -> SPPWSocketBufferMetrics {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        setSocketBufferOption(fd: fd, option: SO_SNDBUF, targetBytes: targetSendBytes)
        setSocketBufferOption(fd: fd, option: SO_RCVBUF, targetBytes: targetReceiveBytes)

        var tos: Int32 = dscpClass
        let dscpOK: Bool
        if isIPv6 {
            let r6 = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS, &tos, socklen_t(MemoryLayout<Int32>.size))
            let r4 = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
            dscpOK = (r6 == 0 || r4 == 0)
        } else {
            dscpOK = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size)) == 0
        }

        let actualSend = getSocketBufferOption(fd: fd, option: SO_SNDBUF)
        let actualRecv = getSocketBufferOption(fd: fd, option: SO_RCVBUF)
        return SPPWSocketBufferMetrics(
            requestedSendBytes: targetSendBytes,
            requestedReceiveBytes: targetReceiveBytes,
            sendBufferBytes: actualSend,
            receiveBufferBytes: actualRecv,
            dscpConfigured: dscpOK
        )
    }

    /// Convenience alias used by unit tests and callers.
    @discardableResult
    public static func apply(
        to fd: Int32,
        isIPv6: Bool = false,
        sendBufferBytes: Int = defaultTargetSendBufferBytes,
        receiveBufferBytes: Int = defaultTargetReceiveBufferBytes,
        dscpClass: Int32 = dscpInteractiveVideoCS4
    ) -> SPPWSocketBufferMetrics {
        tuneUDPSocket(
            fd: fd,
            isIPv6: isIPv6,
            targetSendBytes: sendBufferBytes,
            targetReceiveBytes: receiveBufferBytes,
            dscpClass: dscpClass
        )
    }

    private static func setSocketBufferOption(fd: Int32, option: Int32, targetBytes: Int) {
        var candidates = [targetBytes]
        for step in fallbackSteps where step < targetBytes {
            candidates.append(step)
        }
        for candidate in candidates {
            var val = Int32(clamping: candidate)
            if setsockopt(fd, SOL_SOCKET, option, &val, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                return
            }
        }
    }

    private static func getSocketBufferOption(fd: Int32, option: Int32) -> Int {
        var val: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, option, &val, &len) == 0 else { return 0 }
        return Int(val)
    }
}

public extension NWParameters {
    /// Interactive-video UDP `NWParameters` (WMM `AC_VI` / DSCP `CS4`) for low-latency control & fallback media links.
    static func sppwInteractiveVideo() -> NWParameters {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = true
        return params
    }
}

// MARK: - Peer Endpoint Address

/// Value-type wrapper around `sockaddr_storage` representing a remote UDP peer (IPv4 or IPv6).
public struct SPPWUDPPeerAddress: Sendable, Hashable {
    public let rawAddress: Data
    public let displayAddress: String
    public let peerKey: String

    /// Host-only key (without port) or stable peer identifier used for client session deduplication.
    public var hostKey: String {
        if let bracketRange = peerKey.range(of: "]:", options: .backwards), peerKey.hasPrefix("[") {
            return String(peerKey[peerKey.index(after: peerKey.startIndex)..<bracketRange.lowerBound])
        }
        if let colonIndex = peerKey.lastIndex(of: ":") {
            return String(peerKey[..<colonIndex])
        }
        return peerKey
    }

    public init?(sockaddrPtr: UnsafePointer<sockaddr>, length: socklen_t) {
        guard length > 0 else { return nil }
        let raw = Data(bytes: sockaddrPtr, count: Int(length))
        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var servBuf = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let res = getnameinfo(
            sockaddrPtr,
            length,
            &hostBuf,
            socklen_t(hostBuf.count),
            &servBuf,
            socklen_t(servBuf.count),
            NI_NUMERICHOST | NI_NUMERICSERV
        )
        guard res == 0 else { return nil }
        let hostRaw = String(decoding: hostBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let portStr = String(decoding: servBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let host = hostRaw.hasPrefix("::ffff:") ? String(hostRaw.dropFirst(7)) : hostRaw
        self.rawAddress = raw
        self.displayAddress = host.contains(":") ? "[\(host)]:\(portStr)" : "\(host):\(portStr)"
        self.peerKey = self.displayAddress
    }

    public static func == (lhs: SPPWUDPPeerAddress, rhs: SPPWUDPPeerAddress) -> Bool {
        lhs.peerKey == rhs.peerKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(peerKey)
    }
}

// MARK: - High-Throughput Non-Blocking POSIX UDP Server Socket

/// Owns a reusable 64 KB receive scratch buffer whose lifetime is tied to
/// ARC / `DispatchSourceRead`'s cancel handler, preventing use-after-free when
/// a socket is closed while `drainIncoming` is executing on its dispatch queue.
private final class SPPWReceiveScratchBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let capacity: Int

    init(capacity: Int = 65_536) {
        self.capacity = capacity
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        pointer.deallocate()
    }
}

/// Low-overhead dual-stack POSIX UDP server socket with explicit `SO_SNDBUF`/`SO_RCVBUF`
/// tuning, DSCP `CS4` Wi-Fi QoS marking, and batch receive draining.
public final class SPPWUDPServerSocket: @unchecked Sendable {
    public typealias DatagramHandler = @Sendable (Data, SPPWUDPPeerAddress) -> Void

    public let port: UInt16
    public let bufferMetrics: SPPWSocketBufferMetrics
    public var tuning: SPPWSocketBufferMetrics { bufferMetrics }
    public var boundAddressDescription: String { isIPv6 ? "0.0.0.0 / [::]" : "0.0.0.0" }

    private let fd: Int32
    private let isIPv6: Bool
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private let lock = NSLock()
    private var closed = false
    private var fdManagedBySource = false
    private var datagramHandler: DatagramHandler?
    /// Pre-allocated 64 KB receive buffer reused across all `DispatchSourceRead` wakeups on `queue`.
    private let receiveScratch = SPPWReceiveScratchBuffer(capacity: 65_536)
    private var securityLayer: SPPWServerSecurity?

    /// Secure transport (PROTOCOL.md §7). When set, handshake and pairing are answered here,
    /// the handler only sees plaintext datagrams of authorised peers, and `send` seals them.
    public var security: SPPWServerSecurity? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return securityLayer
        }
        set {
            lock.lock()
            securityLayer = newValue
            lock.unlock()
        }
    }

    public init(
        port: UInt16,
        queueLabel: String = "it.screenspan.pyrowave.udp.server",
        sendBufferBytes: Int = SPPWSocketBufferTuning.defaultTargetSendBufferBytes,
        receiveBufferBytes: Int = SPPWSocketBufferTuning.defaultTargetReceiveBufferBytes,
        onDatagram: DatagramHandler? = nil
    ) throws {
        // Prefer a dual-stack IPv6 UDP socket (`IPV6_V6ONLY = 0`) bound to `[::]`
        // so both IPv4 (`0.0.0.0`) and IPv6 LAN clients connect seamlessly.
        // If dual-stack cannot be enabled, fall back explicitly to IPv4 `INADDR_ANY` (`0.0.0.0`).
        var sockFD = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        var usingIPv6 = true
        if sockFD >= 0 {
            var zero: Int32 = 0
            if setsockopt(sockFD, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                Darwin.close(sockFD)
                sockFD = -1
            }
        }
        if sockFD < 0 {
            sockFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            usingIPv6 = false
        }
        guard sockFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var one: Int32 = 1
        _ = setsockopt(sockFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(sockFD, F_GETFL, 0)
        _ = fcntl(sockFD, F_SETFL, flags | O_NONBLOCK)

        var bindResult: Int32
        if usingIPv6 {
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            addr6.sin6_addr = in6addr_any
            bindResult = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(sockFD, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bindResult != 0 {
                // Retry with pure IPv4 INADDR_ANY if IPv6 bind failed on this host.
                Darwin.close(sockFD)
                sockFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                usingIPv6 = false
                if sockFD >= 0 {
                    _ = setsockopt(sockFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                    let flags4 = fcntl(sockFD, F_GETFL, 0)
                    _ = fcntl(sockFD, F_SETFL, flags4 | O_NONBLOCK)
                    var addr4 = sockaddr_in()
                    addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr4.sin_family = sa_family_t(AF_INET)
                    addr4.sin_port = port.bigEndian
                    addr4.sin_addr.s_addr = INADDR_ANY.bigEndian
                    bindResult = withUnsafePointer(to: &addr4) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.bind(sockFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        } else {
            var addr4 = sockaddr_in()
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = port.bigEndian
            addr4.sin_addr.s_addr = INADDR_ANY.bigEndian
            bindResult = withUnsafePointer(to: &addr4) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(sockFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sockFD < 0 || bindResult != 0 {
            let err = errno
            if sockFD >= 0 { Darwin.close(sockFD) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        self.fd = sockFD
        self.isIPv6 = usingIPv6
        self.port = port
        self.bufferMetrics = SPPWSocketBufferTuning.tuneUDPSocket(
            fd: sockFD,
            isIPv6: usingIPv6,
            targetSendBytes: sendBufferBytes,
            targetReceiveBytes: receiveBufferBytes
        )
        self.queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        self.datagramHandler = onDatagram

        if let onDatagram {
            start(onDatagram: onDatagram)
        }
    }

    public func start(onDatagram: @escaping DatagramHandler) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        self.datagramHandler = onDatagram
        if readSource != nil {
            lock.unlock()
            return
        }
        let sockFD = fd
        let scratch = receiveScratch
        let source = DispatchSource.makeReadSource(fileDescriptor: sockFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainIncoming(scratch: scratch, onDatagram: onDatagram)
        }
        // Close the file descriptor strictly inside the cancel handler once
        // libdispatch guarantees `drainIncoming` will never run again.
        source.setCancelHandler {
            _ = scratch
            Darwin.close(sockFD)
        }
        self.readSource = source
        self.fdManagedBySource = true
        lock.unlock()
        source.resume()
    }

    private func drainIncoming(scratch: SPPWReceiveScratchBuffer, onDatagram: DatagramHandler) {
        let base = scratch.pointer
        let capacity = scratch.capacity
        for _ in 0..<128 {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            if isClosed { break }

            var storage = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &storage) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(fd, base, capacity, 0, saPtr, &addrLen)
                }
            }
            if received <= 0 {
                if received < 0, errno == EBADF {
                    close()
                }
                break
            }
            let packet = Data(bytes: base, count: received)
            let peer = withUnsafePointer(to: &storage) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    SPPWUDPPeerAddress(sockaddrPtr: saPtr, length: addrLen)
                }
            }
            if let peer {
                if let security {
                    let plain = security.incoming(packet, from: peer.peerKey) { [weak self] reply in
                        self?.sendRaw(reply, to: peer)
                    }
                    if let plain { onDatagram(plain, peer) }
                } else {
                    onDatagram(packet, peer)
                }
            }
        }
    }

    /// Sends a single datagram to `peer` (sealed when `security` is set; dropped if the peer
    /// has no secure session). Returns `true` if sent or queued by kernel.
    @discardableResult
    public func send(_ data: Data, to peer: SPPWUDPPeerAddress) -> Bool {
        lock.lock()
        let isClosed = closed
        let security = securityLayer
        lock.unlock()
        guard !isClosed else { return false }
        if let security {
            guard let sealed = security.outgoing(data, to: peer.peerKey) else { return false }
            return sendRaw(sealed, to: peer)
        }
        return sendRaw(data, to: peer)
    }

    @discardableResult
    private func sendRaw(_ data: Data, to peer: SPPWUDPPeerAddress) -> Bool {

        return data.withUnsafeBytes { payloadBuf in
            peer.rawAddress.withUnsafeBytes { addrBuf in
                guard let payloadPtr = payloadBuf.baseAddress,
                      let saPtr = addrBuf.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                    return false
                }
                let sent = Darwin.sendto(
                    fd,
                    payloadPtr,
                    payloadBuf.count,
                    0,
                    saPtr,
                    socklen_t(peer.rawAddress.count)
                )
                if sent >= 0 { return true }
                // Retry once on transient EAGAIN / ENOBUFS without blocking actor/caller threads.
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == ENOBUFS {
                    sched_yield()
                    return Darwin.sendto(
                        fd,
                        payloadPtr,
                        payloadBuf.count,
                        0,
                        saPtr,
                        socklen_t(peer.rawAddress.count)
                    ) >= 0
                }
                return false
            }
        }
    }

    /// Sends a batch of datagrams to multiple connected peers.
    public func sendBatch(_ datagrams: [Data], to peers: [SPPWUDPPeerAddress]) {
        guard !datagrams.isEmpty, !peers.isEmpty else { return }
        for datagram in datagrams {
            for peer in peers {
                send(datagram, to: peer)
            }
        }
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let src = readSource
        readSource = nil
        let managed = fdManagedBySource
        let sockFD = fd
        lock.unlock()

        if let src {
            src.cancel()
        } else if !managed {
            Darwin.close(sockFD)
        }
    }

    public func stop() {
        close()
    }

    deinit {
        close()
    }
}

// MARK: - High-Throughput Non-Blocking POSIX UDP Client Socket

/// Connected POSIX UDP client socket for macOS and iOS receivers with explicit
/// `SO_RCVBUF` / `SO_SNDBUF` sizing (2–4 MB) and zero-allocation batch receive draining
/// so 60fps wavelet bursts over Wi-Fi never overflow the kernel receive queue.
public final class SPPWUDPClientSocket: @unchecked Sendable {
    public typealias DatagramHandler = @Sendable (Data) -> Void

    public let host: String
    public let port: UInt16
    public let resolvedAddressDescription: String
    public let bufferMetrics: SPPWSocketBufferMetrics
    public var tuning: SPPWSocketBufferMetrics { bufferMetrics }

    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private let lock = NSLock()
    private var closed = false
    private var fdManagedBySource = false
    private var securityLayer: SPPWClientSecurity?

    /// Secure transport (PROTOCOL.md §7), attached with `attachSecurity(_:)`.
    public var security: SPPWClientSecurity? {
        lock.lock()
        defer { lock.unlock() }
        return securityLayer
    }

    /// Runs `security` on this socket: it starts the handshake now; app datagrams sent before
    /// the session is ready are queued and sent sealed once it is.
    public func attachSecurity(_ security: SPPWClientSecurity) {
        lock.lock()
        securityLayer = security
        lock.unlock()
        security.start { [weak self] datagram in
            _ = self?.sendRawWithErrno(datagram)
        }
    }
    private var datagramHandler: DatagramHandler?
    /// Pre-allocated 64 KB receive buffer reused across all `DispatchSourceRead` wakeups on `queue`.
    private let receiveScratch = SPPWReceiveScratchBuffer(capacity: 65_536)

    public init(
        host: String,
        port: UInt16,
        queueLabel: String = "it.screenspan.pyrowave.udp.client",
        sendBufferBytes: Int = SPPWSocketBufferTuning.defaultTargetSendBufferBytes,
        receiveBufferBytes: Int = SPPWSocketBufferTuning.defaultTargetReceiveBufferBytes,
        onDatagram: DatagramHandler? = nil
    ) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var resPtr: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resPtr)
        guard status == 0, let firstAddr = resPtr else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(status != 0 ? status : EHOSTUNREACH),
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve host \(host):\(port)"]
            )
        }
        defer { freeaddrinfo(firstAddr) }

        struct CandidateAddress {
            let family: Int32
            let socktype: Int32
            let proto: Int32
            let addr: UnsafeMutablePointer<sockaddr>
            let addrlen: socklen_t
            let priority: Int
        }

        // Prefer IPv4 (`AF_INET`) over IPv6 when resolving hostnames (e.g. `.local`)
        // unless the user explicitly specified an IPv6 literal, and skip unscoped
        // IPv6 link-local addresses (`fe80::` with `sin6_scope_id == 0`) which are unroutable.
        let explicitIPv6 = host.contains(":")
        var candidates: [CandidateAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = firstAddr
        while let info = cursor?.pointee {
            if let sa = info.ai_addr {
                var priority = 10
                var skip = false
                if info.ai_family == AF_INET {
                    priority = explicitIPv6 ? 2 : 0
                } else if info.ai_family == AF_INET6 {
                    let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    let b0 = sin6.sin6_addr.__u6_addr.__u6_addr8.0
                    let b1 = sin6.sin6_addr.__u6_addr.__u6_addr8.1
                    let isLinkLocal = (b0 == 0xFE) && ((b1 & 0xC0) == 0x80)
                    if isLinkLocal && sin6.sin6_scope_id == 0 {
                        skip = true
                    } else if isLinkLocal {
                        priority = explicitIPv6 ? 1 : 3
                    } else {
                        priority = explicitIPv6 ? 0 : 1
                    }
                }
                if !skip {
                    candidates.append(CandidateAddress(
                        family: info.ai_family,
                        socktype: info.ai_socktype,
                        proto: info.ai_protocol,
                        addr: sa,
                        addrlen: info.ai_addrlen,
                        priority: priority
                    ))
                }
            }
            cursor = info.ai_next
        }
        candidates.sort { $0.priority < $1.priority }

        var connectedFD: Int32 = -1
        var isIPv6 = false
        var lastErrno: Int32 = EHOSTUNREACH
        var resolvedDesc = "\(host):\(port)"
        for candidateAddr in candidates {
            let candidate = socket(candidateAddr.family, candidateAddr.socktype, candidateAddr.proto)
            if candidate >= 0 {
                if Darwin.connect(candidate, candidateAddr.addr, candidateAddr.addrlen) == 0 {
                    connectedFD = candidate
                    isIPv6 = (candidateAddr.family == AF_INET6)
                    if let peerDesc = SPPWUDPPeerAddress(sockaddrPtr: candidateAddr.addr, length: candidateAddr.addrlen)?.displayAddress {
                        resolvedDesc = peerDesc
                    }
                    break
                }
                lastErrno = errno
                Darwin.close(candidate)
            } else {
                lastErrno = errno
            }
        }

        guard connectedFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(lastErrno))
        }

        let flags = fcntl(connectedFD, F_GETFL, 0)
        _ = fcntl(connectedFD, F_SETFL, flags | O_NONBLOCK)

        self.fd = connectedFD
        self.host = host
        self.port = port
        self.resolvedAddressDescription = resolvedDesc
        self.bufferMetrics = SPPWSocketBufferTuning.tuneUDPSocket(
            fd: connectedFD,
            isIPv6: isIPv6,
            targetSendBytes: sendBufferBytes,
            targetReceiveBytes: receiveBufferBytes
        )
        self.queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        self.datagramHandler = onDatagram

        if let onDatagram {
            start(datagramHandler: onDatagram)
        }
    }

    public func start(
        datagramHandler: @escaping DatagramHandler,
        errorHandler: (@Sendable (Error) -> Void)? = nil
    ) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        self.datagramHandler = datagramHandler
        if readSource != nil {
            lock.unlock()
            return
        }
        let sockFD = fd
        let scratch = receiveScratch
        let source = DispatchSource.makeReadSource(fileDescriptor: sockFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainIncoming(scratch: scratch, onDatagram: datagramHandler, errorHandler: errorHandler)
        }
        // Close the file descriptor strictly inside the cancel handler once
        // libdispatch guarantees `drainIncoming` will never run again.
        source.setCancelHandler {
            _ = scratch
            Darwin.close(sockFD)
        }
        self.readSource = source
        self.fdManagedBySource = true
        lock.unlock()
        source.resume()
    }

    private func drainIncoming(
        scratch: SPPWReceiveScratchBuffer,
        onDatagram: DatagramHandler,
        errorHandler: (@Sendable (Error) -> Void)?
    ) {
        let base = scratch.pointer
        let capacity = scratch.capacity
        // Drain up to 256 datagrams per wakeup to prevent kernel ring drops during Wi-Fi bursts.
        for _ in 0..<256 {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            if isClosed { break }

            let received = Darwin.recv(fd, base, capacity, 0)
            if received <= 0 {
                if received < 0 {
                    let err = errno
                    if err != EAGAIN && err != EWOULDBLOCK && err != EINTR && err != ECONNREFUSED {
                        // Cancel the read source BEFORE invoking errorHandler so kqueue
                        // cannot spin at 100% CPU re-delivering the same fatal socket error.
                        close()
                        errorHandler?(NSError(domain: NSPOSIXErrorDomain, code: Int(err)))
                    }
                }
                break
            }
            let packet = Data(bytes: base, count: received)
            if let security {
                if let plain = security.incoming(packet) { onDatagram(plain) }
            } else {
                onDatagram(packet)
            }
        }
    }

    /// Sends a datagram on the connected UDP socket, returning `0` on success or `errno` on failure.
    @discardableResult
    public func sendWithErrno(_ data: Data) -> Int32 {
        lock.lock()
        let isClosed = closed
        let security = securityLayer
        lock.unlock()
        guard !isClosed else { return EBADF }
        if let security {
            // Queued until the secure session is ready: not an error for the caller.
            guard let sealed = security.outgoing(data) else { return 0 }
            return sendRawWithErrno(sealed)
        }
        return sendRawWithErrno(data)
    }

    private func sendRawWithErrno(_ data: Data) -> Int32 {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return EBADF }

        return data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return EINVAL }
            let sent = Darwin.send(fd, base, rawBuf.count, 0)
            return sent >= 0 ? 0 : errno
        }
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        sendWithErrno(data) == 0
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        securityLayer?.stop()
        let src = readSource
        readSource = nil
        let managed = fdManagedBySource
        let sockFD = fd
        lock.unlock()

        if let src {
            src.cancel()
        } else if !managed {
            Darwin.close(sockFD)
        }
    }

    public func stop() {
        close()
    }

    deinit {
        close()
    }
}

// MARK: - Network Interface & Bonjour Service Resolution Support

public enum SPPWNetworkInterface {
    private static let ignoredPrefixes: [String] = [
        "utun", "awdl", "llw", "bridge", "vmenet", "anpi", "ap", "gif", "stf", "XHC", "lo"
    ]

    /// Returns the preferred active non-loopback LAN IPv4 address (`en0`/`en1` first, then any physical `en*`,
    /// excluding VPN tunnels, AWDL, bridges, and link-local `169.254.*`).
    public static func preferredLocalIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        var primaryEN: String?
        var secondaryEN: String?
        var otherPhysical: String?

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            if ignoredPrefixes.contains(where: { name.hasPrefix($0) }) {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let ip = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !ip.isEmpty, ip != "127.0.0.1", !ip.hasPrefix("169.254.") else {
                continue
            }

            if name == "en0" || name == "en1" {
                if name == "en0" {
                    return ip
                }
                if primaryEN == nil {
                    primaryEN = ip
                }
            } else if name.hasPrefix("en") {
                if secondaryEN == nil {
                    secondaryEN = ip
                }
            } else if otherPhysical == nil {
                otherPhysical = ip
            }
        }
        return primaryEN ?? secondaryEN ?? otherPhysical
    }

    /// Non-blocking display service name for Bonjour advertisement (avoids `Host.current().localizedName`
    /// which can block on reverse-DNS queries when LAN DNS is slow).
    public static func localBonjourServiceName() -> String {
        let rawHost = ProcessInfo.processInfo.hostName
        let stripped = rawHost.hasSuffix(".local")
            ? String(rawHost.dropLast(".local".count))
            : (rawHost.hasSuffix(".local.") ? String(rawHost.dropLast(".local.".count)) : rawHost)
        let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "PyrowaveCast" : cleaned
    }

    /// Converts a Bonjour service instance name into a valid `.local` mDNS hostname
    /// (replacing spaces with hyphens) when only the service instance name is available.
    public static func sanitizedMDNSHostname(serviceName: String, domain: String = "local") -> String {
        let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let baseName = serviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let effectiveBase = baseName.isEmpty ? "localhost" : baseName
        return "\(effectiveBase).\(cleanDomain.isEmpty ? "local" : cleanDomain)"
    }
}

/// Resolves Bonjour `NetService` endpoints (`_pyrowavecast._udp` / `_pyrowave._udp`) on `RunLoop.main`
/// with a bounded 5-second timeout, extracting the directly routable IPv4 (preferred) or IPv6 address,
/// UDP port, and TXT dictionary without leaking `NWConnection` instances.
public final class SPPWBonjourServiceResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    public struct ResolvedEndpoint: Sendable, Equatable {
        public let id: String
        public let host: String
        public let port: UInt16
        public let txtRecords: [String: String]
    }

    public typealias Completion = @Sendable (ResolvedEndpoint?) -> Void

    private final class ResolutionEntry: NSObject, NetServiceDelegate {
        let id: String
        let service: NetService
        let completion: Completion
        var finished = false
        weak var owner: SPPWBonjourServiceResolver?

        init(
            id: String,
            service: NetService,
            owner: SPPWBonjourServiceResolver,
            completion: @escaping Completion
        ) {
            self.id = id
            self.service = service
            self.owner = owner
            self.completion = completion
            super.init()
            self.service.delegate = self
        }

        func start(timeout: TimeInterval) {
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: timeout)
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            guard !finished else { return }
            finished = true
            let resolved = Self.extractEndpoint(id: id, from: sender)
            sender.stop()
            sender.remove(from: .main, forMode: .common)
            sender.delegate = nil
            owner?.removeEntry(id: id)
            completion(resolved)
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
            guard !finished else { return }
            finished = true
            sender.stop()
            sender.remove(from: .main, forMode: .common)
            sender.delegate = nil
            owner?.removeEntry(id: id)
            completion(nil)
        }

        private static func extractEndpoint(id: String, from sender: NetService) -> ResolvedEndpoint? {
            var txtRecords: [String: String] = [:]
            if let txtData = sender.txtRecordData() {
                let dict = NetService.dictionary(fromTXTRecord: txtData)
                for (key, value) in dict {
                    if let str = String(data: value, encoding: .utf8), !str.isEmpty {
                        txtRecords[key] = str
                    }
                }
            }

            let resolvedPort: UInt16
            if sender.port > 0 && sender.port <= Int(UInt16.max) {
                resolvedPort = UInt16(sender.port)
            } else if let txtPort = txtRecords["port"], let parsed = UInt16(txtPort), parsed > 0 {
                resolvedPort = parsed
            } else {
                resolvedPort = 9999
            }

            var ipv4Candidate: String?
            var ipv6Candidate: String?

            if let addresses = sender.addresses {
                for addrData in addresses where addrData.count >= MemoryLayout<sockaddr>.size {
                    addrData.withUnsafeBytes { rawBuf in
                        guard let saPtr = rawBuf.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                        let family = Int32(saPtr.pointee.sa_family)
                        guard family == AF_INET || family == AF_INET6 else { return }
                        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let res = getnameinfo(
                            saPtr,
                            socklen_t(addrData.count),
                            &hostBuf,
                            socklen_t(hostBuf.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                        guard res == 0 else { return }
                        let rawIP = String(decoding: hostBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        let ip = rawIP.hasPrefix("::ffff:") ? String(rawIP.dropFirst(7)) : rawIP
                        if family == AF_INET || (!ip.contains(":") && ip.contains(".")) {
                            if !ip.hasPrefix("169.254.") && ip != "127.0.0.1" && ipv4Candidate == nil {
                                ipv4Candidate = ip
                            }
                        } else if family == AF_INET6 {
                            if !ip.lowercased().hasPrefix("fe80:") && ipv6Candidate == nil {
                                ipv6Candidate = ip
                            }
                        }
                    }
                }
            }

            let txtHost = txtRecords["ip"] ?? txtRecords["host"]
            let cleanTXTHost = (txtHost?.contains(" ") == false && !(txtHost?.isEmpty ?? true)) ? txtHost : nil
            let cleanSenderHost = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

            guard let chosenHost = ipv4Candidate
                ?? cleanTXTHost
                ?? ((cleanSenderHost?.contains(" ") == false && !(cleanSenderHost?.isEmpty ?? true)) ? cleanSenderHost : nil)
                ?? ipv6Candidate else {
                return nil
            }

            return ResolvedEndpoint(
                id: id,
                host: chosenHost,
                port: resolvedPort,
                txtRecords: txtRecords
            )
        }
    }

    private let lock = NSLock()
    private var entries: [String: ResolutionEntry] = [:]

    public override init() {
        super.init()
    }

    public func resolve(
        id: String,
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval = 5.0,
        completion: @escaping Completion
    ) {
        let normalizedType = type.hasSuffix(".") ? type : "\(type)."
        let normalizedDomain = domain.hasSuffix(".") ? domain : "\(domain)."
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.entries[id] != nil {
                self.lock.unlock()
                return
            }
            let service = NetService(domain: normalizedDomain, type: normalizedType, name: name)
            let entry = ResolutionEntry(id: id, service: service, owner: self, completion: completion)
            self.entries[id] = entry
            self.lock.unlock()
            entry.start(timeout: timeout)
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    public func cancelAll() {
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = Array(self.entries.values)
            self.entries.removeAll()
            self.lock.unlock()
            for entry in current {
                entry.cancel()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    fileprivate func removeEntry(id: String) {
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
    }

    deinit {
        cancelAll()
    }
}

// MARK: - Bonjour Service Advertiser (Companion to POSIX UDP Server Socket)

/// Lightweight `dnssd` / `NetService` Bonjour advertiser used alongside `SPPWUDPServerSocket`
/// so iOS and macOS receivers discover `_pyrowavecast._udp` (plus legacy `_pyrowave._udp`)
/// together with the `host` / `port` TXT record.
public final class SPPWBonjourAdvertiser: NSObject, @unchecked Sendable {
    public static let primaryServiceType = "_pyrowavecast._udp."
    public static let legacyServiceType = "_pyrowave._udp."

    private final class ServiceHolder: @unchecked Sendable {
        let lock = NSLock()
        var services: [NetService] = []
        var generation: UInt64 = 0
    }

    private let holder = ServiceHolder()

    public override init() {
        super.init()
    }

    public func start(
        serviceName: String = "",
        serviceType: String = SPPWBonjourAdvertiser.primaryServiceType,
        additionalServiceTypes: [String] = [SPPWBonjourAdvertiser.legacyServiceType],
        port: UInt16,
        txtRecords: [String: String] = [:]
    ) {
        var uniqueTypes: [String] = []
        for rawType in [serviceType] + additionalServiceTypes {
            let normalized = rawType.hasSuffix(".") ? rawType : "\(rawType)."
            if !uniqueTypes.contains(normalized) {
                uniqueTypes.append(normalized)
            }
        }
        let types = uniqueTypes
        let txtData: Data?
        if !txtRecords.isEmpty {
            var txtDict: [String: Data] = [:]
            for (k, v) in txtRecords {
                txtDict[k] = Data(v.utf8)
            }
            txtData = NetService.data(fromTXTRecord: txtDict)
        } else {
            txtData = nil
        }

        let holder = self.holder
        holder.lock.lock()
        holder.generation &+= 1
        let targetGeneration = holder.generation
        holder.lock.unlock()

        // `NetService` requires an active `RunLoop` (`RunLoop.main`) to register
        // with `mDNSResponder`. Callers like `actor StreamServer` and
        // `actor IOSStreamServer` run on Swift's cooperative thread pool where
        // `RunLoop.current` is never pumped.
        let publishWork: @Sendable () -> Void = {
            holder.lock.lock()
            let previous = holder.services
            holder.services = []
            let isCurrent = (holder.generation == targetGeneration)
            holder.lock.unlock()

            for service in previous {
                service.stop()
                service.remove(from: .main, forMode: .common)
            }
            guard isCurrent else { return }

            let created = types.map { normalizedType -> NetService in
                let service = NetService(domain: "local.", type: normalizedType, name: serviceName, port: Int32(port))
                if let txtData {
                    service.setTXTRecord(txtData)
                }
                service.schedule(in: .main, forMode: .common)
                service.publish()
                return service
            }

            holder.lock.lock()
            if holder.generation == targetGeneration {
                holder.services = created
                holder.lock.unlock()
            } else {
                holder.lock.unlock()
                for service in created {
                    service.stop()
                    service.remove(from: .main, forMode: .common)
                }
            }
        }

        if Thread.isMainThread {
            publishWork()
        } else {
            DispatchQueue.main.async(execute: publishWork)
        }
    }

    public func start(serviceType: String = SPPWBonjourAdvertiser.primaryServiceType, port: UInt16, ipv4Address: String?) {
        var txt: [String: String] = ["port": String(port), "proto": "SPPW/1"]
        if let ipv4Address, !ipv4Address.isEmpty {
            txt["ip"] = ipv4Address
            txt["host"] = ipv4Address
        }
        start(serviceName: "", serviceType: serviceType, port: port, txtRecords: txt)
    }

    public func stop() {
        let holder = self.holder
        holder.lock.lock()
        holder.generation &+= 1
        let hadServices = !holder.services.isEmpty
        holder.lock.unlock()
        guard hadServices else { return }

        let stopWork: @Sendable () -> Void = {
            holder.lock.lock()
            let previous = holder.services
            holder.services = []
            holder.lock.unlock()
            for service in previous {
                service.stop()
                service.remove(from: .main, forMode: .common)
            }
        }
        if Thread.isMainThread {
            stopWork()
        } else {
            DispatchQueue.main.async(execute: stopWork)
        }
    }

    deinit {
        stop()
    }
}

// MARK: - Sub-Millisecond Mach Packet Pacer

/// Spreads a frame's UDP fragments (and interleaved FEC parity packets) across 65% of the
/// frame interval in micro-bursts of 4 packets using `mach_wait_until`, preventing Wi-Fi AP
/// bufferbloat and local kernel `ENOBUFS` drops.
///
/// If a newer frame is enqueued while an older frame is still being paced out, the remaining
/// tail of the older frame is immediately pre-empted so latency never accumulates.
public final class SPPWMediaPacer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var latestGeneration: UInt64 = 0
    private let microBurstSize = 4
    /// Share of the frame interval a frame is spread over. Wider spreading lowers the peak rate
    /// a Wi-Fi access point has to absorb (bursts overflow its queues and cause loss bursts).
    private let frameSpreadFraction = 0.80
    /// Upper bound of the spread for low frame rates.
    private let maximumSpreadNanos = 14_000_000.0

    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init(label: String = "it.screenspan.pyrowave.media.pacer") {
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    @inline(__always)
    private static func nanosecondsToMachAbsolute(_ nanos: UInt64) -> UInt64 {
        let denom = UInt64(max(timebaseInfo.denom, 1))
        let numer = UInt64(max(timebaseInfo.numer, 1))
        return (nanos * denom) / numer
    }

    /// Enqueues a frame's ordered datagrams (LL fragments + LL FEC first, then HF fragments + HF FEC)
    /// for paced transmission. Any older frame still in flight on the pacer is pre-empted.
    public func paceFrame(
        datagrams: [Data],
        fps: Int,
        sendDatagram: @escaping @Sendable (Data) -> Void
    ) {
        guard !datagrams.isEmpty else { return }

        lock.lock()
        latestGeneration &+= 1
        let generation = latestGeneration
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let count = datagrams.count
            // Small frames (<= 8 packets) go out immediately without sleeping.
            if count <= 8 {
                for packet in datagrams {
                    if self.isGenerationSuperseded(generation) { return }
                    sendDatagram(packet)
                }
                return
            }

            let clampedFPS = Double(min(max(fps, 15), 240))
            let frameIntervalNanos = 1_000_000_000.0 / clampedFPS
            let totalSpreadNanos = min(frameIntervalNanos * self.frameSpreadFraction, self.maximumSpreadNanos)
            let burstCount = max(1, (count + self.microBurstSize - 1) / self.microBurstSize)
            let burstIntervalNanos = UInt64(max(25_000.0, totalSpreadNanos / Double(burstCount)))
            let burstIntervalMach = Self.nanosecondsToMachAbsolute(burstIntervalNanos)

            let startMach = mach_absolute_time()
            var nextDeadlineMach = startMach

            var index = 0
            while index < count {
                if self.isGenerationSuperseded(generation) {
                    // Newer frame is ready: finish a frame that is only slightly late (capture
                    // jitter) at full speed, pre-empt the trailing HF packets of a real backlog.
                    if Self.shouldFlushSupersededFrame(startMach: startMach, frameIntervalNanos: frameIntervalNanos) {
                        while index < count {
                            sendDatagram(datagrams[index])
                            index += 1
                        }
                    }
                    return
                }

                let burstEnd = min(index + self.microBurstSize, count)
                while index < burstEnd {
                    sendDatagram(datagrams[index])
                    index += 1
                }

                if index < count {
                    nextDeadlineMach &+= burstIntervalMach
                    let now = mach_absolute_time()
                    if nextDeadlineMach > now {
                        mach_wait_until(nextDeadlineMach)
                    } else {
                        nextDeadlineMach = now
                    }
                }
            }
        }
    }

    public func enqueueFrame(
        datagrams: [Data],
        burstSize: Int = 4,
        fps: Int,
        sendBurst: @escaping @Sendable ([Data]) -> Void
    ) {
        guard !datagrams.isEmpty else { return }

        lock.lock()
        latestGeneration &+= 1
        let generation = latestGeneration
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let count = datagrams.count
            let bSize = max(1, burstSize)

            if count <= bSize {
                if !self.isGenerationSuperseded(generation) {
                    sendBurst(datagrams)
                }
                return
            }

            let clampedFPS = Double(min(max(fps, 15), 240))
            let frameIntervalNanos = 1_000_000_000.0 / clampedFPS
            let totalSpreadNanos = min(frameIntervalNanos * self.frameSpreadFraction, self.maximumSpreadNanos)
            let burstCount = max(1, (count + bSize - 1) / bSize)
            let burstIntervalNanos = UInt64(max(25_000.0, totalSpreadNanos / Double(burstCount)))
            let burstIntervalMach = Self.nanosecondsToMachAbsolute(burstIntervalNanos)

            let startMach = mach_absolute_time()
            var nextDeadlineMach = startMach
            var index = 0
            while index < count {
                if self.isGenerationSuperseded(generation) {
                    // See `paceFrame`: finish a slightly late frame, drop a real backlog.
                    if Self.shouldFlushSupersededFrame(startMach: startMach, frameIntervalNanos: frameIntervalNanos) {
                        while index < count {
                            let burstEnd = min(index + bSize, count)
                            sendBurst(Array(datagrams[index..<burstEnd]))
                            index = burstEnd
                        }
                    }
                    return
                }

                let burstEnd = min(index + bSize, count)
                let slice = Array(datagrams[index..<burstEnd])
                sendBurst(slice)
                index = burstEnd

                if index < count {
                    nextDeadlineMach &+= burstIntervalMach
                    let now = mach_absolute_time()
                    if nextDeadlineMach > now {
                        mach_wait_until(nextDeadlineMach)
                    } else {
                        nextDeadlineMach = now
                    }
                }
            }
        }
    }

    public func cancelAll() {
        lock.lock()
        latestGeneration &+= 1
        lock.unlock()
    }

    public func cancelPending() {
        cancelAll()
    }

    /// A superseded frame is finished when it started less than one frame interval ago:
    /// the next frame merely arrived early (uneven capture timing). Cutting it would turn
    /// every early capture into a partial-HF frame on the receiver.
    static func shouldFlushSupersededFrame(startMach: UInt64, frameIntervalNanos: Double) -> Bool {
        let elapsedMach = mach_absolute_time() &- startMach
        let numer = UInt64(max(timebaseInfo.numer, 1))
        let denom = UInt64(max(timebaseInfo.denom, 1))
        let elapsedNanos = Double(elapsedMach * numer / denom)
        return elapsedNanos < frameIntervalNanos
    }

    @inline(__always)
    private func isGenerationSuperseded(_ generation: UInt64) -> Bool {
        lock.lock()
        let superseded = generation != latestGeneration
        lock.unlock()
        return superseded
    }
}

// MARK: - Adaptive Wi-Fi Client Buffer & Latency Mode

public enum SPPWLatencyMode: UInt8, CaseIterable, Identifiable, Sendable {
    /// Zero playout buffer (`maxBufferedFrames = 0`), immediate LL-drop on newer frame arrival.
    case ultraLowLatency = 0
    /// Adaptive 1-frame Wi-Fi jitter absorption (`maxBufferedFrames = 1`), FEC + partial-HF decode.
    case balancedWiFi = 1
    /// Resilient Wi-Fi buffer (`maxBufferedFrames = 2`), absorbs 802.11 CSMA/CA & AWDL spikes up to ~28ms.
    case smoothWiFi = 2

    /// Aliases used by receivers and unit tests.
    public static let ultraLow: SPPWLatencyMode = .ultraLowLatency
    public static let wifiResilient: SPPWLatencyMode = .smoothWiFi

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .ultraLowLatency: return SPPWLocalization.tr("latency.ultra_low")
        case .balancedWiFi: return SPPWLocalization.tr("latency.balanced_wifi")
        case .smoothWiFi: return SPPWLocalization.tr("latency.smooth_wifi")
        }
    }

    public var defaultFrameTimeoutMs: Int {
        switch self {
        case .ultraLowLatency: return 8
        case .balancedWiFi: return 14
        case .smoothWiFi: return 28
        }
    }

    public var defaultMaxBufferedFrames: Int {
        switch self {
        case .ultraLowLatency: return 0
        case .balancedWiFi: return 1
        case .smoothWiFi: return 2
        }
    }

    public var defaultFECPercent: Int {
        switch self {
        case .ultraLowLatency: return 10
        case .balancedWiFi: return 15
        case .smoothWiFi: return 20
        }
    }
}

/// Real-time RFC 3550 inter-arrival jitter estimator and adaptive playout buffer depth controller
/// for iOS and macOS Wi-Fi receivers.
public struct SPPWAdaptiveWiFiBuffer: Sendable {
    public var mode: SPPWLatencyMode {
        didSet {
            recomputeRecommendations(fps: 60)
        }
    }
    /// Smoothed inter-arrival jitter in milliseconds.
    public private(set) var jitterMs: Double = 0.0
    public var jitterMilliseconds: Double { jitterMs }

    /// Recommended frame reassembly timeout in milliseconds before salvaging partial-HF or dropping.
    public private(set) var recommendedFrameTimeoutMs: Int
    /// Recommended playout buffer depth in frames (`0 ... 2`).
    public private(set) var recommendedBufferDepthFrames: Int

    /// Target playout delay in milliseconds derived from mode + smoothed Wi-Fi jitter.
    public var targetPlayoutDelayMilliseconds: Double {
        switch mode {
        case .ultraLowLatency:
            return min(8.0, jitterMs * 0.75)
        case .balancedWiFi:
            return min(22.0, max(4.0, jitterMs * 1.5 + 4.0))
        case .smoothWiFi:
            return min(38.0, max(10.0, jitterMs * 2.2 + 10.0))
        }
    }

    /// Maximum acceptable frame age (reassembly + decode) in milliseconds before dropping a stale frame.
    public var maxAcceptableAgeMs: Double {
        switch mode {
        case .ultraLowLatency:
            return max(60.0, 45.0 + jitterMs * 2.0)
        case .balancedWiFi:
            return max(90.0, 65.0 + jitterMs * 3.0)
        case .smoothWiFi:
            return max(130.0, 85.0 + jitterMs * 3.5)
        }
    }

    private var lastSenderTimestampNanos: UInt64 = 0
    private var lastArrivalTimestampNanos: UInt64 = 0
    private var recentFECRecoveryRate: Double = 0.0

    public init(mode: SPPWLatencyMode = .balancedWiFi) {
        self.mode = mode
        self.recommendedFrameTimeoutMs = mode.defaultFrameTimeoutMs
        self.recommendedBufferDepthFrames = mode.defaultMaxBufferedFrames
        recomputeRecommendations(fps: 60)
    }

    public mutating func setMode(_ newMode: SPPWLatencyMode) {
        self.mode = newMode
    }

    public mutating func reset() {
        jitterMs = 0.0
        lastSenderTimestampNanos = 0
        lastArrivalTimestampNanos = 0
        recentFECRecoveryRate = 0.0
        recomputeRecommendations(fps: 60)
    }

    public func recommendedTimeoutMs(fps: Int = 60) -> Int {
        let framePeriodMs = 1000.0 / Double(min(max(fps, 15), 240))
        switch mode {
        case .ultraLowLatency:
            return min(14, max(6, Int((framePeriodMs * 0.5 + jitterMs * 1.1).rounded(.up))))
        case .balancedWiFi:
            let raw = framePeriodMs * 0.8 + jitterMs * 1.8 + (recentFECRecoveryRate > 0.05 ? 3.0 : 0.0)
            return min(26, max(12, Int(raw.rounded(.up))))
        case .smoothWiFi:
            let raw = max(28.0, framePeriodMs * 1.5 + 3.0) + jitterMs * 2.4
            return min(48, max(28, Int(raw.rounded(.up))))
        }
    }

    /// Updates the jitter estimator whenever a complete or partial-HF frame is assembled.
    public mutating func recordFrameArrival(
        senderTimestampNanoseconds: UInt64,
        arrivalTimestampNanoseconds: UInt64,
        fps: Int,
        hadFECRecovery: Bool
    ) {
        if lastSenderTimestampNanos > 0,
           lastArrivalTimestampNanos > 0,
           senderTimestampNanoseconds > lastSenderTimestampNanos,
           arrivalTimestampNanoseconds > lastArrivalTimestampNanos {
            let senderDeltaMs = Double(senderTimestampNanoseconds - lastSenderTimestampNanos) / 1_000_000.0
            let arrivalDeltaMs = Double(arrivalTimestampNanoseconds - lastArrivalTimestampNanos) / 1_000_000.0
            let transitDiffMs = min(abs(arrivalDeltaMs - senderDeltaMs), 100.0)
            // RFC 3550 EWMA: J = J + (|D| - J) / 16
            jitterMs += (transitDiffMs - jitterMs) / 16.0
        }
        lastSenderTimestampNanos = senderTimestampNanoseconds
        lastArrivalTimestampNanos = arrivalTimestampNanoseconds

        let sample = hadFECRecovery ? 1.0 : 0.0
        recentFECRecoveryRate = recentFECRecoveryRate * 0.9 + sample * 0.1
        recomputeRecommendations(fps: fps)
    }

    /// Convenience overload used by receivers and unit tests.
    public mutating func recordFrameArrival(
        senderTimestampNanos: UInt64,
        arrivalUptimeNanos: UInt64,
        fps: Int = 60,
        hadFECRecovery: Bool = false
    ) {
        recordFrameArrival(
            senderTimestampNanoseconds: senderTimestampNanos,
            arrivalTimestampNanoseconds: arrivalUptimeNanos,
            fps: fps,
            hadFECRecovery: hadFECRecovery
        )
    }

    private mutating func recomputeRecommendations(fps: Int) {
        let clampedFPS = Double(min(max(fps, 15), 240))
        let framePeriodMs = 1000.0 / clampedFPS

        switch mode {
        case .ultraLowLatency:
            recommendedBufferDepthFrames = 0
            recommendedFrameTimeoutMs = min(14, max(6, Int((framePeriodMs * 0.5 + jitterMs * 1.1).rounded(.up))))
        case .balancedWiFi:
            if jitterMs > 9.0 {
                recommendedBufferDepthFrames = 2
            } else {
                recommendedBufferDepthFrames = 1
            }
            let rawTimeout = framePeriodMs * 0.8 + jitterMs * 1.8 + (recentFECRecoveryRate > 0.05 ? 3.0 : 0.0)
            recommendedFrameTimeoutMs = min(26, max(12, Int(rawTimeout.rounded(.up))))
        case .smoothWiFi:
            recommendedBufferDepthFrames = jitterMs > 12.0 ? 3 : 2
            let rawTimeout = max(28.0, framePeriodMs * 1.5 + 3.0) + jitterMs * 2.4
            recommendedFrameTimeoutMs = min(48, max(28, Int(rawTimeout.rounded(.up))))
        }
    }
}

// MARK: - Adaptive Bitrate Controller (ABR)

/// 1-second network health observation fed into `SPPWAdaptiveBitrateController`.
public struct SPPWAdaptiveBitrateSample: Sendable, Equatable {
    public let timestampNanoseconds: UInt64
    public let completeFramesDelta: Int
    public let llDroppedFramesDelta: Int
    public let expiredFramesDelta: Int
    public let partialHFFramesDelta: Int
    public let fecRecoveredFramesDelta: Int
    public let lateDroppedFramesDelta: Int
    public let jitterMs: Double

    public init(
        timestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        completeFramesDelta: Int,
        llDroppedFramesDelta: Int = 0,
        expiredFramesDelta: Int = 0,
        partialHFFramesDelta: Int = 0,
        fecRecoveredFramesDelta: Int = 0,
        lateDroppedFramesDelta: Int = 0,
        jitterMs: Double = 0.0
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.completeFramesDelta = max(0, completeFramesDelta)
        self.llDroppedFramesDelta = max(0, llDroppedFramesDelta)
        self.expiredFramesDelta = max(0, expiredFramesDelta)
        self.partialHFFramesDelta = max(0, partialHFFramesDelta)
        self.fecRecoveredFramesDelta = max(0, fecRecoveredFramesDelta)
        self.lateDroppedFramesDelta = max(0, lateDroppedFramesDelta)
        self.jitterMs = max(0.0, jitterMs)
    }
}

/// Action returned by `SPPWAdaptiveBitrateController.evaluate(_:)`.
public enum SPPWAdaptiveBitrateDecision: Sendable, Equatable {
    case hold
    case stepDown(newBitrateBps: Int, reason: String)
    case probeUp(newBitrateBps: Int)
    case revertToStable(newBitrateBps: Int, lockedCeiling: Bool, reason: String)

    public var targetBitrateBps: Int? {
        switch self {
        case .hold:
            return nil
        case .stepDown(let bps, _), .probeUp(let bps), .revertToStable(let bps, _, _):
            return bps
        }
    }
}

/// Closed-loop adaptive bitrate controller for `automaticBitrate == true`.
///
/// Behavior:
/// - Evaluates network health every **1 second** and steps bitrate down immediately
///   whenever loss/jitter occurs until the stream stabilizes.
/// - Never ramps bitrate back up before at least **5 seconds** of consecutive clean
///   network operation (the interval WebRTC GCC uses between probes); after a failed
///   upward probe the wait grows to 20 s, then 40 s.
/// - If probing higher bitrate reproduces packet loss/jitter, immediately reverts to
///   the last problem-free bitrate and locks the learned ceiling if instability persists,
///   avoiding oscillation on penalized links.
public struct SPPWAdaptiveBitrateController: Sendable, Equatable {
    public static let defaultMinBitrateBps = 5_000_000
    public static let defaultMaxBitrateBps = 1_000_000_000
    public static let defaultEvaluationIntervalNanoseconds: UInt64 = 1_000_000_000
    public static let defaultMinimumRampUpCooldownNanoseconds: UInt64 = 5_000_000_000
    /// Shortest ramp-up wait the controller accepts.
    public static let minimumAllowedRampUpCooldownNanoseconds: UInt64 = 5_000_000_000
    /// Base of the wait after failed probes: 2× (20 s) after one, 4× (40 s) after two or more.
    public static let failedProbeBackoffBaseNanoseconds: UInt64 = 10_000_000_000
    public static let defaultProbeConfirmNanoseconds: UInt64 = 5_000_000_000

    public let minBitrateBps: Int
    public private(set) var maxCeilingBitrateBps: Int
    public private(set) var learnedSafeCeilingBps: Int
    public private(set) var currentBitrateBps: Int
    public private(set) var lastStableBitrateBps: Int?
    public private(set) var failedProbeCount: Int = 0
    public private(set) var isCeilingLocked: Bool = false
    /// "Prefer high quality": a single moderate window (partial HF, heavy FEC) no longer cuts
    /// the bitrate, cuts are smaller (−15 % / −5 % instead of −20 % / −10 %), and the climb back
    /// waits half as long after a failed probe (10 s / 20 s) and after a locked ceiling (15 s).
    /// Trades a few more glitches on a bad link for a sharper picture. Survives `reset`.
    public var prefersHighQuality = false

    public let evaluationIntervalNanoseconds: UInt64
    public let minimumRampUpCooldownNanoseconds: UInt64
    public let probeConfirmNanoseconds: UInt64

    private var lastEvaluationNanoseconds: UInt64 = 0
    private var lastChangeNanoseconds: UInt64 = 0
    private var cleanWindowStartNanoseconds: UInt64 = 0
    private var cleanSecondsSinceLastChange: Int = 0
    private var probingFromBitrateBps: Int?
    private var probeStartedAtNanoseconds: UInt64 = 0
    /// Timestamps of recent impaired windows (any loss, partial-HF, late drop, heavy FEC),
    /// used to tell persistent congestion from isolated Wi-Fi blips.
    private var recentImpairedWindowNanos: [UInt64] = []
    private var lockedSinceNanoseconds: UInt64 = 0

    /// A locked ceiling is released after this long without trouble at the locked bitrate,
    /// so a link that recovered (the user moved closer to the access point) can climb again.
    public static let ceilingLockReleaseNanoseconds: UInt64 = 30_000_000_000
    /// Impaired windows within this span (including the current one) count as persistent.
    public static let persistenceWindowNanoseconds: UInt64 = 3_000_000_000

    /// Computes the natural automatic bitrate ceiling matching the server's
    /// `width * height * 1.4 * quality` per-frame budget, rounded up to 1 Mb/s.
    public static func recommendedCeilingBitrateBps(
        width: Int,
        height: Int,
        fps: Int,
        quality: Double,
        minBitrateBps: Int = defaultMinBitrateBps,
        maxBitrateBps: Int = defaultMaxBitrateBps
    ) -> Int {
        let safeW = Double(max(width, 320))
        let safeH = Double(max(height, 240))
        let safeFPS = Double(min(max(fps, 1), 240))
        let safeQuality = min(max(quality, 0.01), 1.0)
        let rawBps = safeW * safeH * 1.4 * safeQuality * safeFPS
        let mbps = Int((rawBps / 1_000_000.0).rounded(.up))
        let quantized = mbps * 1_000_000
        return min(max(quantized, minBitrateBps), maxBitrateBps)
    }

    public init(
        ceilingBitrateBps: Int = 180_000_000,
        minBitrateBps: Int = defaultMinBitrateBps,
        evaluationIntervalNanoseconds: UInt64 = defaultEvaluationIntervalNanoseconds,
        minimumRampUpCooldownNanoseconds: UInt64 = defaultMinimumRampUpCooldownNanoseconds,
        probeConfirmNanoseconds: UInt64 = defaultProbeConfirmNanoseconds,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let floorBps = max(1_000_000, minBitrateBps)
        let clampedCeiling = min(max(ceilingBitrateBps, floorBps), Self.defaultMaxBitrateBps)
        self.minBitrateBps = floorBps
        self.maxCeilingBitrateBps = clampedCeiling
        self.learnedSafeCeilingBps = clampedCeiling
        self.currentBitrateBps = clampedCeiling
        self.evaluationIntervalNanoseconds = max(100_000_000, evaluationIntervalNanoseconds)
        self.minimumRampUpCooldownNanoseconds = max(Self.minimumAllowedRampUpCooldownNanoseconds, minimumRampUpCooldownNanoseconds)
        self.probeConfirmNanoseconds = probeConfirmNanoseconds
        self.lastEvaluationNanoseconds = nowNanoseconds
        self.lastChangeNanoseconds = nowNanoseconds
        self.cleanWindowStartNanoseconds = nowNanoseconds
    }

    public mutating func reset(
        ceilingBitrateBps: Int,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let clampedCeiling = min(max(ceilingBitrateBps, minBitrateBps), Self.defaultMaxBitrateBps)
        maxCeilingBitrateBps = clampedCeiling
        learnedSafeCeilingBps = clampedCeiling
        currentBitrateBps = clampedCeiling
        lastStableBitrateBps = nil
        failedProbeCount = 0
        isCeilingLocked = false
        lastEvaluationNanoseconds = nowNanoseconds
        lastChangeNanoseconds = nowNanoseconds
        cleanWindowStartNanoseconds = nowNanoseconds
        cleanSecondsSinceLastChange = 0
        probingFromBitrateBps = nil
        probeStartedAtNanoseconds = 0
        recentImpairedWindowNanos = []
        lockedSinceNanoseconds = 0
    }

    /// Evaluates a 1-second network health window and returns the bitrate adjustment.
    public mutating func evaluate(_ sample: SPPWAdaptiveBitrateSample) -> SPPWAdaptiveBitrateDecision {
        // Enforce at most one evaluation per 1-second interval.
        if lastEvaluationNanoseconds > 0,
           sample.timestampNanoseconds < lastEvaluationNanoseconds &+ evaluationIntervalNanoseconds {
            return .hold
        }
        lastEvaluationNanoseconds = sample.timestampNanoseconds

        let totalFrames = sample.completeFramesDelta + sample.llDroppedFramesDelta + sample.expiredFramesDelta
        // If no frames arrived during this window, stay put and do not advance clean cooldown.
        if totalFrames == 0 && sample.lateDroppedFramesDelta == 0 {
            cleanWindowStartNanoseconds = sample.timestampNanoseconds
            cleanSecondsSinceLastChange = 0
            return .hold
        }

        let fecRatio = totalFrames > 0
            ? Double(sample.fecRecoveredFramesDelta) / Double(totalFrames)
            : 0.0
        let frameBase = Double(max(totalFrames, 1))
        let lostFrames = sample.llDroppedFramesDelta + sample.expiredFramesDelta
        let lossRatio = Double(lostFrames) / frameBase
        let partialRatio = Double(sample.partialHFFramesDelta) / frameBase

        // Wi-Fi loses isolated packets and stalls for tens of milliseconds (retries, AWDL,
        // power save, scans) without being short of capacity. A bitrate cut only helps when the
        // link is congested, which shows up as heavy loss in one window or loss that persists.
        let isImpaired = lostFrames > 0
            || sample.partialHFFramesDelta > 0
            || sample.lateDroppedFramesDelta > 0
            || (totalFrames >= 10 && fecRatio > 0.20)
        recentImpairedWindowNanos.removeAll {
            sample.timestampNanoseconds &- $0 >= Self.persistenceWindowNanoseconds
        }
        if isImpaired {
            recentImpairedWindowNanos.append(sample.timestampNanoseconds)
        }
        let isPersistent = isImpaired && recentImpairedWindowNanos.count >= 2

        let heavyLoss = lossRatio >= 0.03 || sample.lateDroppedFramesDelta >= 3
        let heavyPartial = partialRatio >= 0.10 || (sample.jitterMs >= 25.0 && partialRatio >= 0.05)
        let lossInvolved = lostFrames > 0 || sample.lateDroppedFramesDelta >= 2

        let isSevere = heavyLoss || (isPersistent && lossInvolved)
        let isModerate = !isSevere && (
            (heavyPartial && (isPersistent || !prefersHighQuality))
                || (totalFrames >= 10 && fecRatio > 0.35 && (isPersistent || !prefersHighQuality))
                || (isPersistent && (sample.partialHFFramesDelta >= 2 || fecRatio > 0.20))
        )

        let isClean = !isImpaired
            && (sample.fecRecoveredFramesDelta == 0 || (totalFrames >= 20 && fecRatio < 0.05))
            && sample.jitterMs < 20.0

        if isSevere || isModerate {
            let reason = degradationReason(sample: sample, fecRatio: fecRatio)
            cleanWindowStartNanoseconds = sample.timestampNanoseconds
            cleanSecondsSinceLastChange = 0

            // If we were probing higher bitrate and the link degraded again,
            // immediately return to the last problem-free bitrate.
            if let stableBps = probingFromBitrateBps {
                probingFromBitrateBps = nil
                probeStartedAtNanoseconds = 0
                failedProbeCount += 1
                currentBitrateBps = stableBps
                lastStableBitrateBps = stableBps
                lastChangeNanoseconds = sample.timestampNanoseconds

                // After a repeated failure above this level, lock the ceiling
                // at the bitrate with fewer problems to stop oscillation.
                if failedProbeCount >= 2 {
                    learnedSafeCeilingBps = min(learnedSafeCeilingBps, stableBps)
                    isCeilingLocked = true
                    lockedSinceNanoseconds = sample.timestampNanoseconds
                }
                return .revertToStable(
                    newBitrateBps: stableBps,
                    lockedCeiling: isCeilingLocked,
                    reason: reason
                )
            }

            // Step down every 1 second until the network stabilizes.
            let factor = prefersHighQuality ? (isSevere ? 0.85 : 0.95) : (isSevere ? 0.80 : 0.90)
            let minStepBps = isSevere ? 2_000_000 : 1_000_000
            let scaled = Int((Double(currentBitrateBps) * factor).rounded(.down))
            let candidate = min(scaled, currentBitrateBps - minStepBps)
            let quantized = (candidate / 1_000_000) * 1_000_000
            let nextBps = max(minBitrateBps, quantized)

            guard nextBps < currentBitrateBps else {
                return .hold
            }

            currentBitrateBps = nextBps
            lastChangeNanoseconds = sample.timestampNanoseconds
            return .stepDown(newBitrateBps: nextBps, reason: reason)
        }

        if isClean {
            cleanSecondsSinceLastChange += 1

            // Confirm an active probe after sustained clean operation.
            if probingFromBitrateBps != nil,
               sample.timestampNanoseconds >= probeStartedAtNanoseconds &+ probeConfirmNanoseconds {
                probingFromBitrateBps = nil
                probeStartedAtNanoseconds = 0
                lastStableBitrateBps = currentBitrateBps
                failedProbeCount = 0
            } else if probingFromBitrateBps == nil && cleanSecondsSinceLastChange >= 3 {
                lastStableBitrateBps = currentBitrateBps
            }

            // Release a locked ceiling after a long clean stretch (conditions change on Wi-Fi);
            // the next probe still waits out the doubled backoff of one failed probe.
            let lockRelease = prefersHighQuality ? Self.ceilingLockReleaseNanoseconds / 2 : Self.ceilingLockReleaseNanoseconds
            if isCeilingLocked,
               sample.timestampNanoseconds &- max(cleanWindowStartNanoseconds, lockedSinceNanoseconds)
                   >= lockRelease {
                isCeilingLocked = false
                learnedSafeCeilingBps = maxCeilingBitrateBps
                failedProbeCount = 1
            }

            let effectiveCeiling = min(maxCeilingBitrateBps, learnedSafeCeilingBps)
            guard !isCeilingLocked, currentBitrateBps < effectiveCeiling else {
                return .hold
            }

            // Never ramp upward in less than 5 seconds; 20 s / 40 s after failed probes.
            let requiredCooldown: UInt64
            let backoffBase = prefersHighQuality ? Self.failedProbeBackoffBaseNanoseconds / 2 : Self.failedProbeBackoffBaseNanoseconds
            switch failedProbeCount {
            case 0: requiredCooldown = minimumRampUpCooldownNanoseconds
            case 1: requiredCooldown = max(minimumRampUpCooldownNanoseconds, backoffBase * 2)
            default: requiredCooldown = max(minimumRampUpCooldownNanoseconds, backoffBase * 4)
            }
            let cleanElapsed = sample.timestampNanoseconds >= cleanWindowStartNanoseconds
                ? (sample.timestampNanoseconds - cleanWindowStartNanoseconds)
                : 0
            let changeElapsed = sample.timestampNanoseconds >= lastChangeNanoseconds
                ? (sample.timestampNanoseconds - lastChangeNanoseconds)
                : 0

            guard cleanElapsed >= requiredCooldown, changeElapsed >= requiredCooldown else {
                return .hold
            }

            // Far below the ceiling (after cuts for a bad patch), climb back in bigger steps.
            let headroom = Double(currentBitrateBps) / Double(max(effectiveCeiling, 1))
            let growthFactor: Double
            if failedProbeCount > 0 {
                growthFactor = 1.05
            } else if headroom < 0.5 {
                growthFactor = 1.25
            } else if headroom < 0.8 {
                growthFactor = 1.15
            } else {
                growthFactor = 1.10
            }
            let minStepBps = failedProbeCount == 0 ? 2_000_000 : 1_000_000
            let grown = Int((Double(currentBitrateBps) * growthFactor).rounded(.up))
            let candidate = max(grown, currentBitrateBps + minStepBps)
            let quantized = ((candidate + 999_999) / 1_000_000) * 1_000_000
            let nextBps = min(effectiveCeiling, quantized)

            guard nextBps > currentBitrateBps else {
                return .hold
            }

            probingFromBitrateBps = currentBitrateBps
            probeStartedAtNanoseconds = sample.timestampNanoseconds
            currentBitrateBps = nextBps
            lastChangeNanoseconds = sample.timestampNanoseconds
            cleanSecondsSinceLastChange = 0
            return .probeUp(newBitrateBps: nextBps)
        }

        // Borderline second (minor FEC or single partial-HF): keep bitrate steady
        // and restart the 10-second clean timer so we do not probe upward prematurely.
        cleanWindowStartNanoseconds = sample.timestampNanoseconds
        cleanSecondsSinceLastChange = 0
        return .hold
    }

    private func degradationReason(sample: SPPWAdaptiveBitrateSample, fecRatio: Double) -> String {
        if sample.llDroppedFramesDelta > 0 {
            return "LL drop: \(sample.llDroppedFramesDelta)"
        }
        if sample.expiredFramesDelta > 0 {
            return "expired: \(sample.expiredFramesDelta)"
        }
        if sample.lateDroppedFramesDelta >= 2 {
            return "late drop: \(sample.lateDroppedFramesDelta)"
        }
        if sample.partialHFFramesDelta >= 2 {
            return "partial HF: \(sample.partialHFFramesDelta)"
        }
        if fecRatio > 0.20 {
            return String(format: "FEC %.0f%%", fecRatio * 100.0)
        }
        return String(format: "jitter %.1f ms", sample.jitterMs)
    }
}

// MARK: - Video Orientation & Localization Support

/// Client-side and stream-request video orientation state (cyclic 90° clockwise rotation + horizontal flip).
/// When transitioning between landscape (`0°` / `180°`) and portrait (`90°` / `270°`),
/// `swapsDimensions` toggles so the receiver automatically swaps `(width, height)`
/// (e.g. `1920x1080` <-> `1080x1920`) and renegotiates the stream request with the server.
public struct SPPWVideoOrientation: Codable, Equatable, Sendable {
    /// Quarter turns clockwise: `0` (0°), `1` (90° CW), `2` (180°), `3` (270° CW).
    public var quarterTurnsClockwise: Int = 0 {
        didSet {
            quarterTurnsClockwise = ((quarterTurnsClockwise % 4) + 4) % 4
        }
    }
    public var isFlippedHorizontally: Bool = false

    public init(
        quarterTurnsClockwise: Int = 0,
        isFlippedHorizontally: Bool = false
    ) {
        self.quarterTurnsClockwise = ((quarterTurnsClockwise % 4) + 4) % 4
        self.isFlippedHorizontally = isFlippedHorizontally
    }

    /// True when the video is rotated by 90° or 270°, requiring width and height to be swapped.
    public var swapsDimensions: Bool {
        (quarterTurnsClockwise % 2) != 0
    }

    public var degreesClockwise: Int {
        quarterTurnsClockwise * 90
    }

    public var isIdentity: Bool {
        quarterTurnsClockwise == 0 && !isFlippedHorizontally
    }

    public var rotationAngleRadians: Double {
        Double(quarterTurnsClockwise) * (.pi / 2.0)
    }

    public var scaleX: Double {
        isFlippedHorizontally ? -1.0 : 1.0
    }

    public var scaleY: Double {
        1.0
    }

    /// Rotates 90° clockwise cyclically (0° -> 90° -> 180° -> 270° -> 0°).
    /// Returns `true` if `swapsDimensions` changed.
    @discardableResult
    public mutating func rotate() -> Bool {
        let wasSwapped = swapsDimensions
        quarterTurnsClockwise = (quarterTurnsClockwise + 1) % 4
        return swapsDimensions != wasSwapped
    }

    /// Toggles horizontal mirror flip.
    public mutating func toggleFlip() {
        isFlippedHorizontally.toggle()
    }

    public var summaryLabel: String {
        var parts: [String] = ["\(degreesClockwise)°"]
        if isFlippedHorizontally { parts.append(SPPWLocalization.tr("orientation.flip")) }
        return parts.joined(separator: " · ")
    }
}

/// Supported localization languages across macOS and iOS (`Localizable.xcstrings`).
public enum SPPWAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case italian = "it"
    case english = "en"
    case chinese = "zh-Hans"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case spanish = "es"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return SPPWLocalization.tr("lang.system")
        case .italian: return "Italiano (it)"
        case .english: return "English (en)"
        case .chinese: return "简体中文 (zh-Hans)"
        case .french: return "Français (fr)"
        case .german: return "Deutsch (de)"
        case .japanese: return "日本語 (ja)"
        case .spanish: return "Español (es)"
        }
    }
}

/// Lightweight cross-platform localization helper backed by `Localizable.xcstrings` and an embedded dictionary
/// for the 7 required languages: Italian (`it`), Chinese (`zh` / `zh-Hans`), English (`en`), French (`fr`),
/// German (`de`), Japanese (`ja`), and Spanish (`es`).
// MARK: - Resolution ladder (client-chosen scaling)

/// Stream sizes derived from the server's native size by *short side* ("p" = lines on the
/// shorter dimension), so every level keeps the server screen's aspect ratio — 16:9, 16:10,
/// iPhone, iPad, landscape or portrait — and is never larger than native.
///
/// Wire semantics of `ClientConfiguration.width/height`:
/// - `0 × 0`: native (server screen size; 1920×1080 for generated test content);
/// - `0 × S`: short side `S`, long side from the server's aspect ratio;
/// - `W × H`: fit inside `W × H` keeping the server's aspect ratio (legacy explicit sizes).
public enum SPPWResolutionLadder {
    /// Levels offered to the user, high to low.
    public static let shortSides: [Int] = [2160, 1440, 1080, 720, 480, 360, 320]
    public static let maximumWidth = 3840
    public static let maximumHeight = 2160

    /// Nearest even value, at least 2.
    public static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    /// Size whose short side is `shortSide`, with `native`'s aspect ratio; native when the
    /// level is not below the native short side.
    public static func size(shortSide: Int, native: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let nativeWidth = max(native.width, 2)
        let nativeHeight = max(native.height, 2)
        let nativeShort = min(nativeWidth, nativeHeight)
        guard shortSide > 0, shortSide < nativeShort else { return (nativeWidth, nativeHeight) }
        let scale = Double(shortSide) / Double(nativeShort)
        if nativeWidth >= nativeHeight {
            return (even(Double(nativeWidth) * scale), even(Double(shortSide)))
        }
        return (even(Double(shortSide)), even(Double(nativeHeight) * scale))
    }

    /// Resolves a client request against the server's native size (see type docs).
    public static func resolve(
        requestedWidth: Int,
        requestedHeight: Int,
        native: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        if requestedWidth <= 0 && requestedHeight <= 0 {
            return (max(native.width, 2), max(native.height, 2))
        }
        if requestedWidth <= 0 {
            return size(shortSide: requestedHeight, native: native)
        }
        let nativeWidth = Double(max(native.width, 2))
        let nativeHeight = Double(max(native.height, 2))
        var scale = min(1, Double(requestedWidth) / nativeWidth)
        if requestedHeight > 0 {
            scale = min(scale, Double(requestedHeight) / nativeHeight)
        }
        return (even(nativeWidth * scale), even(nativeHeight * scale))
    }

    /// The ladder levels strictly below the native short side.
    public static func availableShortSides(nativeShortSide: Int?) -> [Int] {
        guard let nativeShortSide, nativeShortSide > 0 else { return shortSides }
        return shortSides.filter { $0 < nativeShortSide }
    }
}

/// The receiver's resolution choice.
public enum SPPWResolutionMode: Hashable, Sendable, Identifiable {
    /// Server's native size.
    case native
    /// Chosen automatically from the adaptive bitrate (`SPPWAutoResolutionController`).
    case automatic
    /// Fixed short side from `SPPWResolutionLadder.shortSides`.
    case shortSide(Int)

    /// Stable string for persistence.
    public var id: String {
        switch self {
        case .native: "native"
        case .automatic: "auto"
        case .shortSide(let lines): "short:\(lines)"
        }
    }

    public init(id: String) {
        switch id {
        case "auto": self = .automatic
        case let value where value.hasPrefix("short:"):
            let lines = Int(value.dropFirst("short:".count)) ?? 0
            self = SPPWResolutionLadder.shortSides.contains(lines) ? .shortSide(lines) : .native
        default: self = .native
        }
    }

    public var title: String {
        switch self {
        case .native: SPPWLocalization.tr("settings.resolution_native")
        case .automatic: SPPWLocalization.tr("settings.resolution_auto")
        case .shortSide(let lines): Self.levelTitle(lines)
        }
    }

    /// `title` in English, for the log console.
    public var englishTitle: String {
        switch self {
        case .native: SPPWLocalization.english("settings.resolution_native")
        case .automatic: SPPWLocalization.english("settings.resolution_auto")
        case .shortSide(let lines): Self.levelTitle(lines)
        }
    }

    public static func levelTitle(_ lines: Int) -> String {
        switch lines {
        case 2160: "4K (2160p)"
        case 1440: "2K (1440p)"
        default: "\(lines)p"
        }
    }

    /// Menu entries: native, automatic, then the levels below the native short side
    /// (all levels while the native size is unknown).
    public static func menuOptions(nativeShortSide: Int?) -> [SPPWResolutionMode] {
        [.native, .automatic] + SPPWResolutionLadder.availableShortSides(nativeShortSide: nativeShortSide).map { .shortSide($0) }
    }
}

/// Picks the resolution level for `SPPWResolutionMode.automatic` from the adaptive bitrate.
///
/// The adaptive bitrate is capped at the current level's ceiling, so the signals are relative
/// to that ceiling: a link that keeps the bitrate below `stepDownBelowRatio` of it for
/// `stepDownHold` cannot carry the level (step down); one that holds it at the ceiling for
/// the step-up hold has room (try one level up). A step-up that fails within
/// `failedProbeWindow` doubles the step-up hold (up to `maximumStepUpHold`), so a link at its
/// limit does not oscillate.
public struct SPPWAutoResolutionController: Sendable {
    public enum Change: Equatable, Sendable {
        case none
        /// New short side, `nil` = native.
        case changed(Int?)
    }

    public var stepDownBelowRatio = 0.5
    public var stepDownHoldNanos: UInt64 = 3_000_000_000
    public var stepUpAtRatio = 0.95
    public var baseStepUpHoldNanos: UInt64 = 15_000_000_000
    public var maximumStepUpHoldNanos: UInt64 = 120_000_000_000
    public var failedProbeWindowNanos: UInt64 = 20_000_000_000

    /// "Prefer high quality": step down only below 35 % of the ceiling held for 6 s, and try the
    /// next level up after 8 s at the ceiling (instead of 50 % / 3 s and 15 s). Survives `reset`.
    public var prefersHighQuality = false

    /// Current level, `nil` = native.
    public private(set) var shortSide: Int?
    private var belowSince: UInt64?
    private var atCeilingSince: UInt64?
    private var lastStepUpNanos: UInt64?
    private var stepUpHoldNanos: UInt64

    public init(shortSide: Int? = nil) {
        self.shortSide = shortSide
        self.stepUpHoldNanos = 15_000_000_000
    }

    public mutating func reset(shortSide: Int? = nil) {
        let prefersHighQuality = self.prefersHighQuality
        self = SPPWAutoResolutionController(shortSide: shortSide)
        self.prefersHighQuality = prefersHighQuality
    }

    /// Levels from highest (native, `nil`) to lowest.
    private static func levels(nativeShortSide: Int) -> [Int?] {
        [nil] + SPPWResolutionLadder.availableShortSides(nativeShortSide: nativeShortSide).map { Optional($0) }
    }

    public mutating func evaluate(
        currentBitrateBps: Int,
        ceilingBitrateBps: Int,
        nativeShortSide: Int,
        now: UInt64
    ) -> Change {
        let levels = Self.levels(nativeShortSide: nativeShortSide)
        let index = levels.firstIndex(where: { $0 == shortSide }) ?? 0
        let ratio = ceilingBitrateBps > 0 ? Double(currentBitrateBps) / Double(ceilingBitrateBps) : 1

        let baseHold = prefersHighQuality ? min(baseStepUpHoldNanos, 8_000_000_000) : baseStepUpHoldNanos
        if let lastUp = lastStepUpNanos, now &- lastUp > 60_000_000_000 {
            // Held the higher level for a minute: the probe succeeded.
            stepUpHoldNanos = baseHold
            lastStepUpNanos = nil
        }
        let downRatio = prefersHighQuality ? min(stepDownBelowRatio, 0.35) : stepDownBelowRatio
        let downHold = prefersHighQuality ? max(stepDownHoldNanos, 6_000_000_000) : stepDownHoldNanos
        let upHold = prefersHighQuality ? min(stepUpHoldNanos, max(baseHold, stepUpHoldNanos / 2)) : stepUpHoldNanos

        if ratio < downRatio {
            atCeilingSince = nil
            let since = belowSince ?? now
            belowSince = since
            if now &- since >= downHold, index + 1 < levels.count {
                if let lastUp = lastStepUpNanos, now &- lastUp < failedProbeWindowNanos {
                    stepUpHoldNanos = min(stepUpHoldNanos * 2, maximumStepUpHoldNanos)
                }
                lastStepUpNanos = nil
                belowSince = nil
                shortSide = levels[index + 1]
                return .changed(shortSide)
            }
            return .none
        }
        belowSince = nil

        if ratio >= stepUpAtRatio {
            let since = atCeilingSince ?? now
            atCeilingSince = since
            if now &- since >= upHold, index > 0 {
                atCeilingSince = nil
                lastStepUpNanos = now
                shortSide = levels[index - 1]
                return .changed(shortSide)
            }
            return .none
        }
        atCeilingSince = nil
        return .none
    }

    /// Fixed (manual) bitrate: the highest level whose bitrate ceiling fits it.
    public static func bestShortSide(
        bitrateBps: Int,
        fps: Int,
        quality: Double,
        native: (width: Int, height: Int)
    ) -> Int? {
        let nativeShort = min(native.width, native.height)
        for level in levels(nativeShortSide: nativeShort) {
            let size = level.map { SPPWResolutionLadder.size(shortSide: $0, native: native) } ?? native
            let ceiling = SPPWAdaptiveBitrateController.recommendedCeilingBitrateBps(
                width: size.width, height: size.height, fps: fps, quality: quality
            )
            if ceiling <= bitrateBps { return level }
        }
        return SPPWResolutionLadder.availableShortSides(nativeShortSide: nativeShort).last
    }
}

// MARK: - Keep streaming processes responsive

/// Process activity assertion held while a server streams or a receiver is connected.
///
/// Without it macOS puts a hidden/occluded app into App Nap after a while: timers are
/// coalesced and threads throttled, which stalls packet pacing, capture and the UDP loop —
/// the stream "stops after some time in the background". `latencyCritical` keeps timer
/// precision, `userInitiated` prevents App Nap and idle system sleep, and
/// `keepDisplayAwake` also stops the display from sleeping (a sleeping or locked display
/// makes ScreenCaptureKit stop delivering frames).
/// On iOS the assertion does not prevent suspension; the apps additionally disable the idle
/// timer (auto-lock) while streaming.
public final class SPPWStreamingActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    /// Idempotent; calling again with a different `keepDisplayAwake` replaces the assertion.
    public func begin(keepDisplayAwake: Bool) {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical]
        if keepDisplayAwake {
            options.insert(.idleDisplaySleepDisabled)
        }
        let newToken = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        lock.lock()
        let previous = token
        token = newToken
        lock.unlock()
        if let previous {
            ProcessInfo.processInfo.endActivity(previous)
        }
    }

    public func end() {
        lock.lock()
        let previous = token
        token = nil
        lock.unlock()
        if let previous {
            ProcessInfo.processInfo.endActivity(previous)
        }
    }

    deinit {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}

/// Retry delay for automatically restarting a capture source that stopped on its own:
/// 1, 2, 4, 8 s, then every 10 s.
public enum SPPWSourceRestartPolicy {
    public static func delayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(10, 1 << min(max(attempt, 0), 4))
        return UInt64(seconds) * 1_000_000_000
    }

    /// A source that ran at least this long before stopping resets the backoff.
    public static let healthyRunNanoseconds: UInt64 = 10_000_000_000
}

/// Keeps a still screen streaming and tells a still screen apart from a stuck capture.
///
/// ScreenCaptureKit drops unchanged frames (`SCFrameStatus.idle`), so a static desktop
/// sends nothing. Without a refresh, receivers saw no frame for 2 s, asked for a resync,
/// cleared to black and made the server restart the whole capture, which is slow at
/// high resolutions. The server now resends the last encoded frame while the screen is
/// still and restarts the capture only when it really looks dead.
public enum SPPWStillScreenPolicy {
    /// Resend the last frame after this long without a new one (well inside the
    /// receivers' 2 s fresh-frame watchdog).
    public static let refreshIntervalNanoseconds: UInt64 = 1_000_000_000

    /// Capture silent this long counts as possibly stuck when a receiver asks for a resync.
    public static let resyncSilenceNanoseconds: UInt64 = 3_000_000_000

    /// Capture silent this long while the user clicks, types or scrolls counts as stuck.
    public static let interactionStallNanoseconds: UInt64 = 8_000_000_000

    /// Only input within this window counts as "the user is interacting".
    public static let recentInteractionNanoseconds: UInt64 = 3_000_000_000

    /// Minimum time between two stall-driven capture restarts.
    public static let minimumRestartSpacingNanoseconds: UInt64 = 15_000_000_000

    public static func shouldRefresh(nowNanoseconds now: UInt64, lastSentNanoseconds last: UInt64) -> Bool {
        last > 0 && now >= last && now - last >= refreshIntervalNanoseconds
    }

    /// A resync restarts the source only when the stream geometry or rate changed, the
    /// source is not running, or the capture has been silent long enough to look stuck.
    /// Otherwise the server just resends its last frame: PyroWave frames are all intra,
    /// so any frame is a full picture.
    public static func resyncNeedsSourceRestart(
        geometryOrRateChanged: Bool,
        sourceRunning: Bool,
        captureSilenceNanoseconds: UInt64?
    ) -> Bool {
        if geometryOrRateChanged || !sourceRunning { return true }
        guard let silence = captureSilenceNanoseconds else { return false }
        return silence >= resyncSilenceNanoseconds
    }

    /// True when the capture produced nothing for a long time although the user is
    /// actively clicking, typing or scrolling, and no stall restart happened recently.
    public static func isStalledWhileInteracting(
        captureSilenceNanoseconds silence: UInt64,
        sinceLastInteractionNanoseconds sinceInteraction: UInt64?,
        sinceLastStallRestartNanoseconds sinceRestart: UInt64?
    ) -> Bool {
        guard silence >= interactionStallNanoseconds,
              let sinceInteraction, sinceInteraction <= recentInteractionNanoseconds else { return false }
        if let sinceRestart, sinceRestart < minimumRestartSpacingNanoseconds { return false }
        return true
    }
}

public enum SPPWLocalization {
    public static let languageDefaultsKey = "sppwPreferredAppLanguage"
    public static let didChangeLanguageNotification = Notification.Name("SPPWLocalizationDidChangeLanguageNotification")

    public static var selectedLanguage: SPPWAppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: languageDefaultsKey) ?? SPPWAppLanguage.system.rawValue
            return SPPWAppLanguage(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageDefaultsKey)
            NotificationCenter.default.post(name: didChangeLanguageNotification, object: newValue)
        }
    }

    public static var currentLanguageCode: String {
        if let saved = UserDefaults.standard.string(forKey: languageDefaultsKey),
           saved != SPPWAppLanguage.system.rawValue,
           !saved.isEmpty {
            return normalize(saved)
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return normalize(preferred)
    }

    private static func normalize(_ code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("it") { return "it" }
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("fr") { return "fr" }
        if lower.hasPrefix("de") { return "de" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("es") { return "es" }
        return "en"
    }

    public static func tr(_ key: String) -> String {
        let lang = currentLanguageCode
        if let table = translations[key], let localized = table[lang] {
            return localized
        }
        return translations[key]?["en"] ?? NSLocalizedString(key, comment: "")
    }

    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, arguments: args)
    }

    /// English text of `key`, whatever the app language. Log console messages always use it:
    /// logs stay identical on every device and can be pasted into bug reports as they are.
    public static func english(_ key: String) -> String {
        translations[key]?["en"] ?? key
    }

    public static func english(_ key: String, _ args: CVarArg...) -> String {
        String(format: english(key), locale: Locale(identifier: "en_US_POSIX"), arguments: args)
    }

    public static let translations: [String: [String: String]] = [
        "remote.title": [
            "it": "Controllo remoto", "en": "Remote control", "zh": "远程控制", "fr": "Contrôle à distance", "de": "Fernsteuerung", "ja": "リモート操作", "es": "Control remoto"
        ],
        "remote.touch_mode": [
            "it": "Modalità tocco", "en": "Touch mode", "zh": "触控模式", "fr": "Mode tactile", "de": "Touch-Modus", "ja": "タッチモード", "es": "Modo táctil"
        ],
        "remote.mode.trackpad": [
            "it": "Trackpad", "en": "Trackpad", "zh": "触控板", "fr": "Trackpad", "de": "Trackpad", "ja": "トラックパッド", "es": "Trackpad"
        ],
        "remote.mode.direct": [
            "it": "Tocco diretto", "en": "Direct touch", "zh": "直接触控", "fr": "Toucher direct", "de": "Direkte Berührung", "ja": "ダイレクトタッチ", "es": "Toque directo"
        ],
        "remote.pointer_speed": [
            "it": "Velocità puntatore", "en": "Pointer speed", "zh": "指针速度", "fr": "Vitesse du pointeur", "de": "Zeigergeschwindigkeit", "ja": "ポインタの速度", "es": "Velocidad del puntero"
        ],
        "remote.natural_scroll": [
            "it": "Scorrimento naturale", "en": "Natural scrolling", "zh": "自然滚动", "fr": "Défilement naturel", "de": "Natürliches Scrollen", "ja": "ナチュラルスクロール", "es": "Desplazamiento natural"
        ],
        "remote.clipboard_sync": [
            "it": "Sincronizza appunti", "en": "Sync clipboard", "zh": "同步剪贴板", "fr": "Synchroniser le presse-papiers", "de": "Zwischenablage synchronisieren", "ja": "クリップボードを同期", "es": "Sincronizar portapapeles"
        ],
        "remote.clipboard_footer": [
            "it": "Mac → iPhone automatico. iPhone → Mac: ogni nuova copia viene inviata quando torni nell'app (iOS chiede ogni volta \"Consenti incolla\", per sicurezza). Testo, immagini e file da File (i grandi in background). Serve il controllo remoto attivo sul Mac.", "en": "Mac → iPhone is automatic. iPhone → Mac: every new copy is sent when you return to the app (iOS asks \"Allow Paste\" each time, for security). Text, images and files from Files (large ones in the background). Needs remote control on the Mac.", "zh": "Mac → iPhone 自动同步。iPhone → Mac：每次新的复制会在你回到 App 时发送（出于安全，iOS 每次都会询问“允许粘贴”）。支持文本、图片和“文件”中的文件（大文件在后台传输）。需要在 Mac 上开启远程控制。", "fr": "Mac → iPhone automatique. iPhone → Mac : chaque nouvelle copie est envoyée quand vous revenez dans l'app (iOS demande « Autoriser le collage » à chaque fois, par sécurité). Texte, images et fichiers de Fichiers (les gros en arrière-plan). Nécessite le contrôle à distance sur le Mac.", "de": "Mac → iPhone automatisch. iPhone → Mac: Jede neue Kopie wird gesendet, wenn du zur App zurückkehrst (iOS fragt aus Sicherheitsgründen jedes Mal „Einsetzen erlauben“). Text, Bilder und Dateien aus „Dateien“ (große im Hintergrund). Fernsteuerung auf dem Mac nötig.", "ja": "Mac → iPhone は自動。iPhone → Mac：新しくコピーした内容はアプリに戻ったときに送信されます（安全のため iOS が毎回「ペーストを許可」を確認します）。テキスト、画像、「ファイル」のファイル（大きいものはバックグラウンド）。Mac でリモート操作を有効にしてください。", "es": "Mac → iPhone es automático. iPhone → Mac: cada copia nueva se envía al volver a la app (iOS pregunta «Permitir pegar» cada vez, por seguridad). Texto, imágenes y archivos de Archivos (los grandes en segundo plano). Requiere el control remoto activo en el Mac."
        ],
        "remote.clipboard_auto_send": [
            "it": "Invia le copie dell'iPhone in automatico", "en": "Send iPhone copies automatically", "zh": "自动发送 iPhone 上的复制内容", "fr": "Envoyer automatiquement les copies de l'iPhone", "de": "Kopien des iPhone automatisch senden", "ja": "iPhone のコピーを自動送信", "es": "Enviar las copias del iPhone automáticamente"
        ],
        "remote.hint.trackpad": [
            "it": "1 dito muove · tocco clic · 2 dita scorrono · tocco a 2 dita clic destro · tieni premuto e trascina", "en": "1 finger moves · tap clicks · 2 fingers scroll · 2-finger tap right-clicks · press and hold to drag", "zh": "单指移动 · 轻点点击 · 双指滚动 · 双指轻点右键 · 按住拖移", "fr": "1 doigt déplace · toucher clique · 2 doigts défilent · toucher à 2 doigts clic droit · maintenir pour glisser", "de": "1 Finger bewegt · Tippen klickt · 2 Finger scrollen · Tippen mit 2 Fingern Rechtsklick · gedrückt halten zum Ziehen", "ja": "1本指で移動 · タップでクリック · 2本指でスクロール · 2本指タップで右クリック · 長押しでドラッグ", "es": "1 dedo mueve · toque hace clic · 2 dedos desplazan · toque con 2 dedos clic derecho · mantén pulsado para arrastrar"
        ],
        "remote.hint.direct": [
            "it": "Il dito è il puntatore · tocca per cliccare · trascina per spostare", "en": "Your finger is the pointer · tap to click · drag to move", "zh": "手指即指针 · 轻点点击 · 拖动移动", "fr": "Votre doigt est le pointeur · toucher pour cliquer · glisser pour déplacer", "de": "Der Finger ist der Zeiger · Tippen zum Klicken · Ziehen zum Bewegen", "ja": "指がポインタ · タップでクリック · ドラッグで移動", "es": "Tu dedo es el puntero · toca para hacer clic · arrastra para mover"
        ],
        "remote.dock.mode": [
            "it": "Modalità tocco", "en": "Touch mode", "zh": "触控模式", "fr": "Mode tactile", "de": "Touch-Modus", "ja": "タッチモード", "es": "Modo táctil"
        ],
        "receiver.controls_puck_help": [
            "it": "Controlli dello stream · clic per aprirli, trascina per spostare", "en": "Stream controls · click to open, drag to move", "zh": "串流控制 · 点击打开，拖动移动",
            "fr": "Commandes du flux · cliquer pour ouvrir, glisser pour déplacer", "de": "Stream-Steuerung · klicken zum Öffnen, ziehen zum Verschieben", "ja": "ストリームの操作 · クリックで開く、ドラッグで移動", "es": "Controles del stream · haz clic para abrir, arrastra para mover"
        ],
        "keyboard.dismiss": [
            "it": "Chiudi tastiera", "en": "Hide keyboard", "zh": "收起键盘",
            "fr": "Masquer le clavier", "de": "Tastatur ausblenden", "ja": "キーボードを閉じる", "es": "Ocultar teclado",
        ],
        "remote.dock.keyboard": [
            "it": "Tastiera", "en": "Keyboard", "zh": "键盘", "fr": "Clavier", "de": "Tastatur", "ja": "キーボード", "es": "Teclado"
        ],
        "remote.dock.special_keys": [
            "it": "Tasti speciali", "en": "Special keys", "zh": "特殊键", "fr": "Touches spéciales", "de": "Sondertasten", "ja": "特殊キー", "es": "Teclas especiales"
        ],
        "remote.dock.right_click": [
            "it": "Prossimo tocco: clic destro", "en": "Next tap: right click", "zh": "下次轻点：右键", "fr": "Prochain toucher : clic droit", "de": "Nächstes Tippen: Rechtsklick", "ja": "次のタップ：右クリック", "es": "Siguiente toque: clic derecho"
        ],
        "remote.dock.hide": [
            "it": "Nascondi controlli", "en": "Hide controls", "zh": "隐藏控制", "fr": "Masquer les commandes", "de": "Steuerung ausblenden", "ja": "コントロールを隠す", "es": "Ocultar controles"
        ],
        "remote.dock.show": [
            "it": "Mostra controlli", "en": "Show controls", "zh": "显示控制", "fr": "Afficher les commandes", "de": "Steuerung einblenden", "ja": "コントロールを表示", "es": "Mostrar controles"
        ],
        "remote.keys.function": [
            "it": "Tasti funzione", "en": "Function keys", "zh": "功能键", "fr": "Touches de fonction", "de": "Funktionstasten", "ja": "ファンクションキー", "es": "Teclas de función"
        ],
        "remote.keys.shortcuts": [
            "it": "Scorciatoie", "en": "Shortcuts", "zh": "快捷键", "fr": "Raccourcis", "de": "Kurzbefehle", "ja": "ショートカット", "es": "Atajos"
        ],
        "remote.keys.editing": [
            "it": "Modifica e navigazione", "en": "Editing and navigation", "zh": "编辑与导航", "fr": "Édition et navigation", "de": "Bearbeiten und Navigation", "ja": "編集とナビゲーション", "es": "Edición y navegación"
        ],
        "key.cut": [
            "it": "Taglia", "en": "Cut", "zh": "剪切", "fr": "Couper", "de": "Ausschneiden", "ja": "カット", "es": "Cortar"
        ],
        "key.copy": [
            "it": "Copia", "en": "Copy", "zh": "拷贝", "fr": "Copier", "de": "Kopieren", "ja": "コピー", "es": "Copiar"
        ],
        "key.paste": [
            "it": "Incolla", "en": "Paste", "zh": "粘贴", "fr": "Coller", "de": "Einsetzen", "ja": "ペースト", "es": "Pegar"
        ],
        "key.select_all": [
            "it": "Seleziona tutto", "en": "Select all", "zh": "全选", "fr": "Tout sélectionner", "de": "Alles auswählen", "ja": "すべてを選択", "es": "Seleccionar todo"
        ],
        "key.undo": [
            "it": "Annulla", "en": "Undo", "zh": "撤销", "fr": "Annuler", "de": "Widerrufen", "ja": "取り消す", "es": "Deshacer"
        ],
        "key.redo": [
            "it": "Ripristina", "en": "Redo", "zh": "重做", "fr": "Rétablir", "de": "Wiederholen", "ja": "やり直す", "es": "Rehacer"
        ],
        "key.spotlight": [
            "it": "Spotlight", "en": "Spotlight", "zh": "聚焦搜索", "fr": "Spotlight", "de": "Spotlight", "ja": "Spotlight", "es": "Spotlight"
        ],
        "key.app_switcher": [
            "it": "Cambia app", "en": "Switch apps", "zh": "切换应用", "fr": "Changer d’app", "de": "App wechseln", "ja": "アプリを切り替え", "es": "Cambiar de app"
        ],
        "key.minimize": [
            "it": "Riduci a icona", "en": "Minimize", "zh": "最小化", "fr": "Placer dans le Dock", "de": "Im Dock ablegen", "ja": "しまう", "es": "Minimizar"
        ],
        "key.close_window": [
            "it": "Chiudi finestra", "en": "Close window", "zh": "关闭窗口", "fr": "Fermer la fenêtre", "de": "Fenster schließen", "ja": "ウインドウを閉じる", "es": "Cerrar ventana"
        ],
        "key.quit": [
            "it": "Esci dall’app", "en": "Quit app", "zh": "退出应用", "fr": "Quitter l’app", "de": "App beenden", "ja": "アプリを終了", "es": "Salir de la app"
        ],
        "key.mission_control": [
            "it": "Mission Control", "en": "Mission Control", "zh": "调度中心", "fr": "Mission Control", "de": "Mission Control", "ja": "Mission Control", "es": "Mission Control"
        ],
        "key.show_desktop": [
            "it": "Mostra scrivania", "en": "Show desktop", "zh": "显示桌面", "fr": "Afficher le bureau", "de": "Schreibtisch anzeigen", "ja": "デスクトップを表示", "es": "Mostrar escritorio"
        ],
        "key.forward_delete": [
            "it": "Cancella avanti", "en": "Forward delete", "zh": "向前删除", "fr": "Supprimer vers la droite", "de": "Vorwärts löschen", "ja": "前方削除", "es": "Suprimir hacia delante"
        ],
        "action.apply_resync": [
            "it": "Applica e risincronizza", "en": "Apply and resync", "zh": "应用并重新同步",
            "fr": "Appliquer et resynchroniser", "de": "Anwenden & synchronisieren", "ja": "適用して再同期", "es": "Aplicar y resincronizar"
        ],
        "action.cancel": [
            "it": "Annulla", "en": "Cancel", "zh": "取消",
            "fr": "Annuler", "de": "Abbrechen", "ja": "キャンセル", "es": "Cancelar"
        ],
        "action.choose": [
            "it": "Scegli…", "en": "Choose…", "zh": "选择…",
            "fr": "Choisir…", "de": "Auswählen…", "ja": "選択…", "es": "Elegir…"
        ],
        "action.clear": [
            "it": "Cancella", "en": "Clear", "zh": "清除",
            "fr": "Effacer", "de": "Löschen", "ja": "クリア", "es": "Limpiar"
        ],
        "action.clear_log": [
            "it": "Pulisci registro", "en": "Clear log", "zh": "清空日志",
            "fr": "Effacer le journal", "de": "Protokoll löschen", "ja": "ログを消去", "es": "Borrar registro"
        ],
        "action.connect": [
            "it": "Connetti", "en": "Connect", "zh": "连接",
            "fr": "Connecter", "de": "Verbinden", "ja": "接続", "es": "Conectar"
        ],
        "action.disconnect": [
            "it": "Disconnetti", "en": "Disconnect", "zh": "断开连接",
            "fr": "Déconnecter", "de": "Trennen", "ja": "切断", "es": "Desconectar"
        ],
        "action.exit_fullscreen": [
            "it": "Esci", "en": "Exit", "zh": "退出",
            "fr": "Quitter", "de": "Beenden", "ja": "終了", "es": "Salir"
        ],
        "action.exit_fullscreen_help": [
            "it": "Esci da schermo intero (Esc)", "en": "Exit Full Screen (Esc)", "zh": "退出全屏 (Esc)",
            "fr": "Quitter le plein écran (Échap)", "de": "Vollbild beenden (Esc)", "ja": "フルスクリーン終了 (Esc)", "es": "Salir de pantalla completa (Esc)"
        ],
        "receiver.fullscreen_exit_help": [
            "it": "Esci da schermo intero (⌃⌥: premi e rilascia Control+Opzione)", "en": "Exit Full Screen (⌃⌥: press and release Control+Option)", "zh": "退出全屏（⌃⌥：按下并松开 Control+Option）",
            "fr": "Quitter le plein écran (⌃⌥ : appuyez puis relâchez Contrôle+Option)", "de": "Vollbild beenden (⌃⌥: Control+Wahl drücken und loslassen)", "ja": "フルスクリーン終了（⌃⌥：Control+Option を押して離す）", "es": "Salir de pantalla completa (⌃⌥: pulsa y suelta Control+Opción)"
        ],
        "receiver.fullscreen_exit_hint": [
            "it": "Premi e rilascia ⌃⌥ per uscire dallo schermo intero", "en": "Press and release ⌃⌥ to exit full screen", "zh": "按下并松开 ⌃⌥ 退出全屏",
            "fr": "Appuyez puis relâchez ⌃⌥ pour quitter le plein écran", "de": "⌃⌥ drücken und loslassen, um das Vollbild zu beenden", "ja": "⌃⌥ を押して離すとフルスクリーンを終了します", "es": "Pulsa y suelta ⌃⌥ para salir de pantalla completa"
        ],
        "zoom.in_help": [
            "it": "Ingrandisci (fino a 2×, ⌘+, pizzico sul trackpad)", "en": "Zoom in (up to 2×, ⌘+, trackpad pinch)", "zh": "放大（最高 2×，⌘+，触控板捏合）",
            "fr": "Agrandir (jusqu'à 2×, ⌘+, pincement trackpad)", "de": "Vergrößern (bis 2×, ⌘+, Trackpad-Zoomgeste)", "ja": "拡大（最大 2×、⌘+、トラックパッドでピンチ）", "es": "Ampliar (hasta 2×, ⌘+, pellizco en el trackpad)"
        ],
        "zoom.out_help": [
            "it": "Riduci (⌘−)", "en": "Zoom out (⌘−)", "zh": "缩小（⌘−）",
            "fr": "Réduire (⌘−)", "de": "Verkleinern (⌘−)", "ja": "縮小（⌘−）", "es": "Reducir (⌘−)"
        ],
        "zoom.reset_help": [
            "it": "Torna a 1× (⌘0)", "en": "Back to 1× (⌘0)", "zh": "恢复 1×（⌘0）",
            "fr": "Revenir à 1× (⌘0)", "de": "Zurück auf 1× (⌘0)", "ja": "1× に戻す（⌘0）", "es": "Volver a 1× (⌘0)"
        ],
        "action.fullscreen": [
            "it": "Schermo intero", "en": "Full Screen", "zh": "全屏",
            "fr": "Plein écran", "de": "Vollbild", "ja": "フルスクリーン", "es": "Pantalla completa"
        ],
        "action.fullscreen_help": [
            "it": "Schermo intero (doppio clic)", "en": "Full Screen (double-click)", "zh": "全屏（双击）",
            "fr": "Plein écran (double-clic)", "de": "Vollbild (Doppelklick)", "ja": "フルスクリーン（ダブルクリック）", "es": "Pantalla completa (doble clic)"
        ],
        "action.open_system_settings": [
            "it": "Apri Impostazioni di Sistema", "en": "Open System Settings", "zh": "打开系统设置",
            "fr": "Ouvrir les Réglages Système", "de": "Systemeinstellungen öffnen", "ja": "システム設定を開く", "es": "Abrir Ajustes del Sistema"
        ],
        "action.request_permission": [
            "it": "Richiedi permesso", "en": "Request permission", "zh": "请求权限",
            "fr": "Demander l’autorisation", "de": "Berechtigung anfordern", "ja": "権限をリクエスト", "es": "Solicitar permiso"
        ],
        "action.save": [
            "it": "Salva", "en": "Save", "zh": "保存",
            "fr": "Enregistrer", "de": "Speichern", "ja": "保存", "es": "Guardar"
        ],
        "action.show_in_finder": [
            "it": "Mostra nel Finder", "en": "Show in Finder", "zh": "在访达中显示",
            "fr": "Afficher dans le Finder", "de": "Im Finder zeigen", "ja": "Finderで表示", "es": "Mostrar en el Finder"
        ],
        "action.start": [
            "it": "Avvia", "en": "Start", "zh": "启动",
            "fr": "Démarrer", "de": "Starten", "ja": "開始", "es": "Iniciar"
        ],
        "action.start_server": [
            "it": "Avvia server", "en": "Start server", "zh": "启动服务器",
            "fr": "Démarrer le serveur", "de": "Server starten", "ja": "サーバーを開始", "es": "Iniciar servidor"
        ],
        "action.stop": [
            "it": "Ferma", "en": "Stop", "zh": "停止",
            "fr": "Arrêter", "de": "Stoppen", "ja": "停止", "es": "Detener"
        ],
        "action.stop_server": [
            "it": "Ferma server", "en": "Stop server", "zh": "停止服务器",
            "fr": "Arrêter le serveur", "de": "Server stoppen", "ja": "サーバーを停止", "es": "Detener servidor"
        ],
        "action.use": [
            "it": "Usa", "en": "Use", "zh": "使用",
            "fr": "Utiliser", "de": "Nutzen", "ja": "使用", "es": "Usar"
        ],
        "action.verify": [
            "it": "Verifica", "en": "Verify", "zh": "验证",
            "fr": "Vérifier", "de": "Überprüfen", "ja": "確認", "es": "Verificar"
        ],
        "discovery.empty": [
            "it": "Nessun server rilevato in rete (_pyrowavecast._udp)", "en": "No servers found on local network (_pyrowavecast._udp)", "zh": "未发现局域网服务器 (_pyrowavecast._udp)",
            "fr": "Aucun serveur détecté sur le réseau (_pyrowavecast._udp)", "de": "Kein Server im Netzwerk gefunden (_pyrowavecast._udp)", "ja": "ネットワーク上にサーバーが見つかりません (_pyrowavecast._udp)", "es": "No se detectaron servidores en la red (_pyrowavecast._udp)"
        ],
        "discovery.nearby": [
            "it": "Autodiscovery (LAN)", "en": "Nearby devices (LAN)", "zh": "局域网自动发现 (LAN)",
            "fr": "Découverte auto (LAN)", "de": "Geräte im lokalen Netzwerk (LAN)", "ja": "近くのデバイス (LAN)", "es": "Dispositivos cercanos (LAN)"
        ],
        "discovery.refresh_help": [
            "it": "Aggiorna ricerca server sulla rete locale", "en": "Refresh local network server discovery", "zh": "刷新局域网服务器列表",
            "fr": "Actualiser la recherche de serveurs sur le réseau local", "de": "Serversuche im lokalen Netzwerk aktualisieren", "ja": "ローカルネットワーク上のサーバー検索を更新", "es": "Actualizar búsqueda de servidores en la red local"
        ],
        "favorites.add_help": [
            "it": "Aggiungi ai preferiti", "en": "Add to favorites", "zh": "添加到收藏夹",
            "fr": "Ajouter aux favoris", "de": "Zu Favoriten hinzufügen", "ja": "お気に入りに追加", "es": "Añadir a favoritos"
        ],
        "favorites.empty": [
            "it": "Nessun server salvato nei preferiti", "en": "No favorite servers saved", "zh": "暂无收藏服务器",
            "fr": "Aucun serveur favori enregistré", "de": "Keine Favoriten gespeichert", "ja": "お気に入りのサーバーはありません", "es": "No hay servidores favoritos guardados"
        ],
        "favorites.remove_help": [
            "it": "Rimuovi dai preferiti", "en": "Remove from favorites", "zh": "从收藏夹移除",
            "fr": "Retirer des favoris", "de": "Aus Favoriten entfernen", "ja": "お気に入りから削除", "es": "Quitar de favoritos"
        ],
        "favorites.save_named_help": [
            "it": "Salva preferito con nome", "en": "Save favorite with custom name", "zh": "自定义名称保存收藏",
            "fr": "Enregistrer le favori avec un nom", "de": "Favorit mit Namen speichern", "ja": "名前を付けてお気に入りに保存", "es": "Guardar favorito con nombre"
        ],
        "favorites.save_title": [
            "it": "Salva nei preferiti", "en": "Save to favorites", "zh": "保存到收藏夹",
            "fr": "Enregistrer dans les favoris", "de": "Als Favorit speichern", "ja": "お気に入りに保存", "es": "Guardar en favoritos"
        ],
        "favorites.server_name_placeholder": [
            "it": "Nome server", "en": "Server name", "zh": "服务器名称",
            "fr": "Nom du serveur", "de": "Servername", "ja": "サーバー名", "es": "Nombre del servidor"
        ],
        "favorites.title": [
            "it": "Preferiti", "en": "Favorites", "zh": "收藏夹",
            "fr": "Favoris", "de": "Favoriten", "ja": "お気に入り", "es": "Favoritos"
        ],
        "lang.system": [
            "it": "Sistema / Automatica", "en": "System / Automatic", "zh": "系统默认 / 自动",
            "fr": "Système / Automatique", "de": "System / Automatisch", "ja": "システム / 自動", "es": "Sistema / Automático"
        ],
        "latency.balanced_wifi": [
            "it": "Bilanciato (Wi-Fi)", "en": "Balanced (Wi-Fi)", "zh": "平衡 (Wi-Fi)",
            "fr": "Équilibré (Wi-Fi)", "de": "Ausgewogen (WLAN)", "ja": "バランス (Wi-Fi)", "es": "Equilibrado (Wi-Fi)"
        ],
        "latency.smooth_wifi": [
            "it": "Fluido (Buffer Wi-Fi)", "en": "Smooth (Wi-Fi Buffer)", "zh": "流畅 (Wi-Fi 缓冲)",
            "fr": "Fluide (Tampon Wi-Fi)", "de": "Flüssig (WLAN-Puffer)", "ja": "スムーズ (Wi-Fiバッファ)", "es": "Fluido (Búfer Wi-Fi)"
        ],
        "latency.ultra_low": [
            "it": "Ultra-Bassa (LAN)", "en": "Ultra-Low (LAN)", "zh": "超低延迟 (LAN)",
            "fr": "Ultra-basse (LAN)", "de": "Ultra-Niedrig (LAN)", "ja": "超低遅延 (LAN)", "es": "Ultra baja (LAN)"
        ],
        "metric.age": [
            "it": "LATENZA", "en": "AGE", "zh": "延迟",
            "fr": "ÂGE", "de": "ALTER", "ja": "遅延", "es": "EDAD"
        ],
        "metric.bitrate": [
            "it": "Bitrate", "en": "Bitrate", "zh": "码率",
            "fr": "Débit", "de": "Bitrate", "ja": "ビットレート", "es": "Tasa de bits"
        ],
        "metric.client": [
            "it": "CLIENT", "en": "CLIENT", "zh": "客户端",
            "fr": "CLIENT", "de": "CLIENT", "ja": "クライアント", "es": "CLIENTE"
        ],
        "metric.clients": [
            "it": "Client", "en": "Clients", "zh": "客户端",
            "fr": "Clients", "de": "Clients", "ja": "クライアント", "es": "Clientes"
        ],
        "metric.complete_decoded": [
            "it": "COMPLETI / DECODIFICATI", "en": "COMPLETE / DECODED", "zh": "完整 / 已解码",
            "fr": "COMPLETS / DÉCODÉS", "de": "KOMPLETT / DEKODIERT", "ja": "完了 / デコード済", "es": "COMPLETOS / DECODIFICADOS"
        ],
        "metric.decode": [
            "it": "DECODIFICA", "en": "DECODE", "zh": "解码",
            "fr": "DÉCODAGE", "de": "DECODE", "ja": "デコード", "es": "DECODIF."
        ],
        "metric.dropped_expired": [
            "it": "SCARTATI / SCADUTI", "en": "DROPPED / EXPIRED", "zh": "丢弃 / 过期",
            "fr": "PERDUS / EXPIRÉS", "de": "VERWORFEN / ABGELAUFEN", "ja": "ドロップ / 期限切れ", "es": "DESCARTADOS / EXPIRADOS"
        ],
        "metric.fragments": [
            "it": "FRAMMENTI", "en": "FRAGMENTS", "zh": "分片数",
            "fr": "FRAGMENTS", "de": "FRAGMENTE", "ja": "フラグメント", "es": "FRAGMENTOS"
        ],
        "metric.frame": [
            "it": "Frame", "en": "Frames", "zh": "帧数",
            "fr": "Images", "de": "Frames", "ja": "フレーム", "es": "Fotogramas"
        ],
        "metric.frames_fmt": [
            "it": "%d frame", "en": "%d frames", "zh": "%d 帧",
            "fr": "%d images", "de": "%d Frames", "ja": "%d フレーム", "es": "%d fotogramas"
        ],
        "metric.mode": [
            "it": "Modalità", "en": "Mode", "zh": "模式",
            "fr": "Mode", "de": "Modus", "ja": "モード", "es": "Modo"
        ],
        "metric.network": [
            "it": "RETE", "en": "NETWORK", "zh": "网络",
            "fr": "RÉSEAU", "de": "NETZWERK", "ja": "ネットワーク", "es": "RED"
        ],
        "metric.port": [
            "it": "Porta", "en": "Port", "zh": "端口",
            "fr": "Port", "de": "Port", "ja": "ポート", "es": "Puerto"
        ],
        "metric.resolution": [
            "it": "Risoluzione", "en": "Resolution", "zh": "分辨率",
            "fr": "Résolution", "de": "Auflösung", "ja": "解像度", "es": "Resolución"
        ],
        "metric.video": [
            "it": "VIDEO", "en": "VIDEO", "zh": "视频",
            "fr": "VIDÉO", "de": "VIDEO", "ja": "ビデオ", "es": "VÍDEO"
        ],
        "orientation.flip_h": [
            "it": "Specchia O", "en": "Flip H", "zh": "水平翻转",
            "fr": "Miroir H", "de": "Spiegeln H", "ja": "左右反転", "es": "Voltear H"
        ],
        "orientation.flip_h_help": [
            "it": "Specchia orizzontalmente", "en": "Horizontal mirror flip", "zh": "水平镜像翻转",
            "fr": "Retournement miroir horizontal", "de": "Horizontal spiegeln", "ja": "左右に反転", "es": "Volteo en espejo horizontal"
        ],
        "orientation.flip_v": [
            "it": "Specchia V", "en": "Flip V", "zh": "垂直翻转",
            "fr": "Miroir V", "de": "Spiegeln V", "ja": "上下反転", "es": "Voltear V"
        ],
        "orientation.flip_v_help": [
            "it": "Specchia verticalmente", "en": "Vertical mirror flip", "zh": "垂直镜像翻转",
            "fr": "Retournement miroir vertical", "de": "Vertikal spiegeln", "ja": "上下に反転", "es": "Volteo en espejo vertical"
        ],
        "orientation.reset": [
            "it": "Ripristina 0°", "en": "Reset 0°", "zh": "重置 0°",
            "fr": "Réinitialiser 0°", "de": "Zurücksetzen 0°", "ja": "0°にリセット", "es": "Restablecer 0°"
        ],
        "orientation.rotate_180": [
            "it": "Ruota 180°", "en": "Rotate 180°", "zh": "旋转 180°",
            "fr": "Pivoter 180°", "de": "180° drehen", "ja": "180°回転", "es": "Girar 180°"
        ],
        "orientation.rotate_left": [
            "it": "Ruota 90° SX", "en": "Rotate 90° Left", "zh": "左旋 90°",
            "fr": "Pivoter 90° G", "de": "90° links drehen", "ja": "左へ90°回転", "es": "Girar 90° izq."
        ],
        "orientation.rotate_left_help": [
            "it": "Ruota di 90° in senso antiorario (scambia L×A)", "en": "Rotate 90° counter-clockwise (swaps W×H)", "zh": "逆时针旋转 90°（自动互换宽高）",
            "fr": "Pivoter de 90° dans le sens antihoraire (inverse L×H)", "de": "Um 90° gegen den Uhrzeigersinn drehen (tauscht B×H)", "ja": "反時計回りに90°回転（幅×高さを入替）", "es": "Girar 90° en sentido antihorario (intercambia An.×Al.)"
        ],
        "orientation.rotate_right": [
            "it": "Ruota 90° DX", "en": "Rotate 90° Right", "zh": "右旋 90°",
            "fr": "Pivoter 90° D", "de": "90° rechts drehen", "ja": "右へ90°回転", "es": "Girar 90° der."
        ],
        "orientation.rotate_right_help": [
            "it": "Ruota di 90° in senso orario (scambia L×A)", "en": "Rotate 90° clockwise (swaps W×H)", "zh": "顺时针旋转 90°（自动互换宽高）",
            "fr": "Pivoter de 90° dans le sens horaire (inverse L×H)", "de": "Um 90° im Uhrzeigersinn drehen (tauscht B×H)", "ja": "時計回りに90°回転（幅×高さを入替）", "es": "Girar 90° en sentido horario (intercambia An.×Al.)"
        ],
        "orientation.flip": [
            "it": "Flip", "en": "Flip", "zh": "翻转",
            "fr": "Flip", "de": "Flip", "ja": "反転", "es": "Flip"
        ],
        "orientation.flip_help": [
            "it": "Ribalta il video orizzontalmente (specchio)", "en": "Flip video horizontally (mirror)", "zh": "水平镜像翻转视频",
            "fr": "Retourner la vidéo horizontalement (miroir)", "de": "Video horizontal spiegeln", "ja": "ビデオを左右に反転（ミラー）", "es": "Voltear vídeo horizontalmente (espejo)"
        ],
        "orientation.rotate": [
            "it": "Ruota", "en": "Rotate", "zh": "旋转",
            "fr": "Pivoter", "de": "Drehen", "ja": "回転", "es": "Girar"
        ],
        "orientation.rotate_help": [
            "it": "Ruota ciclicamente di 90° in senso orario (scambia L×A)", "en": "Rotate 90° clockwise cyclically (swaps W×H)", "zh": "顺时针循环旋转 90°（自动互换宽高）",
            "fr": "Pivoter cycliquement de 90° dans le sens horaire (inverse L×H)", "de": "Zyklisch um 90° im Uhrzeigersinn drehen (tauscht B×H)", "ja": "時計回りに90°ずつ回転（幅×高さを入替）", "es": "Girar cíclicamente 90° en sentido horario (intercambia An.×Al.)"
        ],
        "orientation.title": [
            "it": "Orientamento video", "en": "Video orientation", "zh": "视频方向",
            "fr": "Orientation vidéo", "de": "Videoausrichtung", "ja": "ビデオの向き", "es": "Orientación de vídeo"
        ],
        "receiver.connect_prompt_subtitle": [
            "it": "Il ricevitore riceve uno stream video UDP unicast direttamente dal server.", "en": "The receiver receives a unicast UDP video stream directly from the server.", "zh": "接收端直接从服务器接收单播 UDP 视频流。",
            "fr": "Le récepteur reçoit un flux vidéo UDP unicast directement du serveur.", "de": "Der Empfänger empfängt einen Unicast-UDP-Videostream direkt vom Server.", "ja": "レシーバーはサーバーから直接ユニキャストUDPビデオストリームを受信します。", "es": "El receptor recibe un flujo de vídeo UDP unicast directamente desde el servidor."
        ],
        "receiver.connect_prompt_title": [
            "it": "Connettiti a un server SPPW/1", "en": "Connect to an SPPW/1 server", "zh": "连接到 SPPW/1 服务器",
            "fr": "Connectez-vous à un serveur SPPW/1", "de": "Mit einem SPPW/1-Server verbinden", "ja": "SPPW/1 サーバーに接続", "es": "Conéctate a un servidor SPPW/1"
        ],
        "receiver.connect_to_server": [
            "it": "Connetti al server", "en": "Connect to server", "zh": "连接到服务器",
            "fr": "Connexion au serveur", "de": "Mit Server verbinden", "ja": "サーバーに接続", "es": "Conectar al servidor"
        ],
        "receiver.control_udp_port": [
            "it": "Porta UDP di controllo", "en": "Control UDP port", "zh": "UDP 控制端口",
            "fr": "Port UDP de contrôle", "de": "UDP-Steuerport", "ja": "制御用 UDP ポート", "es": "Puerto UDP de control"
        ],
        "receiver.direct_ip_port": [
            "it": "IP diretto / Porta", "en": "Direct IP / Port", "zh": "直连 IP / 端口",
            "fr": "IP directe / Port", "de": "Direkte IP / Port", "ja": "直接 IP / ポート", "es": "IP directa / Puerto"
        ],
        "receiver.error.connection_timeout_fmt": [
            "it": "Timeout connessione (%ds)", "en": "Connection timeout (%ds)", "zh": "连接超时 (%d秒)",
            "fr": "Délai de connexion dépassé (%ds)", "de": "Verbindungs-Timeout (%ds)", "ja": "接続タイムアウト (%d秒)", "es": "Tiempo de conexión agotado (%ds)"
        ],
        "receiver.error.invalid_host_port": [
            "it": "Inserisci un indirizzo server e una porta UDP validi", "en": "Enter a valid server host and UDP port", "zh": "请输入有效的服务器地址和 UDP 端口",
            "fr": "Saisissez une adresse de serveur et un port UDP valides", "de": "Geben Sie eine gültige Serveradresse und einen UDP-Port ein", "ja": "有効なサーバーホストとUDPポートを入力してください", "es": "Introduce una dirección de servidor y un puerto UDP válidos"
        ],
        "receiver.live_stream": [
            "it": "Stream dal vivo", "en": "Live Stream", "zh": "实时画面",
            "fr": "Flux en direct", "de": "Live-Stream", "ja": "ライブストリーム", "es": "Transmisión en vivo"
        ],
        "receiver.log_title": [
            "it": "Registro ricevitore", "en": "Receiver log", "zh": "接收端日志",
            "fr": "Journal du récepteur", "de": "Empfänger-Protokoll", "ja": "レシーバーログ", "es": "Registro del receptor"
        ],
        "receiver.server_address": [
            "it": "Indirizzo server", "en": "Server address", "zh": "服务器地址",
            "fr": "Adresse du serveur", "de": "Serveradresse", "ja": "サーバーアドレス", "es": "Dirección del servidor"
        ],
        "receiver.tap_connect_or_nearby": [
            "it": "Tocca Connetti o scegli un server sulla rete locale qui sotto", "en": "Tap Connect or choose a nearby server below", "zh": "点击“连接”或在下方选择局域网内的服务器",
            "fr": "Touchez Connecter ou choisissez un serveur à proximité ci-dessous", "de": "Tippen Sie auf Verbinden oder wählen Sie unten einen Server im Netzwerk", "ja": "「接続」をタップするか、下の近くにあるサーバーを選択してください", "es": "Toca Conectar o elige un servidor cercano abajo"
        ],
        "receiver.waiting_complete_frame": [
            "it": "In attesa di un fotogramma video completo…", "en": "Waiting for a complete video frame…", "zh": "正在等待完整视频帧…",
            "fr": "En attente d’une image vidéo complète…", "de": "Warte auf vollständigen Video-Frame…", "ja": "完全なビデオフレームを待機中…", "es": "Esperando un fotograma de vídeo completo…"
        ],
        "receiver.waiting_video": [
            "it": "In attesa del flusso video…", "en": "Waiting for video…", "zh": "正在等待视频流…",
            "fr": "En attente de la vidéo…", "de": "Warte auf Video…", "ja": "ビデオを待機中…", "es": "Esperando vídeo…"
        ],
        "settings.resolution_native": [
            "it": "Nativa (schermo del server)", "en": "Native (server screen)", "zh": "原生（服务器屏幕）",
            "fr": "Native (écran du serveur)", "de": "Nativ (Serverbildschirm)", "ja": "ネイティブ（サーバー画面）", "es": "Nativa (pantalla del servidor)"
        ],
        "settings.resolution_auto": [
            "it": "Automatica", "en": "Automatic", "zh": "自动",
            "fr": "Automatique", "de": "Automatisch", "ja": "自動", "es": "Automática"
        ],
        "settings.resolution_current_fmt": [
            "it": "Stream attuale: %@", "en": "Current stream: %@", "zh": "当前串流：%@",
            "fr": "Flux actuel : %@", "de": "Aktueller Stream: %@", "ja": "現在のストリーム: %@", "es": "Transmisión actual: %@"
        ],
        "audio.source.none": [
            "it": "Nessuna (solo video)", "en": "None (video only)", "zh": "无（仅视频）",
            "fr": "Aucune (vidéo seule)", "de": "Keine (nur Video)", "ja": "なし（映像のみ）", "es": "Ninguna (solo vídeo)"
        ],
        "audio.source.system": [
            "it": "Audio di sistema", "en": "System audio", "zh": "系统音频",
            "fr": "Audio système", "de": "Systemaudio", "ja": "システムオーディオ", "es": "Audio del sistema"
        ],
        "audio.source.label": [
            "it": "Sorgente audio", "en": "Audio source", "zh": "音频来源",
            "fr": "Source audio", "de": "Audioquelle", "ja": "オーディオソース", "es": "Fuente de audio"
        ],
        "audio.input_volume": [
            "it": "Volume ingresso", "en": "Input volume", "zh": "输入音量",
            "fr": "Volume d’entrée", "de": "Eingangslautstärke", "ja": "入力音量", "es": "Volumen de entrada"
        ],
        "audio.refresh_sources": [
            "it": "Aggiorna sorgenti audio", "en": "Refresh audio sources", "zh": "刷新音频来源",
            "fr": "Actualiser les sources audio", "de": "Audioquellen aktualisieren", "ja": "オーディオソースを更新", "es": "Actualizar fuentes de audio"
        ],
        "server.chroma444": [
            "it": "Colore pieno 4:4:4 (schermo)", "en": "Full color 4:4:4 (screen)", "zh": "全色度 4:4:4（屏幕）",
            "fr": "Couleur complète 4:4:4 (écran)", "de": "Volle Farbe 4:4:4 (Bildschirm)", "ja": "フルカラー 4:4:4（画面）", "es": "Color completo 4:4:4 (pantalla)"
        ],
        "server.chroma444.help": [
            "it": "Testo e interfacce colorate più nitidi; richiede più banda e GPU. Si applica al prossimo avvio del server.", "en": "Sharper coloured text and UI; uses more bandwidth and GPU. Applies the next time the server starts.", "zh": "彩色文字和界面更清晰；占用更多带宽和 GPU。下次启动服务器时生效。",
            "fr": "Texte et interface colorés plus nets ; utilise plus de bande passante et de GPU. S’applique au prochain démarrage du serveur.", "de": "Schärferer farbiger Text und UI; benötigt mehr Bandbreite und GPU. Gilt beim nächsten Serverstart.", "ja": "色付きの文字やUIがより鮮明になりますが、帯域とGPUの負荷が増えます。次回サーバー起動時に適用されます。", "es": "Texto e interfaz en color más nítidos; usa más ancho de banda y GPU. Se aplica la próxima vez que se inicie el servidor."
        ],
        "server.client_preview": [
            "it": "Anteprima client", "en": "Client preview", "zh": "客户端预览",
            "fr": "Aperçu client", "de": "Client-Vorschau", "ja": "クライアントプレビュー", "es": "Vista previa del cliente"
        ],
        "server.remote_control": [
            "it": "Controllo remoto (mouse e tastiera)", "en": "Remote control (mouse & keyboard)", "zh": "远程控制（鼠标和键盘）",
            "fr": "Contrôle à distance (souris et clavier)", "de": "Fernsteuerung (Maus & Tastatur)", "ja": "リモート操作（マウスとキーボード）", "es": "Control remoto (ratón y teclado)"
        ],
        "server.remote_control.help": [
            "it": "Consente ai client connessi di controllare mouse e tastiera di questo Mac in modalità cattura schermo. Richiede il permesso Accessibilità di macOS.", "en": "Allows connected clients to control this Mac's mouse and keyboard in screen capture mode. Requires macOS Accessibility permission.", "zh": "允许已连接的客户端在屏幕共享模式下控制此 Mac 的鼠标和键盘。需要 macOS 辅助功能权限。",
            "fr": "Autorise les clients connectés à contrôler la souris et le clavier de ce Mac en mode capture d’écran. Nécessite l’autorisation Accessibilité de macOS.", "de": "Erlaubt verbundenen Clients die Steuerung von Maus und Tastatur dieses Macs im Bildschirmmodus. Erfordert die macOS-Bedienungshilfen-Berechtigung.", "ja": "画面共有モードで接続中のクライアントからこのMacのマウスとキーボードを操作できるようにします。macOSのアクセシビリティ権限が必要です。", "es": "Permite a los clientes conectados controlar el ratón y el teclado de este Mac en modo captura de pantalla. Requiere el permiso de Accesibilidad de macOS."
        ],
        "server.accessibility_permission_active": [
            "it": "Permesso Accessibilità attivo", "en": "Accessibility permission active", "zh": "辅助功能权限已激活",
            "fr": "Autorisation Accessibilité active", "de": "Bedienungshilfen-Berechtigung aktiv", "ja": "アクセシビリティ権限が有効です", "es": "Permiso de Accesibilidad activo"
        ],
        "server.accessibility_permission_required": [
            "it": "Permesso Accessibilità richiesto", "en": "Accessibility permission required", "zh": "需要辅助功能权限",
            "fr": "Autorisation Accessibilité requise", "de": "Bedienungshilfen-Berechtigung erforderlich", "ja": "アクセシビリティ権限が必要です", "es": "Se requiere permiso de Accesibilidad"
        ],
        "server.accessibility_permission_hint": [
            "it": "Abilita PyrowaveCast in Impostazioni di Sistema → Privacy e sicurezza → Accessibilità per iniettare mouse e tastiera.", "en": "Enable PyrowaveCast in System Settings → Privacy & Security → Accessibility to inject mouse and keyboard events.", "zh": "请在“系统设置 → 隐私与安全性 → 辅助功能”中启用 PyrowaveCast 以控制鼠标和键盘。",
            "fr": "Activez PyrowaveCast dans Réglages Système → Confidentialité et sécurité → Accessibilité pour contrôler la souris et le clavier.", "de": "Aktivieren Sie PyrowaveCast unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen, um Maus- und Tastatureingaben zu senden.", "ja": "マウスとキーボードを操作するには「システム設定 → プライバシーとセキュリティ → アクセシビリティ」でPyrowaveCastを有効にしてください。", "es": "Activa PyrowaveCast en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad para controlar el ratón y el teclado."
        ],
        "server.accessibility_guide_title": [
            "it": "Guida Accessibilità (Impostazioni e Privacy)", "en": "Accessibility guide (Privacy & Security)", "zh": "辅助功能指南（隐私与安全性）",
            "fr": "Guide Accessibilité (Confidentialité et sécurité)", "de": "Bedienungshilfen-Anleitung (Datenschutz & Sicherheit)", "ja": "アクセシビリティ設定ガイド（プライバシーとセキュリティ）", "es": "Guía de Accesibilidad (Privacidad y seguridad)"
        ],
        "server.accessibility_guide_step1": [
            "it": "Clicca \"Apri Impostazioni di Sistema\" qui sotto: si aprirà direttamente Impostazioni di Sistema → Privacy e sicurezza → Accessibilità.", "en": "Click \"Open System Settings\" below to open System Settings → Privacy & Security → Accessibility.", "zh": "点击下方的“打开系统设置”：将直接打开“系统设置 → 隐私与安全性 → 辅助功能”。",
            "fr": "Cliquez sur « Ouvrir les Réglages Système » ci-dessous pour ouvrir Réglages Système → Confidentialité et sécurité → Accessibilité.", "de": "Klicken Sie unten auf „Systemeinstellungen öffnen“, um Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen zu öffnen.", "ja": "下の「システム設定を開く」をクリックすると、「システム設定 → プライバシーとセキュリティ → アクセシビリティ」が開きます。", "es": "Haz clic en «Abrir Ajustes del Sistema» abajo para abrir Ajustes del Sistema → Privacidad y seguridad → Accesibilidad."
        ],
        "server.accessibility_guide_step2": [
            "it": "Se \"PyrowaveCast\" è già nella lista, attiva l’interruttore accanto al nome. Se NON compare, clicca \"+\" in basso a sinistra, seleziona PyrowaveCast.app (usa \"Mostra nel Finder\") e clicca \"Apri\".", "en": "If \"PyrowaveCast\" is already listed, enable its toggle. If it is NOT listed, click the \"+\" button at the bottom left, select PyrowaveCast.app (use \"Show in Finder\"), and click \"Open\".", "zh": "如果列表中已有“PyrowaveCast”，请打开其开关。如果不在列表中，请点击左下角的“+”，选择 PyrowaveCast.app（可使用“在访达中显示”）并点击“打开”。",
            "fr": "Si « PyrowaveCast » figure déjà dans la liste, activez son interrupteur. Sinon, cliquez sur « + » en bas à gauche, sélectionnez PyrowaveCast.app (utilisez « Afficher dans le Finder ») et cliquez sur « Ouvrir ».", "de": "Wenn „PyrowaveCast“ bereits aufgeführt ist, aktivieren Sie den Schalter. Andernfalls klicken Sie unten links auf „+“, wählen PyrowaveCast.app aus (nutzen Sie „Im Finder zeigen“) und klicken Sie auf „Öffnen“.", "ja": "一覧に「PyrowaveCast」がある場合はスイッチをオンにします。ない場合は左下の「+」をクリックし、PyrowaveCast.app（「Finderで表示」で確認可能）を選択して「開く」をクリックします。", "es": "Si «PyrowaveCast» ya aparece en la lista, activa su interruptor. Si NO aparece, haz clic en «+» abajo a la izquierda, selecciona PyrowaveCast.app (usa «Mostrar en el Finder») y haz clic en «Abrir»."
        ],
        "server.accessibility_guide_step3": [
            "it": "Inserisci la password del Mac oppure usa Touch ID quando richiesto da macOS.", "en": "Enter your Mac password or use Touch ID when prompted by macOS.", "zh": "当 macOS 提示时，输入您的 Mac 密码或使用触控 ID。",
            "fr": "Saisissez le mot de passe de votre Mac ou utilisez Touch ID lorsque macOS vous le demande.", "de": "Geben Sie Ihr Mac-Passwort ein oder verwenden Sie Touch ID, wenn macOS Sie dazu auffordert.", "ja": "macOSに求められたら、Macのパスワードを入力するかTouch IDを使用します。", "es": "Introduce la contraseña de tu Mac o usa Touch ID cuando macOS lo solicite."
        ],
        "server.accessibility_guide_step4": [
            "it": "Torna in PyrowaveCast e clicca \"Verifica\": il controllo remoto di mouse e tastiera sarà attivo immediatamente (se hai aggiornato l’app, disattiva e riattiva l’interruttore).", "en": "Return to PyrowaveCast and click \"Verify\": remote mouse and keyboard control activates immediately (if you updated the app, toggle it off and back on).", "zh": "返回 PyrowaveCast 并点击“验证”：鼠标和键盘远程控制将立即生效（若刚更新应用，请先关闭再重新打开该开关）。",
            "fr": "Revenez dans PyrowaveCast et cliquez sur « Vérifier » : le contrôle souris/clavier est actif immédiatement (après une mise à jour, désactivez puis réactivez l’interrupteur).", "de": "Kehren Sie zu PyrowaveCast zurück und klicken Sie auf „Überprüfen“: Die Fernsteuerung ist sofort aktiv (nach einem App-Update den Schalter aus- und wieder einschalten).", "ja": "PyrowaveCastに戻って「確認」をクリックすると、マウスとキーボードの操作がすぐ有効になります（アプリを更新した場合は一度オフにしてからオンにし直してください）。", "es": "Vuelve a PyrowaveCast y haz clic en «Verificar»: el control remoto de ratón y teclado se activará al instante (si actualizaste la app, desactiva y vuelve a activar el interruptor)."
        ],
        "server.log.accessibility_missing_warning": [
            "it": "Controllo remoto attivo ma permesso \"Accessibilità\" non concesso. Abilita PyrowaveCast in Impostazioni di Sistema → Privacy e sicurezza → Accessibilità.", "en": "Remote control is enabled, but \"Accessibility\" permission is not granted. Enable PyrowaveCast in System Settings → Privacy & Security → Accessibility.", "zh": "远程控制已启用，但未授予“辅助功能”权限。请在“系统设置 → 隐私与安全性 → 辅助功能”中启用 PyrowaveCast。",
            "fr": "Le contrôle à distance est actif, mais l’autorisation « Accessibilité » n’est pas accordée. Activez PyrowaveCast dans Réglages Système → Confidentialité et sécurité → Accessibilité.", "de": "Fernsteuerung ist aktiv, aber die Berechtigung „Bedienungshilfen“ fehlt. Aktivieren Sie PyrowaveCast unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen.", "ja": "リモート操作が有効ですが「アクセシビリティ」権限が付与されていません。「システム設定 → プライバシーとセキュリティ → アクセシビリティ」でPyrowaveCastを有効にしてください。", "es": "El control remoto está activo, pero falta el permiso de «Accesibilidad». Activa PyrowaveCast en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad."
        ],
        "receiver.remote_control": [
            "it": "Controllo remoto (mouse e tastiera)", "en": "Remote control (mouse & keyboard)", "zh": "远程控制（鼠标和键盘）",
            "fr": "Contrôle à distance (souris et clavier)", "de": "Fernsteuerung (Maus & Tastatur)", "ja": "リモート操作（マウスとキーボード）", "es": "Control remoto (ratón y teclado)"
        ],
        "receiver.remote_control_short": [
            "it": "Controllo", "en": "Control", "zh": "控制",
            "fr": "Contrôle", "de": "Steuerung", "ja": "操作", "es": "Control"
        ],
        "receiver.remote_control_help": [
            "it": "Invia mouse, rotella e tastiera al Mac remoto. Premi ⌃⌥Esc per rilasciare la tastiera.", "en": "Send mouse, scroll, and keyboard input to the remote Mac. Press ⌃⌥Esc to release keyboard focus.", "zh": "将鼠标、滚轮和键盘输入发送到远程 Mac。按 ⌃⌥Esc 释放键盘焦点。",
            "fr": "Envoie la souris, le défilement et le clavier au Mac distant. Appuyez sur ⌃⌥Échap pour libérer le clavier.", "de": "Sendet Maus-, Scroll- und Tastatureingaben an den entfernten Mac. Mit ⌃⌥Esc Tastaturfokus freigeben.", "ja": "マウス、スクロール、キーボード入力をリモートMacへ送信します。⌃⌥Escでキーボードフォーカスを解除します。", "es": "Envía ratón, rueda y teclado al Mac remoto. Pulsa ⌃⌥Esc para liberar el teclado."
        ],
        "receiver.remote_control_hint": [
            "it": "Clicca sul video per inviare mouse e tastiera al Mac remoto. Premi ⌃⌥Esc per rilasciare.", "en": "Click the video to send mouse and keyboard input to the remote Mac. Press ⌃⌥Esc to release.", "zh": "点击视频区域即可向远程 Mac 发送鼠标和键盘输入。按 ⌃⌥Esc 释放。",
            "fr": "Cliquez sur la vidéo pour contrôler le Mac distant. Appuyez sur ⌃⌥Échap pour libérer.", "de": "Klicken Sie ins Video, um Maus und Tastatur an den entfernten Mac zu senden. Mit ⌃⌥Esc beenden.", "ja": "映像をクリックするとリモートMacを操作できます。⌃⌥Escで解除します。", "es": "Haz clic en el vídeo para controlar el Mac remoto. Pulsa ⌃⌥Esc para liberar."
        ],
        "receiver.remote_control_active_badge": [
            "it": "Controllo attivo · ⌃⌥Esc per rilasciare", "en": "Control active · ⌃⌥Esc to release", "zh": "控制中 · 按 ⌃⌥Esc 释放",
            "fr": "Contrôle actif · ⌃⌥Échap pour libérer", "de": "Steuerung aktiv · ⌃⌥Esc zum Freigeben", "ja": "操作中 · ⌃⌥Escで解除", "es": "Control activo · ⌃⌥Esc para liberar"
        ],
        "receiver.remote_control_click_badge": [
            "it": "Clicca sul video per controllare", "en": "Click video to control", "zh": "点击视频开始控制",
            "fr": "Cliquez sur la vidéo pour contrôler", "de": "Zum Steuern ins Video klicken", "ja": "クリックして操作開始", "es": "Haz clic en el vídeo para controlar"
        ],
        "transfer.clear": [
            "it": "Rimuovi completati", "en": "Clear finished", "zh": "清除已完成", "fr": "Effacer les terminés", "de": "Abgeschlossene entfernen", "ja": "完了分を消去", "es": "Borrar terminados"
        ],
        "transfer.cancel": [
            "it": "Annulla trasferimento", "en": "Cancel transfer", "zh": "取消传输", "fr": "Annuler le transfert", "de": "Übertragung abbrechen", "ja": "転送をキャンセル", "es": "Cancelar transferencia"
        ],
        "transfer.waiting_fmt": [
            "it": "In attesa · %@", "en": "Waiting · %@", "zh": "等待中 · %@", "fr": "En attente · %@", "de": "Wartet · %@", "ja": "待機中 · %@", "es": "En espera · %@"
        ],
        "transfer.done_fmt": [
            "it": "Completato · %@", "en": "Done · %@", "zh": "已完成 · %@", "fr": "Terminé · %@", "de": "Fertig · %@", "ja": "完了 · %@", "es": "Completado · %@"
        ],
        "transfer.failed_fmt": [
            "it": "Non riuscito (%@)", "en": "Failed (%@)", "zh": "失败（%@）", "fr": "Échec (%@)", "de": "Fehlgeschlagen (%@)", "ja": "失敗（%@）", "es": "Error (%@)"
        ],
        "transfer.cancelled": [
            "it": "Annullato", "en": "Cancelled", "zh": "已取消", "fr": "Annulé", "de": "Abgebrochen", "ja": "キャンセル済み", "es": "Cancelado"
        ],
        "security.broadcast_open_note": [
            "it": "La trasmissione di sistema (Condividi lo schermo) senza App Group non può mostrare il PIN: lì vale la modalità aperta, sempre cifrata.", "en": "System broadcast (Share screen) without the App Group cannot show the PIN: it uses open mode there, still encrypted.", "zh": "未启用 App Group 时，系统广播（共享屏幕）无法显示 PIN：此时使用开放模式，仍然加密。", "fr": "La diffusion système (Partager l'écran) sans App Group ne peut pas afficher le code : elle utilise le mode ouvert, toujours chiffré.", "de": "Die Systemübertragung (Bildschirm teilen) ohne App Group kann die PIN nicht zeigen: Dort gilt der offene Modus, weiterhin verschlüsselt.", "ja": "App Group がない場合、システムブロードキャスト（画面共有）はPINを表示できません：その場合はオープンモード（暗号化は維持）になります。", "es": "La emisión del sistema (Compartir pantalla) sin App Group no puede mostrar el PIN: allí usa el modo abierto, sigue cifrado."
        ],
        "security.section": [
            "it": "Sicurezza", "en": "Security", "zh": "安全", "fr": "Sécurité", "de": "Sicherheit", "ja": "セキュリティ", "es": "Seguridad"
        ],
        "security.encryption": [
            "it": "Cifratura", "en": "Encryption", "zh": "加密", "fr": "Chiffrement", "de": "Verschlüsselung", "ja": "暗号化", "es": "Cifrado"
        ],
        "security.encryption.help": [
            "it": "Cifra lo stream (AES-256-GCM) e richiede l'handshake sicuro. Server e ricevitori devono avere la stessa impostazione.", "en": "Encrypts the stream (AES-256-GCM) and requires the secure handshake. Server and receivers must use the same setting.", "zh": "加密串流（AES-256-GCM）并要求安全握手。服务器和接收端必须设置一致。", "fr": "Chiffre le flux (AES-256-GCM) et exige la poignée de main sécurisée. Le serveur et les récepteurs doivent avoir le même réglage.", "de": "Verschlüsselt den Stream (AES-256-GCM) und verlangt den sicheren Handshake. Server und Empfänger müssen gleich eingestellt sein.", "ja": "ストリームを暗号化（AES-256-GCM）し、安全なハンドシェイクを必須にします。サーバと受信側は同じ設定にしてください。", "es": "Cifra la transmisión (AES-256-GCM) y exige el protocolo de enlace seguro. El servidor y los receptores deben usar el mismo ajuste."
        ],
        "security.pairing_mode": [
            "it": "Abbinamento", "en": "Pairing", "zh": "配对", "fr": "Association", "de": "Kopplung", "ja": "ペアリング", "es": "Emparejamiento"
        ],
        "security.mode.pin": [
            "it": "PIN", "en": "PIN", "zh": "PIN", "fr": "PIN", "de": "PIN", "ja": "PIN", "es": "PIN"
        ],
        "security.mode.password": [
            "it": "Password", "en": "Password", "zh": "密码", "fr": "Mot de passe", "de": "Passwort", "ja": "パスワード", "es": "Contraseña"
        ],
        "security.mode.open": [
            "it": "Aperto", "en": "Open", "zh": "开放", "fr": "Ouvert", "de": "Offen", "ja": "オープン", "es": "Abierto"
        ],
        "security.mode.pin.help": [
            "it": "Un nuovo ricevitore si abbina con il PIN a 5 cifre che compare qui.", "en": "A new receiver pairs with the 5-digit PIN shown here.", "zh": "新接收端使用此处显示的 5 位 PIN 配对。", "fr": "Un nouveau récepteur s'associe avec le code PIN à 5 chiffres affiché ici.", "de": "Ein neuer Empfänger koppelt mit der hier angezeigten 5-stelligen PIN.", "ja": "新しい受信側は、ここに表示される5桁のPINでペアリングします。", "es": "Un receptor nuevo se empareja con el PIN de 5 dígitos que aparece aquí."
        ],
        "security.mode.password.help": [
            "it": "Per server headless senza schermo: un nuovo ricevitore si abbina con questa password.", "en": "For headless servers without a screen: a new receiver pairs with this password.", "zh": "适用于无屏幕的服务器：新接收端使用此密码配对。", "fr": "Pour les serveurs sans écran : un nouveau récepteur s'associe avec ce mot de passe.", "de": "Für Server ohne Bildschirm: Ein neuer Empfänger koppelt mit diesem Passwort.", "ja": "画面のないサーバ向け：新しい受信側はこのパスワードでペアリングします。", "es": "Para servidores sin pantalla: un receptor nuevo se empareja con esta contraseña."
        ],
        "security.mode.open.help": [
            "it": "Qualsiasi ricevitore della rete può collegarsi (sempre cifrato, ma senza verificare chi è).", "en": "Any receiver on the network can connect (still encrypted, but nobody is verified).", "zh": "网络中的任何接收端都可以连接（仍然加密，但不验证身份）。", "fr": "Tout récepteur du réseau peut se connecter (toujours chiffré, mais sans vérification).", "de": "Jeder Empfänger im Netz kann sich verbinden (weiterhin verschlüsselt, aber ohne Prüfung).", "ja": "ネットワーク上のどの受信側も接続できます（暗号化は維持、ただし相手は検証しません）。", "es": "Cualquier receptor de la red puede conectarse (sigue cifrado, pero sin verificar a nadie)."
        ],
        "security.password.placeholder": [
            "it": "Nuova password", "en": "New password", "zh": "新密码", "fr": "Nouveau mot de passe", "de": "Neues Passwort", "ja": "新しいパスワード", "es": "Nueva contraseña"
        ],
        "security.password.save": [
            "it": "Salva", "en": "Save", "zh": "保存", "fr": "Enregistrer", "de": "Sichern", "ja": "保存", "es": "Guardar"
        ],
        "security.password.set": [
            "it": "Password impostata", "en": "Password set", "zh": "已设置密码", "fr": "Mot de passe défini", "de": "Passwort gesetzt", "ja": "パスワード設定済み", "es": "Contraseña establecida"
        ],
        "security.password.missing": [
            "it": "Nessuna password: i nuovi ricevitori non possono abbinarsi", "en": "No password: new receivers cannot pair", "zh": "未设置密码：新接收端无法配对", "fr": "Aucun mot de passe : les nouveaux récepteurs ne peuvent pas s'associer", "de": "Kein Passwort: Neue Empfänger können nicht koppeln", "ja": "パスワード未設定：新しい受信側はペアリングできません", "es": "Sin contraseña: los receptores nuevos no pueden emparejarse"
        ],
        "security.fingerprint_this": [
            "it": "Impronta di questo dispositivo", "en": "This device's fingerprint", "zh": "本设备指纹", "fr": "Empreinte de cet appareil", "de": "Fingerabdruck dieses Geräts", "ja": "このデバイスのフィンガープリント", "es": "Huella de este dispositivo"
        ],
        "security.paired_clients_fmt": [
            "it": "Ricevitori abbinati (%ld)", "en": "Paired receivers (%ld)", "zh": "已配对接收端（%ld）", "fr": "Récepteurs associés (%ld)", "de": "Gekoppelte Empfänger (%ld)", "ja": "ペアリング済み受信側（%ld）", "es": "Receptores emparejados (%ld)"
        ],
        "security.paired_servers_fmt": [
            "it": "Server abbinati (%ld)", "en": "Paired servers (%ld)", "zh": "已配对服务器（%ld）", "fr": "Serveurs associés (%ld)", "de": "Gekoppelte Server (%ld)", "ja": "ペアリング済みサーバ（%ld）", "es": "Servidores emparejados (%ld)"
        ],
        "security.forget": [
            "it": "Dimentica", "en": "Forget", "zh": "忘记", "fr": "Oublier", "de": "Vergessen", "ja": "削除", "es": "Olvidar"
        ],
        "security.none_paired": [
            "it": "Nessun dispositivo abbinato", "en": "No paired devices", "zh": "没有已配对设备", "fr": "Aucun appareil associé", "de": "Keine gekoppelten Geräte", "ja": "ペアリング済みデバイスはありません", "es": "Ningún dispositivo emparejado"
        ],
        "security.pin.title": [
            "it": "PIN di abbinamento", "en": "Pairing PIN", "zh": "配对 PIN", "fr": "Code d'association", "de": "Kopplungs-PIN", "ja": "ペアリングPIN", "es": "PIN de emparejamiento"
        ],
        "security.pin.subtitle_fmt": [
            "it": "Digita questo PIN su %@ · impronta %@", "en": "Type this PIN on %@ · fingerprint %@", "zh": "请在 %@ 上输入此 PIN · 指纹 %@", "fr": "Saisissez ce code sur %@ · empreinte %@", "de": "Diese PIN auf %@ eingeben · Fingerabdruck %@", "ja": "%@ でこのPINを入力 · フィンガープリント %@", "es": "Escribe este PIN en %@ · huella %@"
        ],
        "security.pin.expires_fmt": [
            "it": "Scade tra %ld s", "en": "Expires in %ld s", "zh": "%ld 秒后过期", "fr": "Expire dans %ld s", "de": "Läuft in %ld s ab", "ja": "あと %ld 秒で失効", "es": "Caduca en %ld s"
        ],
        "security.pin.dismiss": [
            "it": "Rifiuta", "en": "Reject", "zh": "拒绝", "fr": "Refuser", "de": "Ablehnen", "ja": "拒否", "es": "Rechazar"
        ],
        "security.log.pin_requested_fmt": [
            "it": "Abbinamento richiesto da %@ (%@): PIN mostrato", "en": "Pairing requested by %@ (%@): PIN shown", "zh": "%@（%@）请求配对：已显示 PIN", "fr": "Association demandée par %@ (%@) : code affiché", "de": "Kopplung angefragt von %@ (%@): PIN angezeigt", "ja": "%@（%@）がペアリングを要求：PINを表示", "es": "Emparejamiento solicitado por %@ (%@): PIN mostrado"
        ],
        "security.log.paired_fmt": [
            "it": "Abbinato %@ (%@)", "en": "Paired %@ (%@)", "zh": "已配对 %@（%@）", "fr": "%@ associé (%@)", "de": "%@ gekoppelt (%@)", "ja": "%@ をペアリング（%@）", "es": "%@ emparejado (%@)"
        ],
        "security.log.session_paired_fmt": [
            "it": "Sessione cifrata con %@ (%@), abbinato", "en": "Encrypted session with %@ (%@), paired", "zh": "与 %@（%@）的加密会话，已配对", "fr": "Session chiffrée avec %@ (%@), associé", "de": "Verschlüsselte Sitzung mit %@ (%@), gekoppelt", "ja": "%@（%@）との暗号化セッション、ペアリング済み", "es": "Sesión cifrada con %@ (%@), emparejado"
        ],
        "security.log.session_fmt": [
            "it": "Sessione cifrata con %@ (%@)", "en": "Encrypted session with %@ (%@)", "zh": "与 %@（%@）的加密会话", "fr": "Session chiffrée avec %@ (%@)", "de": "Verschlüsselte Sitzung mit %@ (%@)", "ja": "%@（%@）との暗号化セッション", "es": "Sesión cifrada con %@ (%@)"
        ],
        "security.prompt.pin.title": [
            "it": "Inserisci il PIN", "en": "Enter the PIN", "zh": "输入 PIN", "fr": "Saisissez le code", "de": "PIN eingeben", "ja": "PINを入力", "es": "Introduce el PIN"
        ],
        "security.prompt.pin.message_fmt": [
            "it": "%@ mostra un PIN a 5 cifre. Impronta del server: %@", "en": "%@ shows a 5-digit PIN. Server fingerprint: %@", "zh": "%@ 显示了一个 5 位 PIN。服务器指纹：%@", "fr": "%@ affiche un code à 5 chiffres. Empreinte du serveur : %@", "de": "%@ zeigt eine 5-stellige PIN. Fingerabdruck des Servers: %@", "ja": "%@ に5桁のPINが表示されています。サーバのフィンガープリント：%@", "es": "%@ muestra un PIN de 5 dígitos. Huella del servidor: %@"
        ],
        "security.prompt.password.title": [
            "it": "Password del server", "en": "Server password", "zh": "服务器密码", "fr": "Mot de passe du serveur", "de": "Server-Passwort", "ja": "サーバのパスワード", "es": "Contraseña del servidor"
        ],
        "security.prompt.password.message_fmt": [
            "it": "Inserisci la password di abbinamento di %@. Impronta del server: %@", "en": "Enter the pairing password of %@. Server fingerprint: %@", "zh": "输入 %@ 的配对密码。服务器指纹：%@", "fr": "Saisissez le mot de passe d'association de %@. Empreinte du serveur : %@", "de": "Kopplungs-Passwort von %@ eingeben. Fingerabdruck des Servers: %@", "ja": "%@ のペアリングパスワードを入力。サーバのフィンガープリント：%@", "es": "Introduce la contraseña de emparejamiento de %@. Huella del servidor: %@"
        ],
        "security.prompt.wrong_fmt": [
            "it": "Errato. Tentativi rimasti: %ld", "en": "Wrong. Attempts left: %ld", "zh": "错误。剩余尝试次数：%ld", "fr": "Incorrect. Essais restants : %ld", "de": "Falsch. Verbleibende Versuche: %ld", "ja": "違います。残り回数：%ld", "es": "Incorrecto. Intentos restantes: %ld"
        ],
        "security.prompt.renewed": [
            "it": "Il PIN precedente non vale più: il server ne mostra uno nuovo.", "en": "The previous PIN is no longer valid: the server shows a new one.", "zh": "之前的 PIN 已失效：服务器显示了新的 PIN。", "fr": "L'ancien code n'est plus valable : le serveur en affiche un nouveau.", "de": "Die vorige PIN gilt nicht mehr: Der Server zeigt eine neue.", "ja": "前のPINは無効です：サーバに新しいPINが表示されます。", "es": "El PIN anterior ya no vale: el servidor muestra uno nuevo."
        ],
        "security.prompt.pair": [
            "it": "Abbina", "en": "Pair", "zh": "配对", "fr": "Associer", "de": "Koppeln", "ja": "ペアリング", "es": "Emparejar"
        ],
        "security.prompt.cancel": [
            "it": "Annulla", "en": "Cancel", "zh": "取消", "fr": "Annuler", "de": "Abbrechen", "ja": "キャンセル", "es": "Cancelar"
        ],
        "security.status.paired": [
            "it": "Cifrato · abbinato", "en": "Encrypted · paired", "zh": "已加密 · 已配对", "fr": "Chiffré · associé", "de": "Verschlüsselt · gekoppelt", "ja": "暗号化 · ペアリング済み", "es": "Cifrado · emparejado"
        ],
        "security.status.unverified": [
            "it": "Cifrato · server non verificato", "en": "Encrypted · server not verified", "zh": "已加密 · 服务器未验证", "fr": "Chiffré · serveur non vérifié", "de": "Verschlüsselt · Server nicht geprüft", "ja": "暗号化 · サーバ未検証", "es": "Cifrado · servidor no verificado"
        ],
        "security.status.plaintext": [
            "it": "Non cifrato", "en": "Not encrypted", "zh": "未加密", "fr": "Non chiffré", "de": "Unverschlüsselt", "ja": "暗号化なし", "es": "Sin cifrar"
        ],
        "security.receiver.encryption.help": [
            "it": "Usa l'handshake sicuro e cifra lo stream. Deve corrispondere all'impostazione del server; se non corrisponde la connessione viene rifiutata, mai declassata.", "en": "Uses the secure handshake and encrypts the stream. Must match the server's setting; a mismatch is refused, never downgraded.", "zh": "使用安全握手并加密串流。必须与服务器设置一致；不一致时拒绝连接，绝不降级。", "fr": "Utilise la poignée de main sécurisée et chiffre le flux. Doit correspondre au réglage du serveur ; une différence est refusée, jamais rétrogradée.", "de": "Nutzt den sicheren Handshake und verschlüsselt den Stream. Muss zur Server-Einstellung passen; Abweichungen werden abgelehnt, nie herabgestuft.", "ja": "安全なハンドシェイクを使い、ストリームを暗号化します。サーバ設定と一致が必要で、不一致は拒否され、決して格下げされません。", "es": "Usa el protocolo de enlace seguro y cifra la transmisión. Debe coincidir con el servidor; si no coincide se rechaza, nunca se degrada."
        ],
        "security.failure.server_requires_encryption": [
            "it": "Il server richiede la cifratura: attivala in questo ricevitore.", "en": "The server requires encryption: turn it on in this receiver.", "zh": "服务器要求加密：请在此接收端开启。", "fr": "Le serveur exige le chiffrement : activez-le sur ce récepteur.", "de": "Der Server verlangt Verschlüsselung: hier einschalten.", "ja": "サーバは暗号化を必要とします：この受信側で有効にしてください。", "es": "El servidor exige cifrado: actívalo en este receptor."
        ],
        "security.failure.server_encryption_disabled": [
            "it": "La cifratura è disattivata sul server: attivala lì o disattivala qui.", "en": "Encryption is off on the server: turn it on there or off here.", "zh": "服务器已关闭加密：请在服务器上开启，或在此关闭。", "fr": "Le chiffrement est désactivé sur le serveur : activez-le là-bas ou désactivez-le ici.", "de": "Auf dem Server ist die Verschlüsselung aus: dort ein- oder hier ausschalten.", "ja": "サーバで暗号化がオフです：サーバで有効にするか、ここで無効にしてください。", "es": "El cifrado está desactivado en el servidor: actívalo allí o desactívalo aquí."
        ],
        "security.failure.bad_signature": [
            "it": "Il server non ha dimostrato la sua identità: connessione interrotta.", "en": "The server did not prove its identity: connection stopped.", "zh": "服务器未能证明其身份：连接已中止。", "fr": "Le serveur n'a pas prouvé son identité : connexion interrompue.", "de": "Der Server hat seine Identität nicht nachgewiesen: Verbindung beendet.", "ja": "サーバが身元を証明できませんでした：接続を中止しました。", "es": "El servidor no demostró su identidad: conexión detenida."
        ],
        "security.failure.denied": [
            "it": "Il server ha rifiutato questo dispositivo.", "en": "The server refused this device.", "zh": "服务器拒绝了此设备。", "fr": "Le serveur a refusé cet appareil.", "de": "Der Server hat dieses Gerät abgelehnt.", "ja": "サーバがこのデバイスを拒否しました。", "es": "El servidor rechazó este dispositivo."
        ],
        "security.failure.locked": [
            "it": "Troppi tentativi: riprova tra qualche minuto.", "en": "Too many attempts: try again in a few minutes.", "zh": "尝试次数过多：请几分钟后重试。", "fr": "Trop d'essais : réessayez dans quelques minutes.", "de": "Zu viele Versuche: in ein paar Minuten erneut versuchen.", "ja": "試行回数が多すぎます：数分後に再試行してください。", "es": "Demasiados intentos: vuelve a intentarlo en unos minutos."
        ],
        "security.failure.unavailable": [
            "it": "Il server non ha una password di abbinamento.", "en": "The server has no pairing password.", "zh": "服务器未设置配对密码。", "fr": "Le serveur n'a pas de mot de passe d'association.", "de": "Der Server hat kein Kopplungs-Passwort.", "ja": "サーバにペアリングパスワードがありません。", "es": "El servidor no tiene contraseña de emparejamiento."
        ],
        "security.failure.cancelled": [
            "it": "Abbinamento annullato.", "en": "Pairing cancelled.", "zh": "已取消配对。", "fr": "Association annulée.", "de": "Kopplung abgebrochen.", "ja": "ペアリングをキャンセルしました。", "es": "Emparejamiento cancelado."
        ],
        "settings.prefer_high_quality": [
            "it": "Preferisci alta qualità", "en": "Prefer high quality", "zh": "优先高画质",
            "fr": "Privilégier la qualité", "de": "Hohe Qualität bevorzugen", "ja": "高画質を優先", "es": "Preferir alta calidad"
        ],
        "settings.prefer_high_quality_help": [
            "it": "Bitrate e risoluzione automatici restano alti durante i brevi disturbi del Wi-Fi e risalgono prima, con un po' più di FEC: immagine più nitida, qualche scatto in più su una rete debole.",
            "en": "Automatic bitrate and resolution stay high through short Wi-Fi trouble and climb back sooner, with a little more FEC: a sharper picture, a few more glitches on a weak link.",
            "zh": "自动码率和分辨率在短暂的 Wi-Fi 波动中保持较高并更快恢复，并略增 FEC：画面更清晰，弱网络下偶尔多些卡顿。",
            "fr": "Le débit et la résolution automatiques restent élevés pendant les courtes perturbations Wi-Fi et remontent plus vite, avec un peu plus de FEC : image plus nette, quelques saccades de plus sur un réseau faible.",
            "de": "Automatische Bitrate und Auflösung bleiben bei kurzen WLAN-Störungen hoch und steigen schneller wieder, mit etwas mehr FEC: schärferes Bild, bei schwachem Netz etwas mehr Ruckler.",
            "ja": "自動ビットレートと解像度が短いWi-Fiの乱れでも高いまま保たれ、早く回復します（FECも少し増加）。画質はより鮮明に、弱い回線では少し乱れが増えます。",
            "es": "La tasa de bits y la resolución automáticas se mantienen altas durante los cortes breves de Wi-Fi y suben antes, con algo más de FEC: imagen más nítida, algún tirón más en una red débil."
        ],
        "receiver.hide_remote_cursor": [
            "it": "Nascondi cursore remoto", "en": "Hide remote cursor", "zh": "隐藏远程光标",
            "fr": "Masquer le curseur distant", "de": "Entfernten Zeiger ausblenden", "ja": "リモートのカーソルを隠す", "es": "Ocultar cursor remoto"
        ],
        "receiver.hide_remote_cursor_help": [
            "it": "Lascia fuori dal video il cursore del Mac remoto anche senza controllo remoto. Con il controllo remoto attivo è sempre nascosto: al suo posto c'è il puntatore di questo Mac.",
            "en": "Keeps the remote Mac's cursor out of the video even without remote control. With remote control on it is always hidden: this Mac's pointer takes its place.",
            "zh": "即使未开启远程控制，也不在视频中显示远程 Mac 的光标。开启远程控制时始终隐藏，由本机指针代替。",
            "fr": "Retire le curseur du Mac distant de la vidéo, même sans contrôle à distance. Avec le contrôle à distance activé, il est toujours masqué : le pointeur de ce Mac le remplace.",
            "de": "Blendet den Zeiger des entfernten Mac auch ohne Fernsteuerung aus dem Video aus. Bei aktiver Fernsteuerung ist er immer ausgeblendet: Der Zeiger dieses Mac ersetzt ihn.",
            "ja": "リモート操作をしていなくても、リモートMacのカーソルを映像に表示しません。リモート操作中は常に非表示で、このMacのポインタが代わりに使われます。",
            "es": "Deja fuera del vídeo el cursor del Mac remoto incluso sin control remoto. Con el control remoto activado siempre está oculto: lo sustituye el puntero de este Mac."
        ],
        "receiver.clipboard_sync_help": [
            "it": "Copia qui e incolla sul Mac remoto, e viceversa: testo, immagini e file (fino a 16 MB). Funziona con il controllo remoto attivo.",
            "en": "Copy here and paste on the remote Mac, and back: text, images and files (up to 16 MB). Works while remote control is on.",
            "zh": "在此复制、在远程 Mac 上粘贴，反之亦然：文本、图片和文件（最多 16 MB）。需开启远程控制。",
            "fr": "Copiez ici et collez sur le Mac distant, et inversement : texte, images et fichiers (jusqu’à 16 Mo). Fonctionne avec le contrôle à distance activé.",
            "de": "Hier kopieren und auf dem entfernten Mac einsetzen und umgekehrt: Text, Bilder und Dateien (bis 16 MB). Funktioniert bei aktiver Fernsteuerung.",
            "ja": "ここでコピーしてリモートMacでペースト、その逆も可能：テキスト、画像、ファイル（最大16 MB）。リモート操作中に有効です。",
            "es": "Copia aquí y pega en el Mac remoto, y al revés: texto, imágenes y archivos (hasta 16 MB). Funciona con el control remoto activado."
        ],
        "receiver.log.clipboard_received": [
            "it": "Appunti dal Mac remoto (%@, %ld B)", "en": "Clipboard from the remote Mac (%@, %ld B)", "zh": "来自远程 Mac 的剪贴板（%@，%ld B）",
            "fr": "Presse-papiers du Mac distant (%@, %ld o)", "de": "Zwischenablage vom entfernten Mac (%@, %ld B)", "ja": "リモートMacのクリップボード（%@、%ld B）", "es": "Portapapeles del Mac remoto (%@, %ld B)"
        ],
        "receiver.log.remote_control_enabled": [
            "it": "Controllo remoto abilitato (clicca sul video, ⌃⌥Esc per rilasciare)", "en": "Remote control enabled (click video, ⌃⌥Esc to release)", "zh": "已启用远程控制（点击视频区域，按 ⌃⌥Esc 释放）",
            "fr": "Contrôle à distance activé (cliquez sur la vidéo, ⌃⌥Échap pour libérer)", "de": "Fernsteuerung aktiviert (ins Video klicken, ⌃⌥Esc zum Freigeben)", "ja": "リモート操作を有効にしました（映像をクリック、⌃⌥Escで解除）", "es": "Control remoto activado (haz clic en el vídeo, ⌃⌥Esc para liberar)"
        ],
        "receiver.log.remote_control_disabled": [
            "it": "Controllo remoto disabilitato", "en": "Remote control disabled", "zh": "已禁用远程控制",
            "fr": "Contrôle à distance désactivé", "de": "Fernsteuerung deaktiviert", "ja": "リモート操作を無効にしました", "es": "Control remoto desactivado"
        ],
        "broadcast.share_screen": [
            "it": "Condividi tutto lo schermo", "en": "Share the whole screen", "zh": "共享整个屏幕",
            "fr": "Partager tout l’écran", "de": "Ganzen Bildschirm teilen", "ja": "画面全体を共有", "es": "Compartir toda la pantalla"
        ],
        "server.clipboard_sync_store": [
            "it": "Appunti condivisi con i client", "en": "Share the clipboard with clients", "zh": "与客户端共享剪贴板",
            "fr": "Partager le presse-papiers avec les clients", "de": "Zwischenablage mit Clients teilen", "ja": "クライアントとクリップボードを共有", "es": "Compartir el portapapeles con los clientes"
        ],
        "server.remote_control_store_unavailable": [
            "it": "Nella versione Mac App Store i client non possono controllare mouse e tastiera di questo Mac: la sandbox di macOS non lo consente. Usa la versione scaricabile da GitHub per il controllo remoto.", "en": "In the Mac App Store version clients can't control this Mac's mouse and keyboard: the macOS App Sandbox doesn't allow it. Use the download from GitHub for remote control.", "zh": "在 Mac App Store 版本中，客户端无法控制此 Mac 的鼠标和键盘：macOS App 沙盒不允许。如需远程控制，请使用 GitHub 上的下载版本。",
            "fr": "Dans la version Mac App Store, les clients ne peuvent pas contrôler la souris et le clavier de ce Mac : le bac à sable macOS ne le permet pas. Utilisez la version téléchargeable sur GitHub pour le contrôle à distance.", "de": "In der Mac App Store-Version können Clients Maus und Tastatur dieses Macs nicht steuern: Die macOS App Sandbox erlaubt es nicht. Für die Fernsteuerung die Version von GitHub verwenden.", "ja": "Mac App Store 版では、クライアントはこの Mac のマウスとキーボードを操作できません（macOS の App Sandbox が許可しないため）。リモート操作には GitHub のダウンロード版を使用してください。", "es": "En la versión de la Mac App Store los clientes no pueden controlar el ratón y el teclado de este Mac: el App Sandbox de macOS no lo permite. Usa la versión descargable de GitHub para el control remoto."
        ],
        "broadcast.stop": [
            "it": "Trasmissione attiva · tocca per fermarla", "en": "Broadcast running · tap to stop", "zh": "正在广播 · 轻点停止",
            "fr": "Diffusion en cours · touchez pour arrêter", "de": "Übertragung läuft · tippen zum Beenden", "ja": "ブロードキャスト中 · タップで停止", "es": "Transmisión activa · toca para detenerla"
        ],
        "broadcast.help_fmt": [
            "it": "Trasmette tutto lo schermo e l’audio delle app anche quando PyrowaveCast è in background, sulla schermata Home o con lo schermo bloccato (estensione di trasmissione iOS, porta UDP %d). Si avvia e si ferma anche dal Centro di Controllo (Registrazione schermo → PyrowaveCast).", "en": "Casts the whole screen and app audio even while PyrowaveCast is in the background, on the Home Screen or locked (iOS broadcast extension, UDP port %d). You can also start and stop it from Control Center (Screen Recording → PyrowaveCast).", "zh": "即使 PyrowaveCast 在后台、位于主屏幕或锁屏，也会投射整个屏幕和 App 音频（iOS 广播扩展，UDP 端口 %d）。也可在控制中心启动和停止（屏幕录制 → PyrowaveCast）。",
            "fr": "Diffuse tout l’écran et le son des apps même lorsque PyrowaveCast est en arrière-plan, sur l’écran d’accueil ou verrouillé (extension de diffusion iOS, port UDP %d). Démarrage et arrêt aussi depuis le Centre de contrôle (Enregistrement de l’écran → PyrowaveCast).", "de": "Überträgt den ganzen Bildschirm und den App-Ton, auch wenn PyrowaveCast im Hintergrund, auf dem Home-Bildschirm oder gesperrt ist (iOS-Übertragungserweiterung, UDP-Port %d). Start und Stopp auch über das Kontrollzentrum (Bildschirmaufnahme → PyrowaveCast).", "ja": "PyrowaveCast がバックグラウンド、ホーム画面、ロック中でも画面全体と App のオーディオをキャストします（iOS ブロードキャスト拡張、UDP ポート %d）。コントロールセンター（画面収録 → PyrowaveCast）からも開始・停止できます。", "es": "Transmite toda la pantalla y el audio de las apps aunque PyrowaveCast esté en segundo plano, en la pantalla de inicio o bloqueado (extensión de transmisión de iOS, puerto UDP %d). También se inicia y detiene desde el Centro de control (Grabación de pantalla → PyrowaveCast)."
        ],
        "broadcast.error.start_fmt": [
            "it": "Server PyrowaveCast non avviato sulla porta UDP %d (%@). Ferma il server nell’app e riprova.", "en": "PyrowaveCast server could not start on UDP port %d (%@). Stop the server in the app and try again.", "zh": "PyrowaveCast 服务器无法在 UDP 端口 %d 上启动（%@）。请停止 App 内的服务器后重试。",
            "fr": "Le serveur PyrowaveCast n’a pas pu démarrer sur le port UDP %d (%@). Arrêtez le serveur dans l’app et réessayez.", "de": "PyrowaveCast-Server konnte nicht auf UDP-Port %d starten (%@). Server in der App stoppen und erneut versuchen.", "ja": "PyrowaveCast サーバーを UDP ポート %d で開始できませんでした（%@）。App のサーバーを停止してからやり直してください。", "es": "No se pudo iniciar el servidor PyrowaveCast en el puerto UDP %d (%@). Detén el servidor en la app y vuelve a intentarlo."
        ],
        "server.background.title": [
            "it": "Server PyrowaveCast attivo", "en": "PyrowaveCast server running", "zh": "PyrowaveCast 服务器运行中",
            "fr": "Serveur PyrowaveCast actif", "de": "PyrowaveCast-Server aktiv", "ja": "PyrowaveCast サーバー実行中", "es": "Servidor PyrowaveCast activo"
        ],
        "server.background.subtitle_waiting": [
            "it": "Streaming in corso anche in background", "en": "Keeps streaming in the background", "zh": "在后台继续串流",
            "fr": "Diffusion maintenue en arrière-plan", "de": "Streamt auch im Hintergrund weiter", "ja": "バックグラウンドでもストリーミングを継続", "es": "Sigue transmitiendo en segundo plano"
        ],
        "server.background.subtitle_fmt": [
            "it": "Client: %d · %@ Mb/s", "en": "Clients: %d · %@ Mb/s", "zh": "客户端：%d · %@ Mb/s",
            "fr": "Clients : %d · %@ Mb/s", "de": "Clients: %d · %@ Mb/s", "ja": "クライアント: %d · %@ Mb/s", "es": "Clientes: %d · %@ Mb/s"
        ],
        "server.error.file_import_fmt": [
            "it": "Impossibile importare il file selezionato: %@", "en": "Could not import the selected file: %@", "zh": "无法导入所选文件：%@",
            "fr": "Impossible d’importer le fichier sélectionné : %@", "de": "Ausgewählte Datei konnte nicht importiert werden: %@", "ja": "選択したファイルを読み込めませんでした: %@", "es": "No se pudo importar el archivo seleccionado: %@"
        ],
        "server.error.photos_copy_fmt": [
            "it": "Impossibile copiare il file da Foto: %@", "en": "Could not copy file from Photos: %@", "zh": "无法从“照片”复制文件：%@",
            "fr": "Impossible de copier le fichier depuis Photos : %@", "de": "Datei konnte nicht aus Fotos kopiert werden: %@", "ja": "写真からファイルをコピーできませんでした: %@", "es": "No se pudo copiar el archivo desde Fotos: %@"
        ],
        "server.error.photos_import_fmt": [
            "it": "Impossibile importare da Foto: %@", "en": "Could not import from Photos: %@", "zh": "无法从“照片”导入：%@",
            "fr": "Impossible d’importer depuis Photos : %@", "de": "Import aus Fotos fehlgeschlagen: %@", "ja": "写真から読み込めませんでした: %@", "es": "No se pudo importar desde Fotos: %@"
        ],
        "server.error.photos_unavailable": [
            "it": "Impossibile importare da Foto: file non disponibile.", "en": "Could not import from Photos: file unavailable.", "zh": "无法从“照片”导入：文件不可用。",
            "fr": "Impossible d’importer depuis Photos : fichier indisponible.", "de": "Import aus Fotos fehlgeschlagen: Datei nicht verfügbar.", "ja": "写真から読み込めませんでした: ファイルが利用できません。", "es": "No se pudo importar desde Fotos: archivo no disponible."
        ],
        "server.error.photos_unsupported": [
            "it": "Formato file non supportato dall’app Foto.", "en": "File format not supported by the Photos app.", "zh": "“照片”应用不支持该文件格式。",
            "fr": "Format de fichier non pris en charge par l’app Photos.", "de": "Dateiformat wird von der Fotos-App nicht unterstützt.", "ja": "写真アプリでサポートされていないファイル形式です。", "es": "Formato de archivo no compatible con la app Fotos."
        ],
        "server.error.start_failed_fmt": [
            "it": "Impossibile avviare il server: %@", "en": "Could not start server: %@", "zh": "无法启动服务器：%@",
            "fr": "Impossible de démarrer le serveur : %@", "de": "Server konnte nicht gestartet werden: %@", "ja": "サーバーを開始できませんでした: %@", "es": "No se pudo iniciar el servidor: %@"
        ],
        "server.help.card": [
            "it": "Scheda test animata, immagine e video in loop mantengono le modalità sorgente di test del server Mac.", "en": "Animated test card, image, and looped video preserve the Mac server's test-source modes.", "zh": "动态测试卡、图片与循环视频模式与 Mac 服务器的测试源模式完全一致。",
            "fr": "La mire animée, l’image et la vidéo en boucle conservent les modes de test du serveur Mac.", "de": "Animiertes Testbild, Bild und Endlosvideo bieten dieselben Testquellen wie der Mac-Server.", "ja": "アニメーションテストカード、画像、ループ動画はMacサーバーのテストソースモードと同様に動作します。", "es": "La carta de ajuste animada, la imagen y el vídeo en bucle conservan los modos de prueba del servidor Mac."
        ],
        "server.help.image": [
            "it": "L’immagine selezionata viene copiata nella sandbox dell’app e trasmessa con codifica PyrowaveCast.", "en": "The selected image is copied into the app sandbox and streamed with PyrowaveCast encoding.", "zh": "所选图片将复制到应用沙盒并通过 PyrowaveCast 编码进行串流。",
            "fr": "L’image sélectionnée est copiée dans le bac à sable de l’app et diffusée avec l’encodage PyrowaveCast.", "de": "Das ausgewählte Bild wird in die App-Sandbox kopiert und mit PyrowaveCast-Codierung gestreamt.", "ja": "選択された画像はアプリのサンドボックスにコピーされ、PyrowaveCastエンコードで配信されます。", "es": "La imagen seleccionada se copia en el entorno aislado de la app y se transmite con codificación PyrowaveCast."
        ],
        "server.help.screen_ios27": [
            "it": "La condivisione schermo di sistema usa il selettore ScreenCaptureKit di iOS 27. Conferma il prompt di sistema.", "en": "Full system screen sharing uses the iOS 27 ScreenCaptureKit picker. Confirm the system prompt.", "zh": "系统屏幕共享使用 iOS 27 ScreenCaptureKit 选择器，请在系统弹窗中确认。",
            "fr": "Le partage d’écran système utilise le sélecteur ScreenCaptureKit d’iOS 27. Confirmez l’invite système.", "de": "Die System-Bildschirmfreigabe nutzt die iOS 27 ScreenCaptureKit-Auswahl. Bestätigen Sie den Systemdialog.", "ja": "システム画面共有はiOS 27のScreenCaptureKitピッカーを使用します。システムプロンプトを確認してください。", "es": "El uso compartido de pantalla del sistema usa el selector ScreenCaptureKit de iOS 27. Confirma el aviso del sistema."
        ],
        "server.help.screen_older_ios": [
            "it": "La condivisione schermo di sistema richiede iOS 27 o successivo. Usa scheda test, immagine o video su questo dispositivo.", "en": "System screen sharing requires iOS 27 or later. Use a test card, image, or video on this device.", "zh": "系统屏幕共享需要 iOS 27 或更高版本。请在此设备上使用测试卡、图片或视频模式。",
            "fr": "Le partage d’écran système nécessite iOS 27 ou ultérieur. Utilisez une mire, une image ou une vidéo sur cet appareil.", "de": "System-Bildschirmfreigabe erfordert iOS 27 oder neuer. Nutzen Sie Testbild, Bild oder Video auf diesem Gerät.", "ja": "システム画面共有にはiOS 27以降が必要です。このデバイスではテストカード、画像、またはビデオを使用してください。", "es": "Compartir la pantalla del sistema requiere iOS 27 o posterior. Usa carta de ajuste, imagen o vídeo en este dispositivo."
        ],
        "server.help.video": [
            "it": "Il video selezionato viene copiato nella sandbox dell’app e riprodotto in loop come sorgente stream.", "en": "The selected video is copied into the app sandbox and looped as the stream source.", "zh": "所选视频将复制到应用沙盒并循环播放作为串流源。",
            "fr": "La vidéo sélectionnée est copiée dans le bac à sable de l’app et lue en boucle comme source du flux.", "de": "Das ausgewählte Video wird in die App-Sandbox kopiert und in Endlosschleife als Stream-Quelle genutzt.", "ja": "選択されたビデオはアプリのサンドボックスにコピーされ、ストリームソースとしてループ再生されます。", "es": "El vídeo seleccionado se copia en el entorno aislado de la app y se reproduce en bucle como fuente."
        ],
        "server.log.permission_missing_warning": [
            "it": "Attenzione: permesso \"Registrazione schermo\" non attivo. Segui la guida passo-passo in Impostazioni di Sistema → Privacy e sicurezza e riavvia PyrowaveCast.", "en": "Warning: \"Screen Recording\" permission is not active. Follow the step-by-step guide in System Settings → Privacy & Security and restart PyrowaveCast.", "zh": "警告：“屏幕录制”权限未开启。请按照“系统设置 → 隐私与安全性”中的分步指南操作并重启 PyrowaveCast。",
            "fr": "Attention : l’autorisation « Enregistrement de l’écran » n’est pas active. Suivez le guide dans Réglages Système → Confidentialité et sécurité puis relancez PyrowaveCast.", "de": "Warnung: Berechtigung „Bildschirmaufnahme“ ist nicht aktiv. Folgen Sie der Anleitung unter Systemeinstellungen → Datenschutz & Sicherheit und starten Sie PyrowaveCast neu.", "ja": "警告: 「画面収録」の権限が有効ではありません。「システム設定 → プライバシーとセキュリティ」のガイドに従って設定し、PyrowaveCastを再起動してください。", "es": "Atención: el permiso «Grabación de pantalla» no está activo. Sigue la guía en Ajustes del Sistema → Privacidad y seguridad y reinicia PyrowaveCast."
        ],
        "server.log.started_port_fmt": [
            "it": "Server avviato sulla porta %d", "en": "Server started on port %d", "zh": "服务器已在端口 %d 启动",
            "fr": "Serveur démarré sur le port %d", "de": "Server gestartet auf Port %d", "ja": "ポート %d でサーバーを開始しました", "es": "Servidor iniciado en el puerto %d"
        ],
        "server.log_title": [
            "it": "Registro del server", "en": "Server log", "zh": "服务器日志",
            "fr": "Journal du serveur", "de": "Server-Protokoll", "ja": "サーバーログ", "es": "Registro del servidor"
        ],
        "server.mode.card": [
            "it": "Scheda test", "en": "Test card", "zh": "测试卡",
            "fr": "Mire de test", "de": "Testbild", "ja": "テストカード", "es": "Carta de ajuste"
        ],
        "server.mode.image": [
            "it": "Immagine", "en": "Image", "zh": "图片",
            "fr": "Image", "de": "Bild", "ja": "画像", "es": "Imagen"
        ],
        "server.mode.screen": [
            "it": "Schermo", "en": "Screen", "zh": "屏幕",
            "fr": "Écran", "de": "Bildschirm", "ja": "画面", "es": "Pantalla"
        ],
        "server.mode.video": [
            "it": "Video", "en": "Video", "zh": "视频",
            "fr": "Vidéo", "de": "Video", "ja": "ビデオ", "es": "Vídeo"
        ],
        "server.no_file_selected": [
            "it": "Nessun file selezionato", "en": "No file selected", "zh": "未选择文件",
            "fr": "Aucun fichier sélectionné", "de": "Keine Datei ausgewählt", "ja": "ファイルが選択されていません", "es": "Ningún archivo seleccionado"
        ],
        "server.no_image_selected": [
            "it": "Nessuna immagine selezionata", "en": "No image selected", "zh": "未选择图片",
            "fr": "Aucune image sélectionnée", "de": "Kein Bild ausgewählt", "ja": "画像が選択されていません", "es": "Ninguna imagen seleccionada"
        ],
        "server.no_video_selected": [
            "it": "Nessun video selezionato", "en": "No video selected", "zh": "未选择视频",
            "fr": "Aucune vidéo sélectionnée", "de": "Kein Video ausgewählt", "ja": "ビデオが選択されていません", "es": "Ningún vídeo seleccionado"
        ],
        "server.permission_guide_step1": [
            "it": "Clicca \"Apri Impostazioni di Sistema\" qui sotto: si aprirà direttamente Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e audio di sistema.", "en": "Click \"Open System Settings\" below to open System Settings → Privacy & Security → Screen & System Audio Recording.", "zh": "点击下方的“打开系统设置”：将直接打开“系统设置 → 隐私与安全性 → 录屏与系统录音”。",
            "fr": "Cliquez sur « Ouvrir les Réglages Système » ci-dessous pour ouvrir Réglages Système → Confidentialité et sécurité → Enregistrement de l’écran et de l’audio système.", "de": "Klicken Sie unten auf „Systemeinstellungen öffnen“, um Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme zu öffnen.", "ja": "下の「システム設定を開く」をクリックすると、「システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音」が開きます。", "es": "Haz clic en «Abrir Ajustes del Sistema» abajo para abrir Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema."
        ],
        "server.permission_guide_step2": [
            "it": "Se \"PyrowaveCast\" è già nella lista, attiva l’interruttore accanto al nome. Se NON compare nella lista, clicca il pulsante \"+\" in basso a sinistra, seleziona PyrowaveCast.app (usa \"Mostra nel Finder\" per trovarla subito) e clicca \"Apri\".", "en": "If \"PyrowaveCast\" is already listed, enable its toggle. If it is NOT listed, click the \"+\" button at the bottom left, select PyrowaveCast.app (use \"Show in Finder\" to locate it quickly), and click \"Open\".", "zh": "如果列表中已有“PyrowaveCast”，请打开其开关。如果不在列表中，请点击左下角的“+”按钮，选择 PyrowaveCast.app（可使用“在访达中显示”快速定位）并点击“打开”。",
            "fr": "Si « PyrowaveCast » figure déjà dans la liste, activez son interrupteur. Sinon, cliquez sur le bouton « + » en bas à gauche, sélectionnez PyrowaveCast.app (utilisez « Afficher dans le Finder ») et cliquez sur « Ouvrir ».", "de": "Wenn „PyrowaveCast“ bereits aufgeführt ist, aktivieren Sie den Schalter. Andernfalls klicken Sie unten links auf „+“, wählen Sie PyrowaveCast.app aus (nutzen Sie „Im Finder zeigen“) und klicken Sie auf „Öffnen“.", "ja": "「PyrowaveCast」が一覧にある場合はスイッチをオンにします。一覧にない場合は左下の「+」をクリックし、PyrowaveCast.app（「Finderで表示」ですぐに見つかります）を選択して「開く」をクリックします。", "es": "Si «PyrowaveCast» ya aparece en la lista, activa su interruptor. Si NO aparece, haz clic en el botón «+» abajo a la izquierda, selecciona PyrowaveCast.app (usa «Mostrar en el Finder») y haz clic en «Abrir»."
        ],
        "server.permission_guide_step3": [
            "it": "Inserisci la password del Mac oppure usa Touch ID quando richiesto da macOS.", "en": "Enter your Mac password or use Touch ID when prompted by macOS.", "zh": "当 macOS 提示时，输入您的 Mac 密码或使用触控 ID。",
            "fr": "Saisissez le mot de passe de votre Mac ou utilisez Touch ID lorsque macOS vous le demande.", "de": "Geben Sie Ihr Mac-Passwort ein oder verwenden Sie Touch ID, wenn macOS Sie dazu auffordert.", "ja": "macOSに求められたら、Macのパスワードを入力するかTouch IDを使用します。", "es": "Introduce la contraseña de tu Mac o usa Touch ID cuando macOS lo solicite."
        ],
        "server.permission_guide_step4": [
            "it": "Quando macOS chiede \"Esci e riapri\", clicca \"Esci e riapri\" (oppure chiudi e riapri PyrowaveCast manualmente). Poi clicca \"Verifica\" e \"Avvia\".", "en": "When macOS prompts \"Quit & Reopen\", click \"Quit & Reopen\" (or restart PyrowaveCast manually). Then click \"Verify\" and \"Start\".", "zh": "当 macOS 提示“退出并重新打开”时，点击它（或手动重启 PyrowaveCast）。然后点击“验证”和“启动”。",
            "fr": "Lorsque macOS affiche « Quitter et rouvrir », cliquez dessus (ou relancez PyrowaveCast manuellement). Cliquez ensuite sur « Vérifier » puis « Démarrer ».", "de": "Wenn macOS „Beenden & erneut öffnen“ anzeigt, klicken Sie darauf (oder starten Sie PyrowaveCast manuell neu). Klicken Sie danach auf „Überprüfen“ und „Starten“.", "ja": "macOSに「終了して再度開く」と表示されたらクリックします（または手動で再起動します）。その後「確認」と「開始」をクリックしてください。", "es": "Cuando macOS pregunte «Salir y volver a abrir», haz clic en ello (o reinicia PyrowaveCast manualmente). Luego haz clic en «Verificar» e «Iniciar»."
        ],
        "server.permission_guide_title": [
            "it": "Guida passo-passo (Privacy e sicurezza)", "en": "Step-by-step guide (Privacy & Security)", "zh": "分步指南（隐私与安全性）",
            "fr": "Guide pas à pas (Confidentialité et sécurité)", "de": "Schritt-für-Schritt-Anleitung (Datenschutz & Sicherheit)", "ja": "ステップバイステップガイド（プライバシーとセキュリティ）", "es": "Guía paso a paso (Privacidad y seguridad)"
        ],
        "server.picker.choose_source": [
            "it": "Scegli da dove caricare il file", "en": "Choose where to load the file from", "zh": "选择文件来源",
            "fr": "Choisissez d’où charger le fichier", "de": "Wählen Sie aus, woher die Datei geladen werden soll", "ja": "ファイルの読み込み元を選択してください", "es": "Elige desde dónde cargar el archivo"
        ],
        "server.picker.files_app": [
            "it": "File", "en": "Files", "zh": "文件",
            "fr": "Fichiers", "de": "Dateien", "ja": "ファイル", "es": "Archivos"
        ],
        "server.picker.photos_app": [
            "it": "App Foto", "en": "Photos App", "zh": "照片应用",
            "fr": "App Photos", "de": "Fotos-App", "ja": "写真アプリ", "es": "App Fotos"
        ],
        "server.picker.select_image": [
            "it": "Seleziona immagine", "en": "Select image", "zh": "选择图片",
            "fr": "Sélectionner une image", "de": "Bild auswählen", "ja": "画像を選択", "es": "Seleccionar imagen"
        ],
        "server.picker.select_video": [
            "it": "Seleziona video", "en": "Select video", "zh": "选择视频",
            "fr": "Sélectionner une vidéo", "de": "Video auswählen", "ja": "ビデオを選択", "es": "Seleccionar vídeo"
        ],
        "server.preview_disabled": [
            "it": "Anteprima client disattivata (risparmio CPU/GPU)", "en": "Client preview disabled (saving CPU/GPU)", "zh": "客户端预览已关闭（节省 CPU/GPU）",
            "fr": "Aperçu client désactivé (économie CPU/GPU)", "de": "Client-Vorschau deaktiviert (spart CPU/GPU)", "ja": "クライアントプレビュー無効（CPU/GPU節約）", "es": "Vista previa desactivada (ahorro de CPU/GPU)"
        ],
        "server.preview_header": [
            "it": "Anteprima (ciò che riceve il client)", "en": "Preview (what the client receives)", "zh": "预览（客户端接收到的画面）",
            "fr": "Aperçu (ce que reçoit le client)", "de": "Vorschau (was der Client empfängt)", "ja": "プレビュー（クライアント受信映像）", "es": "Vista previa (lo que recibe el cliente)"
        ],
        "server.preview_start_prompt": [
            "it": "Avvia il server per vedere l’anteprima", "en": "Start the server to preview the stream", "zh": "启动服务器以预览串流画面",
            "fr": "Démarrez le serveur pour prévisualiser le flux", "de": "Server starten, um die Vorschau zu sehen", "ja": "プレビューするにはサーバーを開始してください", "es": "Inicia el servidor para ver la vista previa"
        ],
        "server.preview_waiting_frame": [
            "it": "In attesa del primo frame…", "en": "Waiting for first frame…", "zh": "正在等待第一帧…",
            "fr": "En attente de la première image…", "de": "Warte auf ersten Frame…", "ja": "最初のフレームを待機中…", "es": "Esperando el primer fotograma…"
        ],
        "server.screen_permission_active": [
            "it": "Registrazione schermo attiva", "en": "Screen Recording active", "zh": "屏幕录制权限已激活",
            "fr": "Enregistrement de l’écran actif", "de": "Bildschirmaufnahme aktiv", "ja": "画面収録が有効です", "es": "Grabación de pantalla activa"
        ],
        "server.screen_permission_required": [
            "it": "Permesso Registrazione schermo richiesto", "en": "Screen Recording permission required", "zh": "需要屏幕录制权限",
            "fr": "Autorisation d’enregistrement de l’écran requise", "de": "Berechtigung für Bildschirmaufnahme erforderlich", "ja": "画面収録の権限が必要です", "es": "Se requiere permiso de grabación de pantalla"
        ],
        "server.screen_resolution_info_fmt": [
            "it": "Risoluzione schermo server: %@ (verrà concordata automaticamente con i client).", "en": "Server screen resolution: %@ (automatically negotiated with clients).", "zh": "服务器屏幕分辨率：%@（将自动与客户端协商）。",
            "fr": "Résolution de l’écran du serveur : %@ (négociée automatiquement avec les clients).", "de": "Server-Bildschirmauflösung: %@ (wird automatisch mit Clients ausgehandelt).", "ja": "サーバー画面解像度: %@（クライアントと自動ネゴシエーションされます）。", "es": "Resolución de pantalla del servidor: %@ (se negociará automáticamente con los clientes)."
        ],
        "server.source": [
            "it": "Sorgente", "en": "Source", "zh": "信号源",
            "fr": "Source", "de": "Quelle", "ja": "ソース", "es": "Fuente"
        ],
        "server.stream_settings": [
            "it": "Impostazioni stream", "en": "Stream settings", "zh": "串流设置",
            "fr": "Paramètres de diffusion", "de": "Stream-Einstellungen", "ja": "ストリーム設定", "es": "Ajustes de transmisión"
        ],
        "server.test_modes_no_permission": [
            "it": "Le modalità di test non richiedono alcuna autorizzazione di sistema.", "en": "Test modes do not require any system permissions.", "zh": "测试模式不需要任何系统权限。",
            "fr": "Les modes de test ne nécessitent aucune autorisation système.", "de": "Testmodi benötigen keine Systemberechtigungen.", "ja": "テストモードはシステムの権限を必要としません。", "es": "Los modos de prueba no requieren ningún permiso del sistema."
        ],
        "server.title": [
            "it": "PyrowaveCast Server", "en": "PyrowaveCast Server", "zh": "PyrowaveCast 服务器",
            "fr": "Serveur PyrowaveCast", "de": "PyrowaveCast-Server", "ja": "PyrowaveCast サーバー", "es": "Servidor PyrowaveCast"
        ],
        "server.udp_port": [
            "it": "Porta UDP", "en": "UDP port", "zh": "UDP 端口",
            "fr": "Port UDP", "de": "UDP-Port", "ja": "UDP ポート", "es": "Puerto UDP"
        ],
        "settings.agreed_timeout_fmt": [
            "it": "Timeout riconnessione concordato: %ds", "en": "Agreed reconnect timeout: %ds", "zh": "协商重连超时: %d秒",
            "fr": "Délai de reconnexion convenu : %ds", "de": "Vereinbartes Wiederverbindungs-Timeout: %ds", "ja": "合意された再接続タイムアウト: %d秒", "es": "Tiempo límite de reconexión acordado: %ds"
        ],
        "settings.auto_target": [
            "it": "Target automatico", "en": "Auto target", "zh": "自动目标码率",
            "fr": "Cible auto", "de": "Auto-Ziel", "ja": "自動ターゲット", "es": "Objetivo auto"
        ],
        "settings.automatic_bitrate": [
            "it": "Bitrate automatico (ABR)", "en": "Automatic bitrate (ABR)", "zh": "自动码率 (ABR)",
            "fr": "Débit automatique (ABR)", "de": "Automatische Bitrate (ABR)", "ja": "自動ビットレート (ABR)", "es": "Tasa de bits automática (ABR)"
        ],
        "settings.bitrate_mbps": [
            "it": "Bitrate (Mb/s)", "en": "Bitrate (Mb/s)", "zh": "码率 (Mb/s)",
            "fr": "Débit (Mb/s)", "de": "Bitrate (Mb/s)", "ja": "ビットレート (Mb/s)", "es": "Tasa de bits (Mb/s)"
        ],
        "settings.crc_skipped_caption": [
            "it": "Checksum ignorati — massimo throughput, nessun controllo corruzione", "en": "Checksums skipped — max throughput, no corruption detection", "zh": "跳过校验和 — 最大吞吐量，不检测数据损坏",
            "fr": "Sommes de contrôle ignorées — débit maximal, sans détection d’erreur", "de": "Prüfsummen übersprungen — maximaler Durchsatz", "ja": "チェックサム省略 — 最大スループット・破損検出なし", "es": "Sumas omitidas — máximo rendimiento, sin detección de corrupción"
        ],
        "settings.crc_verification": [
            "it": "Verifica CRC32 frammenti", "en": "CRC32 fragment verification", "zh": "CRC32 分片校验",
            "fr": "Vérification CRC32 des fragments", "de": "CRC32-Fragmentprüfung", "ja": "CRC32 フラグメント検証", "es": "Verificación CRC32 de fragmentos"
        ],
        "settings.crc_verified_caption": [
            "it": "Checksum dei frammenti verificati (CRC parziale)", "en": "Fragment checksums verified (partial CRC)", "zh": "已启用分片校验（部分 CRC32）",
            "fr": "Sommes de contrôle des fragments vérifiées (CRC partiel)", "de": "Fragment-Prüfsummen aktiviert (Teil-CRC)", "ja": "フラグメントのチェックサムを検証（部分CRC）", "es": "Sumas de verificación activas (CRC parcial)"
        ],
        "settings.diagnostics": [
            "it": "Log e diagnostica", "en": "Logs & Diagnostics", "zh": "日志与诊断",
            "fr": "Journaux et diagnostics", "de": "Protokolle & Diagnose", "ja": "ログと診断", "es": "Registros y diagnóstico"
        ],
        "settings.fec_parity": [
            "it": "Parità FEC (2× LL / 1× HF)", "en": "FEC Parity (2× LL / 1× HF)", "zh": "FEC 冗余度 (2× LL / 1× HF)",
            "fr": "Parité FEC (2× LL / 1× HF)", "de": "FEC-Parität (2× LL / 1× HF)", "ja": "FEC パリティ (2× LL / 1× HF)", "es": "Paridad FEC (2× LL / 1× HF)"
        ],
        "settings.frame_rate": [
            "it": "Frame rate", "en": "Frame rate", "zh": "帧率",
            "fr": "Fréquence d’images", "de": "Bildrate", "ja": "フレームレート", "es": "Fotogramas por seg."
        ],
        "settings.height": [
            "it": "Altezza", "en": "Height", "zh": "高度",
            "fr": "Hauteur", "de": "Höhe", "ja": "高さ", "es": "Alto"
        ],
        "settings.language": [
            "it": "Lingua", "en": "Language", "zh": "语言",
            "fr": "Langue", "de": "Sprache", "ja": "言語", "es": "Idioma"
        ],
        "settings.quality": [
            "it": "Qualità", "en": "Quality", "zh": "画质",
            "fr": "Qualité", "de": "Qualität", "ja": "画質", "es": "Calidad"
        ],
        "settings.server_controlled_resolution": [
            "it": "Risoluzione impostata dal server (cattura schermo)", "en": "Resolution set by server (screen capture)", "zh": "分辨率由服务器决定（屏幕录制）",
            "fr": "Résolution définie par le serveur (capture d’écran)", "de": "Auflösung vom Server vorgegeben (Bildschirmaufnahme)", "ja": "サーバー側の画面収録解像度を使用", "es": "Resolución fijada por el servidor (captura de pantalla)"
        ],
        "settings.server_resolution_timeout_fmt": [
            "it": "Risoluzione cattura schermo del server · Timeout: %ds", "en": "Server screen capture resolution · Timeout: %ds", "zh": "服务器屏幕录制分辨率 · 超时: %d秒",
            "fr": "Résolution capture écran serveur · Délai : %ds", "de": "Server-Bildschirmauflösung · Timeout: %ds", "ja": "サーバー画面収録の解像度 · タイムアウト: %d秒", "es": "Resolución de captura del servidor · Tiempo límite: %ds"
        ],
        "settings.resolution_custom": [
            "it": "Personalizzata", "en": "Custom", "zh": "自定义",
            "fr": "Personnalisée", "de": "Benutzerdefiniert", "ja": "カスタム", "es": "Personalizada"
        ],
        "settings.resolution_preset": [
            "it": "Risoluzione", "en": "Resolution", "zh": "分辨率预设",
            "fr": "Résolution", "de": "Auflösung", "ja": "解像度プリセット", "es": "Resolución"
        ],
        "settings.resolution_server_screen": [
            "it": "Cattura schermo server", "en": "Server Screen Capture", "zh": "服务器屏幕录制",
            "fr": "Capture d’écran serveur", "de": "Server-Bildschirmaufnahme", "ja": "サーバー画面収録", "es": "Captura de pantalla del servidor"
        ],
        "settings.stream_request": [
            "it": "Parametri stream", "en": "Stream request", "zh": "串流参数",
            "fr": "Paramètres du flux", "de": "Stream-Einstellungen", "ja": "ストリーム設定", "es": "Parámetros de transmisión"
        ],
        "settings.width": [
            "it": "Larghezza", "en": "Width", "zh": "宽度",
            "fr": "Largeur", "de": "Breite", "ja": "幅", "es": "Ancho"
        ],
        "settings.wifi_and_fec": [
            "it": "Wi-Fi e Reed-Solomon FEC", "en": "Wi-Fi & Reed-Solomon FEC", "zh": "Wi-Fi 与 Reed-Solomon 前向纠错",
            "fr": "Wi-Fi et FEC Reed-Solomon", "de": "WLAN & Reed-Solomon-FEC", "ja": "Wi-Fi と Reed-Solomon FEC", "es": "Wi-Fi y FEC Reed-Solomon"
        ],
        "settings.wifi_jitter_mode": [
            "it": "Modalità buffer jitter Wi-Fi", "en": "Wi-Fi Jitter Buffer Mode", "zh": "Wi-Fi 抖动缓冲模式",
            "fr": "Mode tampon de gigue Wi-Fi", "de": "WLAN-Jitter-Puffermodus", "ja": "Wi-Fi ジッターバッファモード", "es": "Modo de búfer de jitter Wi-Fi"
        ],
        "sidebar.receiver_connected": [
            "it": "Ricevitore connesso", "en": "Receiver connected", "zh": "接收端已连接",
            "fr": "Récepteur connecté", "de": "Empfänger verbunden", "ja": "レシーバー接続済み", "es": "Receptor conectado"
        ],
        "sidebar.receiver_disconnected": [
            "it": "Ricevitore disconnesso", "en": "Receiver disconnected", "zh": "接收端未连接",
            "fr": "Récepteur déconnecté", "de": "Empfänger getrennt", "ja": "レシーバー未接続", "es": "Receptor desconectado"
        ],
        "sidebar.server_listening_fmt": [
            "it": "Server in ascolto su %d", "en": "Server listening on %d", "zh": "服务器正在监听端口 %d",
            "fr": "Serveur en écoute sur %d", "de": "Server lauscht auf %d", "ja": "サーバー待受中 (ポート %d)", "es": "Servidor escuchando en %d"
        ],
        "sidebar.server_stopped": [
            "it": "Server fermo", "en": "Server stopped", "zh": "服务器已停止",
            "fr": "Serveur arrêté", "de": "Server gestoppt", "ja": "サーバー停止中", "es": "Servidor detenido"
        ],
        "state.connecting": [
            "it": "Connessione in corso…", "en": "Connecting…", "zh": "正在连接…",
            "fr": "Connexion…", "de": "Verbinden…", "ja": "接続中…", "es": "Conectando…"
        ],
        "state.disconnected": [
            "it": "Disconnesso", "en": "Disconnected", "zh": "未连接",
            "fr": "Déconnecté", "de": "Getrennt", "ja": "未接続", "es": "Desconectado"
        ],
        "state.error_fmt": [
            "it": "Errore · %@", "en": "Error · %@", "zh": "错误 · %@",
            "fr": "Erreur · %@", "de": "Fehler · %@", "ja": "エラー · %@", "es": "Error · %@"
        ],
        "state.listening": [
            "it": "In ascolto", "en": "Listening", "zh": "正在监听",
            "fr": "En écoute", "de": "Bereit", "ja": "待受中", "es": "Escuchando"
        ],
        "state.reconnecting_fmt": [
            "it": "Riconnessione… (#%d · %ds)", "en": "Reconnecting… (#%d · %ds)", "zh": "正在重连… (#%d · %d秒)",
            "fr": "Reconnexion… (#%d · %ds)", "de": "Verbindung wird wiederhergestellt… (#%d · %ds)", "ja": "再接続中… (#%d · %d秒)", "es": "Reconectando… (#%d · %ds)"
        ],
        "state.stopped": [
            "it": "Fermo", "en": "Stopped", "zh": "已停止",
            "fr": "Arrêté", "de": "Gestoppt", "ja": "停止中", "es": "Detenido"
        ],
        "state.streaming": [
            "it": "In streaming", "en": "Streaming", "zh": "正在串流",
            "fr": "Diffusion en cours", "de": "Streaming aktiv", "ja": "ストリーミング中", "es": "Transmitiendo"
        ],
        "state.waiting_screen_permission": [
            "it": "In attesa del permesso schermo…", "en": "Waiting for screen permission…", "zh": "正在等待屏幕录制权限…",
            "fr": "En attente de l’autorisation d’écran…", "de": "Warte auf Bildschirmberechtigung…", "ja": "画面収録の権限を待機中…", "es": "Esperando permiso de pantalla…"
        ],
        "state.waiting_video": [
            "it": "Connesso · in attesa del video", "en": "Connected · waiting for video", "zh": "已连接 · 等待视频流",
            "fr": "Connecté · en attente de la vidéo", "de": "Verbunden · warte auf Video", "ja": "接続済み · ビデオ待機中", "es": "Conectado · esperando vídeo"
        ],
        "tab.receiver": [
            "it": "Ricevitore", "en": "Receiver", "zh": "接收端",
            "fr": "Récepteur", "de": "Empfänger", "ja": "レシーバー", "es": "Receptor"
        ],
        "tab.server": [
            "it": "Server", "en": "Server", "zh": "服务端",
            "fr": "Serveur", "de": "Server", "ja": "サーバー", "es": "Servidor"
        ],
        "tab.settings": [
            "it": "Impostazioni", "en": "Settings", "zh": "设置",
            "fr": "Réglages", "de": "Einstellungen", "ja": "設定", "es": "Ajustes"
        ]
    ]
}


// MARK: - App & Build Version Information

public enum SPPWBuildVersion: Sendable {
    public static let fallbackVersion = "0.6.19"
    public static let fallbackBuildNumber = "619"
    public static let fallbackCommit = "1f7c373"

    /// Formatted build version string, e.g. "v0.6.4 (build 604, c778763)".
    /// If commit information is not available, falls back to "v0.6.4 (build 604)".
    public static var current: String {
        let bundle = Bundle.main
        if let explicit = bundle.object(forInfoDictionaryKey: "PyrowaveBuildVersion") as? String,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }

        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackVersion
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? fallbackBuildNumber
        let commit = (bundle.object(forInfoDictionaryKey: "PyrowaveGitCommit") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "GitCommit") as? String)
            ?? fallbackCommit

        return formatted(version: version, build: build, commit: commit)
    }

    public static func formatted(version: String, build: String, commit: String?) -> String {
        let trimmedCommit = commit?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCommit, !trimmedCommit.isEmpty {
            return "v\(version) (build \(build), \(trimmedCommit))"
        } else if !build.isEmpty {
            return "v\(version) (build \(build))"
        } else {
            return "v\(version)"
        }
    }
}

