import CryptoKit
import Darwin
import Foundation

enum PrivacyLabConfigChangeCheckpointError: Error, Equatable, CustomStringConvertible {
    case invalidFD
    case invalidSocket
    case writeFailed
    case timeout
    case eof
    case oversized
    case malformed
    case wrongNonce

    var description: String {
        switch self {
        case .invalidFD: return "privacy lab config checkpoint fd must be an inherited descriptor >= 3"
        case .invalidSocket: return "privacy lab config checkpoint fd must be a connected AF_UNIX socket"
        case .writeFailed: return "privacy lab config checkpoint write failed"
        case .timeout: return "privacy lab config checkpoint timed out"
        case .eof: return "privacy lab config checkpoint closed before ack"
        case .oversized: return "privacy lab config checkpoint ack exceeded size limit"
        case .malformed: return "privacy lab config checkpoint ack was malformed"
        case .wrongNonce: return "privacy lab config checkpoint ack nonce mismatch"
        }
    }
}

struct PrivacyLabConfigChangeCheckpoint {
    static let schemaVersion = 1
    static let readyEvent = "privacy_lab_config_change_checkpoint_ready"
    static let ackEvent = "privacy_lab_config_change_checkpoint_ack"
    static let maxFrameBytes = 4096
    static let timeoutMilliseconds: Int32 = 2_000

    private let socket: OwnedCheckpointSocket
    private let nonceFactory: () -> String

    init(fd: Int32, nonceFactory: @escaping () -> String = PrivacyLabConfigChangeCheckpoint.makeNonce) throws {
        guard fd >= 3 else { throw PrivacyLabConfigChangeCheckpointError.invalidFD }
        let ownedFD = Darwin.fcntl(fd, F_DUPFD_CLOEXEC, 3)
        guard ownedFD >= 0 else { throw PrivacyLabConfigChangeCheckpointError.invalidFD }
        do {
            try Self.validateConnectedUnixSocket(ownedFD)
        } catch {
            Darwin.close(ownedFD)
            throw error
        }
        self.socket = OwnedCheckpointSocket(fd: ownedFD)
        self.nonceFactory = nonceFactory
    }

    func signalReady(scope: PrivacyLabIdentityScope) throws {
        let fd = try socket.takeForOneShot()
        defer { Darwin.close(fd) }
        let nonce = nonceFactory()
        let frame: [String: Any] = [
            "event": Self.readyEvent,
            "nonce": nonce,
            "pid": Int(Darwin.getpid()),
            "root_digest": Self.rootDigest(scope.stateRoot),
            "schema_version": Self.schemaVersion,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) + Data([0x0a])
        guard data.count <= Self.maxFrameBytes else {
            throw PrivacyLabConfigChangeCheckpointError.oversized
        }
        let deadline = Self.monotonicMilliseconds() + Int64(Self.timeoutMilliseconds)
        try writeAll(data, fd: fd, deadline: deadline)
        let ack = try readAck(fd: fd, deadline: deadline)
        guard Set(ack.keys) == ["event", "nonce", "schema_version"],
              ack["event"] as? String == Self.ackEvent,
              ack["schema_version"] as? Int == Self.schemaVersion,
              let ackNonce = ack["nonce"] as? String else {
            throw PrivacyLabConfigChangeCheckpointError.malformed
        }
        guard ackNonce == nonce else { throw PrivacyLabConfigChangeCheckpointError.wrongNonce }
    }

    private static func validateConnectedUnixSocket(_ fd: Int32) throws {
        var type: Int32 = 0
        var typeLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeLength) == 0,
              type == SOCK_STREAM else {
            throw PrivacyLabConfigChangeCheckpointError.invalidSocket
        }
        var noSigpipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PrivacyLabConfigChangeCheckpointError.invalidSocket
        }

        var address = sockaddr_storage()
        var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getpeername(fd, sockaddrPointer, &addressLength)
            }
        }
        guard result == 0, address.ss_family == sa_family_t(AF_UNIX) else {
            throw PrivacyLabConfigChangeCheckpointError.invalidSocket
        }
    }

    private static func rootDigest(_ root: URL) -> String {
        Data(SHA256.hash(data: Data(root.path.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeNonce() -> String {
        "\(UInt64.random(in: UInt64.min...UInt64.max))-\(UInt64.random(in: UInt64.min...UInt64.max))"
    }

    private func writeAll(_ data: Data, fd: Int32, deadline: Int64) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                let result = Darwin.send(fd, base.advanced(by: written), data.count - written, MSG_DONTWAIT)
                if result > 0 {
                    written += result
                } else if result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else {
                    throw PrivacyLabConfigChangeCheckpointError.writeFailed
                }
            }
        }
    }

    private func readAck(fd: Int32, deadline: Int64) throws -> [String: Any] {
        var buffer = [UInt8]()
        while true {
            try wait(fd: fd, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            let count = Darwin.recv(fd, &byte, 1, MSG_DONTWAIT)
            if count == 0 {
                throw PrivacyLabConfigChangeCheckpointError.eof
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw PrivacyLabConfigChangeCheckpointError.eof
            }
            if byte == 0x0a {
                break
            }
            buffer.append(byte)
            if buffer.count > Self.maxFrameBytes {
                throw PrivacyLabConfigChangeCheckpointError.oversized
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(buffer)) as? [String: Any] else {
            throw PrivacyLabConfigChangeCheckpointError.malformed
        }
        return object
    }

    private func wait(fd: Int32, events: Int16, deadline: Int64) throws {
        while true {
            let remaining = deadline - Self.monotonicMilliseconds()
            guard remaining > 0 else { throw PrivacyLabConfigChangeCheckpointError.timeout }
            var pollDescriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = Darwin.poll(&pollDescriptor, 1, Int32(min(remaining, Int64(Self.timeoutMilliseconds))))
            if ready > 0 {
                if (pollDescriptor.revents & Int16(POLLNVAL)) != 0 {
                    throw PrivacyLabConfigChangeCheckpointError.invalidSocket
                }
                if (pollDescriptor.revents & events) != 0 {
                    return
                }
                if (pollDescriptor.revents & Int16(POLLHUP)) != 0 {
                    throw events == Int16(POLLOUT)
                        ? PrivacyLabConfigChangeCheckpointError.writeFailed
                        : PrivacyLabConfigChangeCheckpointError.eof
                }
                if (pollDescriptor.revents & Int16(POLLERR)) != 0 {
                    throw PrivacyLabConfigChangeCheckpointError.writeFailed
                }
            } else if ready < 0 && errno == EINTR {
                continue
            } else {
                throw PrivacyLabConfigChangeCheckpointError.timeout
            }
        }
    }

    private static func monotonicMilliseconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000 + Int64(ts.tv_nsec) / 1_000_000
    }
}

private final class OwnedCheckpointSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            Darwin.close(current)
        }
    }

    func takeForOneShot() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw PrivacyLabConfigChangeCheckpointError.invalidSocket }
        let current = fd
        fd = -1
        return current
    }
}
