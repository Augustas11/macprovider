import Darwin
import Foundation

// Issue #2084 stage transport: one TCP link between two pipeline stages. POSIX
// sockets with TCP_NODELAY so a 14 KiB decode activation is not held back by Nagle,
// a heartbeat thread so a silent peer is detected while the other side waits, and
// typed errors instead of traps when the peer goes away.

public enum ShardLinkError: Error, Equatable, Sendable {
    case resolveFailed(host: String)
    case socketFailed(operation: String, errno: Int32)
    case connectTimedOut
    case acceptTimedOut
    /// The receive deadline passed while the peer was still heartbeating.
    case receiveTimedOut
    /// No byte (frame or heartbeat) arrived for longer than the liveness window.
    case peerDead(silentMilliseconds: Int)
    case peerClosed
    case sendTimedOut
    case closed
    case frame(ShardFrameError)
}

public struct ShardLinkConfiguration: Equatable, Sendable {
    public var groupEpoch: UInt64
    public var heartbeatInterval: TimeInterval
    /// The peer is dead after this many heartbeat intervals with no byte received.
    public var missedHeartbeatLimit: Int
    public var sendTimeout: TimeInterval
    public var limits: ShardFrameLimits

    public init(
        groupEpoch: UInt64,
        heartbeatInterval: TimeInterval = 0.1,
        missedHeartbeatLimit: Int = 3,
        sendTimeout: TimeInterval = 5,
        limits: ShardFrameLimits = ShardFrameLimits()
    ) {
        self.groupEpoch = groupEpoch
        self.heartbeatInterval = heartbeatInterval
        self.missedHeartbeatLimit = missedHeartbeatLimit
        self.sendTimeout = sendTimeout
        self.limits = limits
    }

    var livenessWindow: TimeInterval {
        heartbeatInterval * Double(max(1, missedHeartbeatLimit))
    }
}

public struct ShardLinkStatistics: Equatable, Sendable {
    public var framesSent: UInt64 = 0
    public var framesReceived: UInt64 = 0
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var heartbeatsSent: UInt64 = 0
    public var heartbeatsReceived: UInt64 = 0
}

public final class ShardStageListener: @unchecked Sendable {
    private let fd: Int32
    public let port: UInt16

    /// Bind and listen. `port` 0 picks an ephemeral port, read back from `port`.
    public init(host: String, port: UInt16) throws {
        var address = try ShardSocketAddress.resolve(host: host, port: port)
        let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ShardLinkError.socketFailed(operation: "socket", errno: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let bound = address.withSockaddr { bind(fd, $0, $1) }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ShardLinkError.socketFailed(operation: "bind", errno: code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ShardLinkError.socketFailed(operation: "listen", errno: code)
        }
        address = try ShardSocketAddress.local(of: fd)
        self.fd = fd
        self.port = address.port
    }

    deinit { Darwin.close(fd) }

    public func accept(timeout: TimeInterval, configuration: ShardLinkConfiguration) throws -> ShardStageLink {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, ShardSocketAddress.pollMilliseconds(timeout))
        if ready == 0 { throw ShardLinkError.acceptTimedOut }
        guard ready > 0 else { throw ShardLinkError.socketFailed(operation: "poll", errno: errno) }
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { throw ShardLinkError.socketFailed(operation: "accept", errno: errno) }
        return try ShardStageLink(connectedSocket: client, configuration: configuration)
    }
}

public final class ShardStageLink: @unchecked Sendable {
    public let configuration: ShardLinkConfiguration
    private let fd: Int32

    // Writers (caller and heartbeat thread) serialize on sendLock; sequence numbers are
    // assigned under it so the wire order always matches the sequence order.
    private let sendLock = NSLock()
    private var nextSendSequence: UInt64 = 0

    // One receiver at a time.
    private let receiveLock = NSLock()
    private var receiveState: ShardLinkReceiveState
    /// Bytes of a not-yet-complete frame; never more than one frame (bounded by the cap).
    private var pending = Data()

    private let stateLock = NSLock()
    private var lastHeard: TimeInterval
    private var isClosed = false
    private var heartbeatsPaused = false
    private var stats = ShardLinkStatistics()
    private var heartbeatTimer: DispatchSourceTimer?

    public static func connect(
        host: String,
        port: UInt16,
        timeout: TimeInterval,
        configuration: ShardLinkConfiguration
    ) throws -> ShardStageLink {
        let address = try ShardSocketAddress.resolve(host: host, port: port)
        let deadline = ShardSocketAddress.now() + timeout
        // Retry refused connections until the deadline so a head can start before its tail.
        while true {
            let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw ShardLinkError.socketFailed(operation: "socket", errno: errno) }
            if address.withSockaddr({ Darwin.connect(fd, $0, $1) }) == 0 {
                return try ShardStageLink(connectedSocket: fd, configuration: configuration)
            }
            let code = errno
            Darwin.close(fd)
            guard code == ECONNREFUSED || code == ETIMEDOUT else {
                throw ShardLinkError.socketFailed(operation: "connect", errno: code)
            }
            if ShardSocketAddress.now() >= deadline { throw ShardLinkError.connectTimedOut }
            usleep(50_000)
        }
    }

    init(connectedSocket fd: Int32, configuration: ShardLinkConfiguration) throws {
        self.fd = fd
        self.configuration = configuration
        self.receiveState = ShardLinkReceiveState(groupEpoch: configuration.groupEpoch)
        self.lastHeard = ShardSocketAddress.now()
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size) == 0
        else {
            let code = errno
            Darwin.close(fd)
            throw ShardLinkError.socketFailed(operation: "setsockopt", errno: code)
        }
        var timeout = ShardSocketAddress.timeval(configuration.sendTimeout)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        startHeartbeats()
    }

    deinit {
        close()
    }

    public var statistics: ShardLinkStatistics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stats
    }

    /// Send one frame; the link assigns the sequence number and returns it.
    @discardableResult
    public func send(_ frame: ShardStageFrame) throws -> UInt64 {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard !closedFlag else { throw ShardLinkError.closed }
        var frame = frame
        frame.header.groupEpoch = configuration.groupEpoch
        frame.header.sequence = nextSendSequence
        let bytes: Data
        do {
            bytes = try ShardStageFrameCodec.encode(frame, limits: configuration.limits)
        } catch let error as ShardFrameError {
            throw ShardLinkError.frame(error)
        }
        try writeAll(bytes)
        nextSendSequence &+= 1
        stateLock.lock()
        stats.framesSent += 1
        stats.bytesSent += UInt64(bytes.count)
        if frame.header.kind == .heartbeat { stats.heartbeatsSent += 1 }
        stateLock.unlock()
        return frame.header.sequence
    }

    /// Receive the next non-heartbeat frame.
    ///
    /// Throws `receiveTimedOut` when `timeout` passes, `peerDead` when nothing at all
    /// (not even a heartbeat) arrived for the liveness window while waiting, and
    /// `peerClosed` on EOF. Silence before this call does not count against the peer:
    /// liveness is judged only over time spent waiting here.
    public func receive(timeout: TimeInterval) throws -> ShardStageFrame {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        let deadline = ShardSocketAddress.now() + timeout
        let waitStart = ShardSocketAddress.now()
        while true {
            // Frame bytes stay in `pending` until the whole frame is present, so a
            // receive that times out mid-frame leaves the stream aligned for the next one.
            try fill(upTo: ShardStageFrameCodec.fixedHeaderSize, deadline: deadline, waitStart: waitStart)
            let total: Int
            do {
                total = try ShardStageFrameCodec.frameLength(
                    fixedHeader: pending.prefix(ShardStageFrameCodec.fixedHeaderSize), limits: configuration.limits)
            } catch let error as ShardFrameError {
                throw ShardLinkError.frame(error)
            }
            try fill(upTo: total, deadline: deadline, waitStart: waitStart)
            let whole = Data(pending.prefix(total))
            pending.removeFirst(total)
            let frame: ShardStageFrame
            do {
                frame = try ShardStageFrameCodec.decode(whole, limits: configuration.limits)
                try receiveState.accept(frame.header)
            } catch let error as ShardFrameError {
                throw ShardLinkError.frame(error)
            }
            stateLock.lock()
            stats.framesReceived += 1
            stats.bytesReceived += UInt64(whole.count)
            if frame.header.kind == .heartbeat { stats.heartbeatsReceived += 1 }
            stateLock.unlock()
            if frame.header.kind != .heartbeat { return frame }
        }
    }

    /// Stop the heartbeat thread and close the socket. Idempotent.
    public func close() {
        stateLock.lock()
        let wasClosed = isClosed
        isClosed = true
        let timer = heartbeatTimer
        heartbeatTimer = nil
        stateLock.unlock()
        guard !wasClosed else { return }
        timer?.cancel()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    /// Test seam: stop emitting heartbeats while keeping the socket open, which is what
    /// a hung peer process looks like from the other end.
    public func pauseHeartbeatsForTesting() {
        stateLock.lock()
        heartbeatsPaused = true
        stateLock.unlock()
    }

    // MARK: - Internals

    private var closedFlag: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosed
    }

    private func startHeartbeats() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macprovider.shard-link.heartbeat"))
        let interval = configuration.heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let skip = self.isClosed || self.heartbeatsPaused
            self.stateLock.unlock()
            if skip { return }
            // A failed heartbeat surfaces on the next caller send/receive; the timer
            // never traps or retries on its own.
            _ = try? self.send(ShardStageFrame(header: ShardStageFrameHeader(
                kind: .heartbeat, groupEpoch: self.configuration.groupEpoch)))
        }
        stateLock.lock()
        heartbeatTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if written < 0, code == EINTR { continue }
                if written < 0, code == EAGAIN || code == EWOULDBLOCK { throw ShardLinkError.sendTimedOut }
                if code == EPIPE || code == ECONNRESET { throw ShardLinkError.peerClosed }
                if closedFlag { throw ShardLinkError.closed }
                throw ShardLinkError.socketFailed(operation: "write", errno: code)
            }
        }
    }

    /// Read from the socket until `pending` holds at least `count` bytes. Reads never
    /// ask for more than the missing bytes, so `pending` stays within one frame.
    private func fill(upTo count: Int, deadline: TimeInterval, waitStart: TimeInterval) throws {
        let window = configuration.livenessWindow
        // Poll in slices no longer than half a heartbeat so liveness is re-checked promptly.
        let slice = max(0.005, configuration.heartbeatInterval / 2)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while pending.count < count {
            let now = ShardSocketAddress.now()
            stateLock.lock()
            let heard = max(lastHeard, waitStart)
            let closed = isClosed
            stateLock.unlock()
            if closed { throw ShardLinkError.closed }
            if now - heard > window {
                throw ShardLinkError.peerDead(silentMilliseconds: Int((now - heard) * 1000))
            }
            if now >= deadline { throw ShardLinkError.receiveTimedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = min(slice, deadline - now, window - (now - heard))
            let ready = poll(&pfd, 1, ShardSocketAddress.pollMilliseconds(max(0, wait)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                if closedFlag { throw ShardLinkError.closed }
                throw ShardLinkError.socketFailed(operation: "poll", errno: errno)
            }
            let want = min(chunk.count, count - pending.count)
            let got = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, want) }
            if got > 0 {
                pending.append(contentsOf: chunk[0..<got])
                stateLock.lock()
                lastHeard = ShardSocketAddress.now()
                stateLock.unlock()
                continue
            }
            if got == 0 { throw ShardLinkError.peerClosed }
            let code = errno
            if code == EINTR || code == EAGAIN { continue }
            if code == ECONNRESET { throw ShardLinkError.peerClosed }
            if closedFlag { throw ShardLinkError.closed }
            throw ShardLinkError.socketFailed(operation: "read", errno: code)
        }
    }
}

/// IPv4/IPv6 socket address helpers shared by the listener and link.
struct ShardSocketAddress {
    var storage: sockaddr_storage
    var length: socklen_t

    var family: Int32 { Int32(storage.ss_family) }

    var port: UInt16 {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer -> UInt16 in
            if family == AF_INET6 {
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    static func resolve(host: String, port: UInt16) throws -> ShardSocketAddress {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw ShardLinkError.resolveFailed(host: host)
        }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        let length = first.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &storage) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(length)))
        }
        return ShardSocketAddress(storage: storage, length: length)
    }

    static func local(of fd: Int32) throws -> ShardSocketAddress {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw ShardLinkError.socketFailed(operation: "getsockname", errno: errno) }
        return ShardSocketAddress(storage: storage, length: length)
    }

    static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    static func pollMilliseconds(_ seconds: TimeInterval) -> Int32 {
        Int32(min(Double(Int32.max), (seconds * 1000).rounded(.up)))
    }

    static func timeval(_ seconds: TimeInterval) -> Darwin.timeval {
        let whole = floor(seconds)
        return Darwin.timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1e6))
    }
}
