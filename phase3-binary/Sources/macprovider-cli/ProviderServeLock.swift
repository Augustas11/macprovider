import Darwin
import Foundation

enum ProviderServeLockError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case alreadyRunning(providerID: String?, port: Int, lockPath: String)
    case directoryCreateFailed(path: String, message: String)
    case openFailed(path: String, errnoCode: Int32)
    case lockFailed(path: String, errnoCode: Int32)

    var description: String {
        switch self {
        case .alreadyRunning(let providerID, let port, let lockPath):
            let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerText = provider.flatMap { $0.isEmpty ? nil : "provider_id \($0)" } ?? "this provider"
            return "\(providerText) is already starting or serving on port \(port) (lock: \(lockPath))"
        case .directoryCreateFailed(let path, let message):
            return "could not create provider singleton lock directory \(path): \(message)"
        case .openFailed(let path, let errnoCode):
            return "could not open provider singleton lock \(path): \(String(cString: strerror(errnoCode)))"
        case .lockFailed(let path, let errnoCode):
            return "could not acquire provider singleton lock \(path): \(String(cString: strerror(errnoCode)))"
        }
    }

    var errorDescription: String? { description }
}

final class ProviderServeLock {
    let url: URL
    private var fd: Int32?

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit {
        release()
    }

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/locks", isDirectory: true)
    }

    static func lockURL(port: Int, directory: URL = defaultDirectory()) -> URL {
        directory.appendingPathComponent(lockFileName(port: port))
    }

    static func lockFileName(port: Int) -> String {
        let raw = "port-\(port)"
        let readable = sanitizedFileComponent(raw, maxLength: 56)
        return "serve-\(readable)-\(stableDigest(raw)).lock"
    }

    static func acquire(
        providerID: String?,
        port: Int,
        directory: URL = defaultDirectory(),
        fileManager: FileManager = .default
    ) throws -> ProviderServeLock {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProviderServeLockError.directoryCreateFailed(
                path: directory.path,
                message: String(describing: error)
            )
        }

        let url = lockURL(port: port, directory: directory)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            throw ProviderServeLockError.openFailed(path: url.path, errnoCode: errno)
        }

        var lockResult: Int32
        repeat {
            lockResult = flock(fd, LOCK_EX | LOCK_NB)
        } while lockResult == -1 && errno == EINTR

        guard lockResult == 0 else {
            let lockErrno = errno
            Darwin.close(fd)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                throw ProviderServeLockError.alreadyRunning(
                    providerID: providerID,
                    port: port,
                    lockPath: url.path
                )
            }
            throw ProviderServeLockError.lockFailed(path: url.path, errnoCode: lockErrno)
        }

        writeLockMetadata(fd: fd, providerID: providerID, port: port)
        return ProviderServeLock(url: url, fd: fd)
    }

    func release() {
        guard let fd else { return }
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
        self.fd = nil
    }

    private static func writeLockMetadata(fd: Int32, providerID: String?, port: Int) {
        _ = Darwin.ftruncate(fd, 0)
        _ = Darwin.lseek(fd, 0, SEEK_SET)
        let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = "pid=\(getpid())\nprovider_id=\(provider)\nport=\(port)\n"
        payload.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
    }

    private static func sanitizedFileComponent(_ value: String, maxLength: Int) -> String {
        var output = ""
        output.reserveCapacity(min(value.count, maxLength))
        for scalar in value.unicodeScalars {
            guard output.count < maxLength else { break }
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                output.unicodeScalars.append(scalar)
            case 45, 46, 95:
                output.unicodeScalars.append(scalar)
            default:
                output.append("_")
            }
        }
        return output.isEmpty ? "provider" : output
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
