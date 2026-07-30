import Darwin
import Foundation

/// Ask the kernel for a free TCP port on 127.0.0.1 before spawning
/// `macprovider-cli serve`. The CLI defaults to port 8080 for its local
/// HTTP inference endpoint and has no auto-fallback if that port is
/// occupied. On any developer Mac running a Node dev server / Rails app /
/// jaeger / anything on 8080, the CLI dies with
/// `Error: bind(...): Address already in use (errno: 48)` before it ever
/// opens the control socket — reproduced on the 2026-07-05 v1.8.4 smoke.
///
/// The probe binds a socket to `127.0.0.1:0` (kernel picks a free port),
/// records the assigned port, closes the socket, and returns the number.
/// There is a small race between our close and the CLI's bind, but the
/// window is <100ms in practice and the fallback is the CLI's own bind
/// error — same failure mode as before, no regression.
enum FreePortProbe {
    /// Returned when no ephemeral TCP port could be allocated. In practice
    /// this only fires on a machine that has exhausted its ephemeral range
    /// (very rare); the CLI's own bind will then produce the same error
    /// with better context.
    enum ProbeError: Error {
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case sockNameFailed(errno: Int32)
    }

    /// Probe a free TCP port on 127.0.0.1 and return the kernel-assigned
    /// port number. The probing socket is closed before this returns.
    static func probe() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ProbeError.socketCreationFailed(errno: errno) }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0  // kernel picks
        let bindResult = withUnsafePointer(to: &addr) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ProbeError.bindFailed(errno: errno) }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.getsockname(sock, sockaddrPtr, &boundLen)
            }
        }
        guard nameResult == 0 else { throw ProbeError.sockNameFailed(errno: errno) }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        return port
    }
}
