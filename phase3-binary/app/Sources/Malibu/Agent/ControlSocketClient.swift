import Darwin
import Foundation

// Newline-delimited JSON framing over a Unix domain socket connected to
// macprovider-cli's ControlSocket server. One connection, one writer, one reader.
//
// AUDIT R2 CODE H1 fix: the read loop no longer runs on the actor. Previously
// `Task { await self.readLoop(...) }` was actor-isolated, so a blocking
// `Darwin.read` held the actor and starved every other call (`send`, `close`).
// The typical failure was Quit-and-Uninstall — the shutdown_request send would
// queue behind the blocked read, and NSApp.terminate never fired.
//
// The new design: reads happen on a detached background task that yields
// decoded frames directly through the actor-independent
// AsyncStream.Continuation. The actor still owns the fd (for send/close) but
// never awaits the read.

actor ControlSocketClient {
    private let socketPath: String
    private var fd: Int32 = -1
    private var streamContinuation: AsyncStream<ControlFrame>.Continuation?
    private var readerTask: Task<Void, Never>?

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
        // Cancel reader FIRST so the detached task exits before we free the fd.
        readerTask?.cancel(); readerTask = nil
        if fd >= 0 {
            // Shutdown wakes any blocked read(); close finalizes.
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        streamContinuation?.finish()
    }

    // MARK: - private

    private func attach(fd: Int32) {
        self.fd = fd
        // AUDIT R2 CODE H1 fix: detach the read loop from the actor. Capture
        // the fd and the Sendable continuation; do the blocking read + parse
        // on a background thread without ever awaiting the actor.
        let capturedContinuation = self.streamContinuation
        readerTask = Task.detached(priority: .utility) {
            Self.blockingReadLoop(fd: fd, continuation: capturedContinuation)
        }
    }

    private static func blockingReadLoop(
        fd: Int32,
        continuation: AsyncStream<ControlFrame>.Continuation?
    ) {
        var buffer = Data()
        let chunk = 4096
        // AUDIT R1 LOW L1 hardening carried into R2: cap the accumulated
        // pre-newline buffer at 1 MiB so a malformed peer cannot OOM the app.
        let maxFrameBytes = 1 << 20
        var raw = [UInt8](repeating: 0, count: chunk)
        while !Task.isCancelled {
            let n = raw.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, chunk) }
            if n <= 0 { break }
            buffer.append(raw, count: n)
            if buffer.count > maxFrameBytes { break }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard !line.isEmpty, let frame = try? ControlCodec.decode(line) else { continue }
                continuation?.yield(frame)
            }
        }
        continuation?.finish()
    }
}
