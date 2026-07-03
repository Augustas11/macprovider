import Darwin
import Foundation

// Newline-delimited JSON framing over a Unix domain socket connected to
// macprovider-cli's ControlSocket server. One connection, one writer, one reader.

actor ControlSocketClient {
    private let socketPath: String
    private var fd: Int32 = -1
    private var reader: Task<Void, Never>?
    private var streamContinuation: AsyncStream<ControlFrame>.Continuation?

    let stream: AsyncStream<ControlFrame>

    init(socketPath: String) {
        self.socketPath = socketPath
        var localContinuation: AsyncStream<ControlFrame>.Continuation!
        self.stream = AsyncStream { localContinuation = $0 }
        self.streamContinuation = localContinuation
    }

    func connect(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(timeout)
                repeat {
                    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
                    guard sock >= 0 else {
                        cont.resume(throwing: POSIXError(.EACCES)); return
                    }
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    _ = self.socketPath.withCString { src in
                        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { dst in
                                _ = strncpy(dst, src, MemoryLayout.size(ofValue: addr.sun_path) - 1)
                            }
                        }
                    }
                    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
                    let result = withUnsafePointer(to: &addr) { rawPtr -> Int32 in
                        rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                            Darwin.connect(sock, sockaddrPtr, len)
                        }
                    }
                    if result == 0 {
                        Task { await self.attach(fd: sock); cont.resume() }
                        return
                    }
                    Darwin.close(sock)
                    Thread.sleep(forTimeInterval: 0.2)
                } while Date() < deadline
                cont.resume(throwing: POSIXError(.ETIMEDOUT))
            }
        }
    }

    func send(_ frame: ControlFrame) throws {
        guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
        var payload = try ControlCodec.encode(frame)
        payload.append(0x0A) // newline delimiter
        try payload.withUnsafeBytes { buffer in
            var written = 0
            let total = buffer.count
            let base = buffer.baseAddress!
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n <= 0 { throw POSIXError(.EIO) }
                written += n
            }
        }
    }

    func close() {
        reader?.cancel()
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        streamContinuation?.finish()
    }

    // MARK: - private

    private func attach(fd: Int32) {
        self.fd = fd
        reader = Task { await readLoop(fd: fd) }
    }

    private func readLoop(fd: Int32) async {
        var buffer = Data()
        let chunk = 4096
        var raw = [UInt8](repeating: 0, count: chunk)
        while !Task.isCancelled {
            let n = raw.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, chunk) }
            if n <= 0 { break }
            buffer.append(raw, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard !line.isEmpty, let frame = try? ControlCodec.decode(line) else { continue }
                deliver(frame)
            }
        }
        streamContinuation?.finish()
    }

    private func deliver(_ frame: ControlFrame) {
        streamContinuation?.yield(frame)
    }
}
