import CryptoKit
import Foundation
import LocalAuthentication
import MacProviderCore
import Security
import Darwin

protocol ProviderCredentialStoring: Sendable {
    var statusSource: ProviderCredentialStatus.Source { get }
    func load(providerID: String) throws -> String?
    func importIfAbsentOrMatches(providerID: String, token: String) throws
    func replace(providerID: String, token: String) throws
    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws
    func deleteAll() throws
}

extension ProviderCredentialStoring {
    var statusSource: ProviderCredentialStatus.Source { .cliKeychain }
}

enum ProviderCredentialStoreError: Error, Equatable, CustomStringConvertible {
    case invalidProviderID
    case invalidToken
    case missing(providerID: String)
    case invalidStoredToken(providerID: String)
    case readFailed(providerID: String, status: OSStatus)
    case writeFailed(providerID: String, status: OSStatus)
    case deleteFailed(status: OSStatus)
    case verificationFailed(providerID: String)
    case conflict(providerID: String)
    case custodyLockFailed

    var description: String {
        switch self {
        case .invalidProviderID:
            return "provider credential store requires a non-empty provider_id"
        case .invalidToken:
            return "provider credential store requires a non-empty token"
        case .missing(let providerID):
            return "provider credential Keychain item is missing for \(providerID)"
        case .invalidStoredToken(let providerID):
            return "provider credential store contains invalid data for \(providerID)"
        case .readFailed(let providerID, let status):
            return "provider credential Keychain read failed for \(providerID) (status \(status))"
        case .writeFailed(let providerID, let status):
            return "provider credential Keychain write failed for \(providerID) (status \(status))"
        case .deleteFailed(let status):
            return "provider credential Keychain cleanup failed (status \(status))"
        case .verificationFailed(let providerID):
            return "provider credential Keychain verification failed for \(providerID)"
        case .conflict(let providerID):
            return "provider credential import conflicts with the authoritative Keychain item for \(providerID)"
        case .custodyLockFailed:
            return "provider credential mutation lock is unavailable"
        }
    }
}

enum ProtectedFileCredentialCustodyError: Error, Equatable, CustomStringConvertible {
    case unavailable(path: String, operation: String, errnoCode: Int32)
    case unsafe(path: String, reason: String)
    case duplicate(path: String)
    case tooLarge(path: String)

    var description: String {
        switch self {
        case .unavailable(let path, let operation, let errnoCode):
            return "protected credential storage \(operation) failed for \(path) (errno \(errnoCode))"
        case .unsafe(let path, let reason):
            return "protected credential storage rejected \(path): \(reason)"
        case .duplicate(let path):
            return "protected credential storage already contains \(path)"
        case .tooLarge(let path):
            return "protected credential storage rejected oversized data at \(path)"
        }
    }
}

/// Shared protected-file custody used only when the operator explicitly selects
/// the headless/fleet backend. Every namespace is serialized across processes,
/// and all secret writes are durable before the atomic rename becomes visible.
struct ProtectedFileCredentialCustody: Sendable {
    enum Namespace: String, Sendable {
        case providerBearers = "provider-bearers"
        case identityKeys = "identity-keys"
    }

    struct StoredData: Sendable {
        let data: Data
        let modifiedAt: Date
    }

    struct LockedDirectory {
        let descriptor: Int32
        let path: String

        func read(name: String, maximumBytes: Int = 64 * 1024) throws -> StoredData? {
            let filePath = URL(fileURLWithPath: path).appendingPathComponent(name).path
            let fd = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                if errno == ENOENT { return nil }
                throw ProtectedFileCredentialCustody.openError(path: filePath, operation: "open")
            }
            defer { close(fd) }
            let info = try ProtectedFileCredentialCustody.validateFile(
                fd: fd,
                path: filePath,
                maximumBytes: maximumBytes,
                allowEmpty: false
            )
            try validateNamedPath(name: name, matches: info)

            var data = Data()
            data.reserveCapacity(Int(info.st_size))
            var buffer = [UInt8](repeating: 0, count: min(4 * 1024, maximumBytes))
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProtectedFileCredentialCustodyError.unavailable(
                        path: filePath,
                        operation: "read",
                        errnoCode: errno
                    )
                }
                if count == 0 { break }
                guard data.count + count <= maximumBytes else {
                    throw ProtectedFileCredentialCustodyError.tooLarge(path: filePath)
                }
                data.append(buffer, count: count)
            }
            let seconds = TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            return StoredData(data: data, modifiedAt: Date(timeIntervalSince1970: seconds))
        }

        func add(name: String, data: Data, maximumBytes: Int = 64 * 1024) throws {
            try write(name: name, data: data, replaceExisting: false, maximumBytes: maximumBytes)
        }

        func replace(name: String, data: Data, maximumBytes: Int = 64 * 1024) throws {
            try write(name: name, data: data, replaceExisting: true, maximumBytes: maximumBytes)
        }

        func deleteIfPresent(name: String) throws {
            guard let existing = try inspect(name: name) else { return }
            try validateNamedPath(name: name, matches: existing)
            let filePath = URL(fileURLWithPath: path).appendingPathComponent(name).path
            guard unlinkat(descriptor, name, 0) == 0 else {
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: filePath,
                    operation: "delete",
                    errnoCode: errno
                )
            }
            try sync()
        }

        private func write(
            name: String,
            data: Data,
            replaceExisting: Bool,
            maximumBytes: Int
        ) throws {
            let filePath = URL(fileURLWithPath: path).appendingPathComponent(name).path
            guard !data.isEmpty else {
                throw ProtectedFileCredentialCustodyError.unsafe(path: filePath, reason: "empty data")
            }
            guard data.count <= maximumBytes else {
                throw ProtectedFileCredentialCustodyError.tooLarge(path: filePath)
            }
            let existing = try inspect(name: name, maximumBytes: maximumBytes)
            if existing != nil && !replaceExisting {
                throw ProtectedFileCredentialCustodyError.duplicate(path: filePath)
            }

            let temporaryName = ".\(name).tmp-\(UUID().uuidString.lowercased())"
            let temporaryPath = URL(fileURLWithPath: path).appendingPathComponent(temporaryName).path
            let fd = openat(
                descriptor,
                temporaryName,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard fd >= 0 else {
                throw ProtectedFileCredentialCustody.openError(path: temporaryPath, operation: "create temporary")
            }
            var removeTemporary = true
            defer {
                close(fd)
                if removeTemporary { _ = unlinkat(descriptor, temporaryName, 0) }
            }

            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw ProtectedFileCredentialCustodyError.unavailable(
                            path: temporaryPath,
                            operation: "write temporary",
                            errnoCode: errno
                        )
                    }
                    offset += count
                }
            }
            guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: temporaryPath,
                    operation: "chmod temporary",
                    errnoCode: errno
                )
            }
            let temporaryInfo = try ProtectedFileCredentialCustody.validateFile(
                fd: fd,
                path: temporaryPath,
                maximumBytes: maximumBytes,
                allowEmpty: false
            )
            guard fsync(fd) == 0 else {
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: temporaryPath,
                    operation: "sync temporary",
                    errnoCode: errno
                )
            }

            if let existing {
                guard replaceExisting else {
                    throw ProtectedFileCredentialCustodyError.duplicate(path: filePath)
                }
                try validateNamedPath(name: name, matches: existing)
                guard renameat(descriptor, temporaryName, descriptor, name) == 0 else {
                    throw ProtectedFileCredentialCustodyError.unavailable(
                        path: filePath,
                        operation: "rename temporary",
                        errnoCode: errno
                    )
                }
            } else if Darwin.renameatx_np(
                descriptor,
                temporaryName,
                descriptor,
                name,
                UInt32(RENAME_EXCL)
            ) != 0 {
                if errno == EEXIST {
                    throw ProtectedFileCredentialCustodyError.duplicate(path: filePath)
                }
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: filePath,
                    operation: "rename temporary",
                    errnoCode: errno
                )
            }
            removeTemporary = false
            try validateNamedPath(name: name, matches: temporaryInfo)
            try sync()
        }

        private func inspect(name: String, maximumBytes: Int = 64 * 1024) throws -> stat? {
            let filePath = URL(fileURLWithPath: path).appendingPathComponent(name).path
            let fd = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                if errno == ENOENT { return nil }
                throw ProtectedFileCredentialCustody.openError(path: filePath, operation: "open for validation")
            }
            defer { close(fd) }
            let info = try ProtectedFileCredentialCustody.validateFile(
                fd: fd,
                path: filePath,
                maximumBytes: maximumBytes,
                allowEmpty: false
            )
            try validateNamedPath(name: name, matches: info)
            return info
        }

        private func validateNamedPath(name: String, matches opened: stat) throws {
            var named = stat()
            guard fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  (named.st_mode & S_IFMT) == S_IFREG,
                  named.st_dev == opened.st_dev,
                  named.st_ino == opened.st_ino else {
                let filePath = URL(fileURLWithPath: path).appendingPathComponent(name).path
                throw ProtectedFileCredentialCustodyError.unsafe(path: filePath, reason: "path changed")
            }
        }

        private func sync() throws {
            guard fsync(descriptor) == 0 else {
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: path,
                    operation: "sync directory",
                    errnoCode: errno
                )
            }
        }
    }

    static let defaultRootDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/macprovider/protected-credentials-v1", isDirectory: true)

    let rootDirectory: URL

    init(rootDirectory: URL = Self.defaultRootDirectory) {
        self.rootDirectory = rootDirectory.absoluteURL
    }

    func providerDirectoryURL(namespace: Namespace, providerID: String) -> URL {
        rootDirectory
            .appendingPathComponent(namespace.rawValue, isDirectory: true)
            .appendingPathComponent(Self.providerDirectoryName(providerID), isDirectory: true)
    }

    func withLockedProviderDirectory<T>(
        namespace: Namespace,
        providerID: String,
        _ operation: (LockedDirectory) throws -> T
    ) throws -> T {
        let rootFD = try openRootDirectory()
        defer { close(rootFD) }
        let namespaceURL = rootDirectory.appendingPathComponent(namespace.rawValue, isDirectory: true)
        let namespaceFD = try Self.openPrivateDirectory(
            parentFD: rootFD,
            name: namespace.rawValue,
            path: namespaceURL.path
        )
        defer { close(namespaceFD) }
        let lockFD = try Self.openLock(directoryFD: namespaceFD, directoryPath: namespaceURL.path)
        defer { close(lockFD) }
        try Self.acquire(lockFD: lockFD, path: namespaceURL.path)
        defer { flock(lockFD, LOCK_UN) }

        let providerName = Self.providerDirectoryName(providerID)
        let providerURL = namespaceURL.appendingPathComponent(providerName, isDirectory: true)
        let providerFD = try Self.openPrivateDirectory(
            parentFD: namespaceFD,
            name: providerName,
            path: providerURL.path
        )
        defer { close(providerFD) }
        return try operation(LockedDirectory(descriptor: providerFD, path: providerURL.path))
    }

    func deleteAll(namespace: Namespace, fileName: String) throws {
        let rootFD = try openRootDirectory()
        defer { close(rootFD) }
        let namespaceURL = rootDirectory.appendingPathComponent(namespace.rawValue, isDirectory: true)
        let namespaceFD = try Self.openPrivateDirectory(
            parentFD: rootFD,
            name: namespace.rawValue,
            path: namespaceURL.path
        )
        defer { close(namespaceFD) }
        let lockFD = try Self.openLock(directoryFD: namespaceFD, directoryPath: namespaceURL.path)
        defer { close(lockFD) }
        try Self.acquire(lockFD: lockFD, path: namespaceURL.path)
        defer { flock(lockFD, LOCK_UN) }

        let names = try FileManager.default.contentsOfDirectory(atPath: namespaceURL.path)
        for name in names where name.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil {
            let providerURL = namespaceURL.appendingPathComponent(name, isDirectory: true)
            let providerFD = try Self.openPrivateDirectory(
                parentFD: namespaceFD,
                name: name,
                path: providerURL.path,
                createIfMissing: false
            )
            defer { close(providerFD) }
            try LockedDirectory(descriptor: providerFD, path: providerURL.path).deleteIfPresent(name: fileName)
        }
    }

    private func openRootDirectory() throws -> Int32 {
        var info = stat()
        let parent = rootDirectory.deletingLastPathComponent()
        try Self.prepareParentChain(parent)
        if lstat(rootDirectory.path, &info) != 0 {
            guard errno == ENOENT else {
                throw Self.openError(path: rootDirectory.path, operation: "inspect root")
            }
            if mkdir(rootDirectory.path, S_IRWXU) != 0 && errno != EEXIST {
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: rootDirectory.path,
                    operation: "create root",
                    errnoCode: errno
                )
            }
        }
        let fd = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw Self.openError(path: rootDirectory.path, operation: "open root")
        }
        do {
            try Self.validateDirectory(fd: fd, path: rootDirectory.path)
            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parentFD >= 0 else {
                throw Self.openError(path: parent.path, operation: "open root parent")
            }
            defer { close(parentFD) }
            try Self.validateNoMountTransition(parentFD: parentFD, childFD: fd, path: rootDirectory.path)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func prepareParentChain(_ parent: URL) throws {
        let standardized = parent.standardizedFileURL
        var current = URL(fileURLWithPath: standardized.path.hasPrefix("/") ? "/" : FileManager.default.currentDirectoryPath)
        let components = standardized.pathComponents.filter { $0 != "/" }
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT else {
                    throw openError(path: current.path, operation: "inspect parent")
                }
                if mkdir(current.path, S_IRWXU) != 0 && errno != EEXIST {
                    throw ProtectedFileCredentialCustodyError.unavailable(
                        path: current.path,
                        operation: "create parent",
                        errnoCode: errno
                    )
                }
                if lstat(current.path, &info) != 0 {
                    throw openError(path: current.path, operation: "inspect created parent")
                }
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                if current.path == "/var",
                   let target = try? symlinkTarget(path: current.path),
                   target == "private/var" || target == "/private/var" {
                    current = URL(fileURLWithPath: "/private/var", isDirectory: true)
                    continue
                }
                throw ProtectedFileCredentialCustodyError.unsafe(path: current.path, reason: "ancestor is a symlink")
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw ProtectedFileCredentialCustodyError.unsafe(path: current.path, reason: "ancestor is not a directory")
            }
            guard info.st_uid == geteuid() || info.st_uid == 0 else {
                throw ProtectedFileCredentialCustodyError.unsafe(path: current.path, reason: "ancestor has wrong owner")
            }
            guard (info.st_mode & 0o022) == 0 else {
                throw ProtectedFileCredentialCustodyError.unsafe(path: current.path, reason: "ancestor is group/world writable")
            }
        }
    }

    private static func symlinkTarget(path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count >= 0 else {
            throw openError(path: path, operation: "read symlink")
        }
        return String(cString: buffer)
    }

    private static func openPrivateDirectory(
        parentFD: Int32,
        name: String,
        path: String,
        createIfMissing: Bool = true
    ) throws -> Int32 {
        if createIfMissing, mkdirat(parentFD, name, S_IRWXU) != 0 && errno != EEXIST {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "create directory",
                errnoCode: errno
            )
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw openError(path: path, operation: "open directory")
        }
        do {
            try validateDirectory(fd: fd, path: path)
            try validateNoMountTransition(parentFD: parentFD, childFD: fd, path: path)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func openLock(directoryFD: Int32, directoryPath: String) throws -> Int32 {
        let path = URL(fileURLWithPath: directoryPath).appendingPathComponent(".custody.lock").path
        let fd = openat(
            directoryFD,
            ".custody.lock",
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { throw openError(path: path, operation: "open lock") }
        do {
            _ = try validateFile(fd: fd, path: path, maximumBytes: 0, allowEmpty: true)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func acquire(lockFD: Int32, path: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard (errno == EWOULDBLOCK || errno == EAGAIN), Date() < deadline else {
                throw ProtectedFileCredentialCustodyError.unavailable(
                    path: path,
                    operation: "acquire lock",
                    errnoCode: errno
                )
            }
            usleep(20_000)
        }
    }

    private static func validateDirectory(fd: Int32, path: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "stat directory",
                errnoCode: errno
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "not a directory")
        }
        guard info.st_uid == geteuid() else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "wrong owner")
        }
        guard (info.st_mode & 0o777) == S_IRWXU else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "mode is not 0700")
        }
        var fileSystem = statfs()
        guard fstatfs(fd, &fileSystem) == 0 else {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "stat filesystem",
                errnoCode: errno
            )
        }
        guard (fileSystem.f_flags & UInt32(MNT_LOCAL)) != 0 else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "filesystem is not local")
        }
        try rejectExtendedACL(fd: fd, path: path)
    }

    private static func validateNoMountTransition(parentFD: Int32, childFD: Int32, path: String) throws {
        var parent = stat()
        var child = stat()
        guard fstat(parentFD, &parent) == 0 else {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "stat parent directory",
                errnoCode: errno
            )
        }
        guard fstat(childFD, &child) == 0 else {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "stat child directory",
                errnoCode: errno
            )
        }
        guard parent.st_dev == child.st_dev else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "mount transition")
        }
    }

    @discardableResult
    private static func validateFile(
        fd: Int32,
        path: String,
        maximumBytes: Int,
        allowEmpty: Bool
    ) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "stat file",
                errnoCode: errno
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "not a regular file")
        }
        guard info.st_uid == geteuid() else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "wrong owner")
        }
        guard info.st_nlink == 1 else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "hard link")
        }
        guard (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "mode is not 0600")
        }
        try rejectExtendedACL(fd: fd, path: path)
        let minimumSize = allowEmpty ? 0 : 1
        guard info.st_size >= minimumSize else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "empty data")
        }
        guard info.st_size <= maximumBytes else {
            throw ProtectedFileCredentialCustodyError.tooLarge(path: path)
        }
        return info
    }

    private static func rejectExtendedACL(fd: Int32, path: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return }
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "inspect ACL",
                errnoCode: errno
            )
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else {
            throw ProtectedFileCredentialCustodyError.unavailable(
                path: path,
                operation: "inspect ACL",
                errnoCode: errno
            )
        }
        guard entry == nil else {
            throw ProtectedFileCredentialCustodyError.unsafe(path: path, reason: "extended ACL")
        }
    }

    private static func providerDirectoryName(_ providerID: String) -> String {
        SHA256.hash(data: Data(providerID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func openError(path: String, operation: String) -> ProtectedFileCredentialCustodyError {
        if errno == ELOOP {
            return .unsafe(path: path, reason: "symlink")
        }
        return .unavailable(path: path, operation: operation, errnoCode: errno)
    }
}

struct ProtectedFileProviderCredentialStore: ProviderCredentialStoring {
    static let tokenFileName = "provider-token.v1"
    let custody: ProtectedFileCredentialCustody

    var statusSource: ProviderCredentialStatus.Source { .protectedFile }

    init(rootDirectory: URL = ProtectedFileCredentialCustody.defaultRootDirectory) {
        custody = ProtectedFileCredentialCustody(rootDirectory: rootDirectory)
    }

    func load(providerID: String) throws -> String? {
        let providerID = try Self.normalizedProviderID(providerID)
        return try custody.withLockedProviderDirectory(namespace: .providerBearers, providerID: providerID) { directory in
            try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID)
        }
    }

    func importIfAbsentOrMatches(providerID: String, token: String) throws {
        let (providerID, token) = try Self.normalized(providerID: providerID, token: token)
        try custody.withLockedProviderDirectory(namespace: .providerBearers, providerID: providerID) { directory in
            if let current = try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID) {
                guard current == token else { throw ProviderCredentialStoreError.conflict(providerID: providerID) }
                return
            }
            do {
                try directory.add(name: Self.tokenFileName, data: Data(token.utf8))
            } catch ProtectedFileCredentialCustodyError.duplicate {
                guard try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID) == token else {
                    throw ProviderCredentialStoreError.conflict(providerID: providerID)
                }
            }
            guard try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID) == token else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
        }
    }

    func replace(providerID: String, token: String) throws {
        let (providerID, token) = try Self.normalized(providerID: providerID, token: token)
        try custody.withLockedProviderDirectory(namespace: .providerBearers, providerID: providerID) { directory in
            try directory.replace(name: Self.tokenFileName, data: Data(token.utf8))
            guard try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID) == token else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
        }
    }

    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws {
        let (providerID, token) = try Self.normalized(providerID: providerID, token: token)
        try custody.withLockedProviderDirectory(namespace: .providerBearers, providerID: providerID) { directory in
            do {
                if let current = try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID) {
                    guard current == token else { throw ProviderCredentialStoreError.conflict(providerID: providerID) }
                    return
                }
                try directory.add(name: Self.tokenFileName, data: Data(token.utf8))
            } catch ProviderCredentialStoreError.invalidStoredToken {
                try directory.replace(name: Self.tokenFileName, data: Data(token.utf8))
            }
            guard try Self.decodeToken(directory.read(name: Self.tokenFileName)?.data, providerID: providerID) == token else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
        }
    }

    func deleteAll() throws {
        try custody.deleteAll(namespace: .providerBearers, fileName: Self.tokenFileName)
    }

    func tokenURL(providerID: String) -> URL {
        custody.providerDirectoryURL(namespace: .providerBearers, providerID: providerID)
            .appendingPathComponent(Self.tokenFileName)
    }

    private static func normalized(providerID: String, token: String) throws -> (String, String) {
        let providerID = try normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }
        return (providerID, token)
    }

    private static func normalizedProviderID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\") else {
            throw ProviderCredentialStoreError.invalidProviderID
        }
        return value
    }

    private static func decodeToken(_ data: Data?, providerID: String) throws -> String? {
        guard let data else { return nil }
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw ProviderCredentialStoreError.invalidStoredToken(providerID: providerID)
        }
        return token
    }
}

/// CLI-owned provider bearer storage.
///
/// The standalone executable uses the login Keychain's default ACL rather than
/// a custom trusted-application ACL. macOS tracks the creator's designated
/// requirement for that default ACL, so release signing pins a stable explicit
/// identifier for update continuity. Every lookup is non-interactive: a locked
/// or inaccessible Keychain becomes an explicit recoverable error, never a
/// password prompt in a launchd session.
struct KeychainProviderCredentialStore: ProviderCredentialStoring {
    static let service = "live.malibu.provider.provider-token.v1"
    static let legacyService = "live.streamvc.macprovider.provider-token.v1"
    private static let mutationLock = NSLock()

    func load(providerID: String) throws -> String? {
        let providerID = try Self.normalizedProviderID(providerID)
        if let token = try load(providerID: providerID, service: Self.service) {
            return token
        }
        guard let legacyToken = try load(providerID: providerID, service: Self.legacyService) else {
            return nil
        }
        try? migrateLegacyTokenIfAbsent(providerID: providerID, token: legacyToken)
        return legacyToken
    }

    private func load(providerID: String, service: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(providerID: providerID, service: service) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                throw ProviderCredentialStoreError.invalidStoredToken(providerID: providerID)
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw ProviderCredentialStoreError.readFailed(providerID: providerID, status: status)
        }
    }

    private func migrateLegacyTokenIfAbsent(providerID: String, token: String) throws {
        let status = SecItemAdd(
            Self.addQuery(providerID: providerID, tokenData: Data(token.utf8)) as CFDictionary,
            nil
        )
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            return
        default:
            throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: status)
        }
    }

    func replace(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }
        try Self.withMutationLock {
            try replaceWhileLocked(providerID: providerID, token: token)
        }
    }

    private func replaceWhileLocked(providerID: String, token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            Self.baseQuery(providerID: providerID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            let addStatus = SecItemAdd(Self.addQuery(providerID: providerID, tokenData: data) as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                break
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(
                    Self.baseQuery(providerID: providerID) as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard retryStatus == errSecSuccess else {
                    throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: retryStatus)
                }
            default:
                throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: addStatus)
            }
        default:
            throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: updateStatus)
        }

        guard try load(providerID: providerID) == token else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
    }

    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }

        try Self.withMutationLock {
            do {
                if let current = try load(providerID: providerID) {
                    guard current == token else {
                        throw ProviderCredentialStoreError.conflict(providerID: providerID)
                    }
                    return
                }
                try importWhileLocked(providerID: providerID, token: token)
            } catch ProviderCredentialStoreError.invalidStoredToken {
                try replaceWhileLocked(providerID: providerID, token: token)
            }
        }
    }

    /// Migration-only insertion. An existing Keychain item is authoritative:
    /// compatibility YAML may verify the same value but may never rotate or
    /// overwrite it. Coordinator-authenticated rotation uses `replace`.
    func importIfAbsentOrMatches(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }

        try Self.withMutationLock {
            try importWhileLocked(providerID: providerID, token: token)
        }
    }

    private func importWhileLocked(providerID: String, token: String) throws {
        if let stored = try load(providerID: providerID) {
            guard stored == token else {
                throw ProviderCredentialStoreError.conflict(providerID: providerID)
            }
            return
        }

        let addStatus = SecItemAdd(
            Self.addQuery(providerID: providerID, tokenData: Data(token.utf8)) as CFDictionary,
            nil
        )
        switch addStatus {
        case errSecSuccess:
            break
        case errSecDuplicateItem:
            guard try load(providerID: providerID) == token else {
                throw ProviderCredentialStoreError.conflict(providerID: providerID)
            }
        default:
            throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: addStatus)
        }

        guard try load(providerID: providerID) == token else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
    }

    func deleteAll() throws {
        try Self.withMutationLock {
            for service in [Self.service, Self.legacyService] {
                let status = SecItemDelete(Self.serviceQuery(service: service) as CFDictionary)
                switch status {
                case errSecSuccess, errSecItemNotFound:
                    continue
                default:
                    throw ProviderCredentialStoreError.deleteFailed(status: status)
                }
            }
        }
    }

    static var serviceQuery: [String: Any] {
        serviceQuery(service: service)
    }

    static func serviceQuery(service: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func baseQuery(providerID: String) -> [String: Any] {
        baseQuery(providerID: providerID, service: service)
    }

    static func baseQuery(providerID: String, service: String) -> [String: Any] {
        serviceQuery(service: service).merging([
            kSecAttrAccount as String: providerID,
        ]) { _, new in new }
    }

    static func readQuery(providerID: String) -> [String: Any] {
        readQuery(providerID: providerID, service: service)
    }

    static func readQuery(providerID: String, service: String) -> [String: Any] {
        baseQuery(providerID: providerID, service: service).merging([
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
    }

    static func addQuery(providerID: String, tokenData: Data) -> [String: Any] {
        baseQuery(providerID: providerID).merging([
            // Intentionally use the legacy login Keychain rather than the Data
            // Protection Keychain: the default ACL binds access to the signed
            // CLI's stable designated requirement across updates. macOS does
            // not honor kSecAttrAccessible here unless DP Keychain (or sync) is
            // selected, so do not claim an unsupported accessibility policy.
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: "MacProvider provider credential",
            kSecValueData as String: tokenData,
        ]) { _, new in new }
    }

    private static func normalizedProviderID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ProviderCredentialStoreError.invalidProviderID }
        return value
    }

    private static func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        // Keep the mutex inode outside the product-state directory. Uninstall
        // intentionally removes `.../macprovider`; deleting a held lock inode
        // would let a second process create and lock a different inode while
        // the first mutation is still active.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProviderCredentialStoreError.custodyLockFailed
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & 0o022) == 0 else {
            throw ProviderCredentialStoreError.custodyLockFailed
        }
        let lockURL = directory.appendingPathComponent(".macprovider-provider-credential.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ProviderCredentialStoreError.custodyLockFailed
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw ProviderCredentialStoreError.custodyLockFailed
        }

        let deadline = Date().addingTimeInterval(10)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard (errno == EWOULDBLOCK || errno == EAGAIN), Date() < deadline else {
                throw ProviderCredentialStoreError.custodyLockFailed
            }
            usleep(20_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

enum ProviderCredentialStoreFactory {
    static func providerStore(for config: AppConfig) -> any ProviderCredentialStoring {
        switch config.credentialStore {
        case .keychain:
            return KeychainProviderCredentialStore()
        case .protectedFile:
            return ProtectedFileProviderCredentialStore(rootDirectory: protectedFileRoot(for: config))
        }
    }

    static func receiptKeyStore(for config: AppConfig) -> any ProviderIdentityKeyStoring {
        switch config.credentialStore {
        case .keychain:
            return KeychainReceiptKeyStore()
        case .protectedFile:
            return ProtectedFileReceiptKeyStore(rootDirectory: protectedFileRoot(for: config))
        }
    }

    static func credentialSource(for config: AppConfig) -> ProviderCredentialStatus.Source {
        switch config.credentialStore {
        case .keychain:
            return .cliKeychain
        case .protectedFile:
            return .protectedFile
        }
    }

    static func protectedFileRoot(for config: AppConfig) -> URL {
        if let explicitRoot = ProcessInfo.processInfo.environment["MACPROVIDER_PROTECTED_CREDENTIAL_ROOT"],
           !explicitRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: ConfigLoader.expandTilde(explicitRoot))
        }
        let expanded = ConfigLoader.expandTilde(config.configPath)
        let configURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        return configURL.appendingPathComponent("protected-credentials", isDirectory: true)
    }
}

struct ProviderCredentialStatus: Equatable, Sendable {
    enum Source: String, Sendable {
        case cliKeychain = "cli_keychain"
        case protectedFile = "protected_file"
        case configFallback = "config_fallback"
        case none
    }

    enum State: String, Sendable {
        case ready
        case degraded
        case conflict
        case unconfigured
        case missing
        case locked
        case notLoggedIn = "not_logged_in"
        case permissionDenied = "permission_denied"
        case corrupt
        case keychainFailure = "keychain_failure"
        case incompatible
        case unavailable
    }

    var hasRestartSafeCredentialCustody: Bool {
        (source == .cliKeychain || source == .protectedFile) && state == .ready && restartSafe
    }

    enum RecoveryAction: String, Sendable {
        case none
        case retry
        case unlockKeychain = "unlock_keychain"
        case login
        case authorizeKeychain = "authorize_keychain"
        case repairKeychain = "repair_keychain"
        case updateOrReinstall = "update_or_reinstall"
        case repairFromProtectedSource = "repair_from_protected_source"
        case restoreOrReenroll = "restore_or_reenroll"
    }

    let source: Source
    let state: State
    let restartSafe: Bool
    let migrationPending: Bool
    let recoveryAction: RecoveryAction

    init(
        source: Source,
        state: State,
        restartSafe: Bool,
        migrationPending: Bool = false,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.source = source
        self.state = state
        self.restartSafe = restartSafe
        self.migrationPending = migrationPending
        self.recoveryAction = recoveryAction ?? Self.defaultRecoveryAction(for: state)
    }

    static let unconfigured = ProviderCredentialStatus(
        source: .none,
        state: .unconfigured,
        restartSafe: false,
        migrationPending: false
    )

    static func failure(
        _ error: Error,
        fallbackAvailable: Bool,
        authoritativeSource: Source? = nil
    ) -> ProviderCredentialStatus {
        let source: Source = authoritativeSource ?? (fallbackAvailable ? .configFallback : .none)
        let state: State
        let action: RecoveryAction
        switch error {
        case ProviderCredentialStoreError.missing:
            state = .missing
            action = .restoreOrReenroll
        case ProviderCredentialStoreError.invalidStoredToken:
            state = .corrupt
            action = fallbackAvailable ? .repairFromProtectedSource : .restoreOrReenroll
        case ProviderCredentialStoreError.conflict:
            state = .conflict
            action = .restoreOrReenroll
        case ProviderCredentialStoreError.readFailed(_, let status):
            switch status {
            case errSecInteractionNotAllowed, errSecInteractionRequired, errSecDatabaseLocked:
                state = .locked
                action = .unlockKeychain
            case errSecNotLoggedIn:
                state = .notLoggedIn
                action = .login
            case errSecNotAvailable:
                state = .unavailable
                action = .retry
            case errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
                state = .permissionDenied
                action = .authorizeKeychain
            case errSecMissingEntitlement:
                state = .incompatible
                action = .updateOrReinstall
            case errSecDecode, errSecReadOnly, errSecNoSuchKeychain, errSecInvalidKeychain,
                 errSecNoDefaultKeychain, errSecDataNotAvailable:
                state = .keychainFailure
                action = .repairKeychain
            default:
                state = .unavailable
                action = .retry
            }
        default:
            state = .unavailable
            action = .retry
        }
        return ProviderCredentialStatus(
            source: source,
            state: state,
            restartSafe: false,
            migrationPending: false,
            recoveryAction: action
        )
    }

    private static func defaultRecoveryAction(for state: State) -> RecoveryAction {
        switch state {
        case .ready, .unconfigured:
            return .none
        case .locked:
            return .unlockKeychain
        case .notLoggedIn:
            return .login
        case .permissionDenied:
            return .authorizeKeychain
        case .corrupt:
            return .repairFromProtectedSource
        case .keychainFailure:
            return .repairKeychain
        case .incompatible:
            return .updateOrReinstall
        case .missing, .conflict:
            return .restoreOrReenroll
        case .degraded, .unavailable:
            return .retry
        }
    }
}

actor ProviderCredentialStatusRuntime {
    private var value: ProviderCredentialStatus

    init(_ value: ProviderCredentialStatus) {
        self.value = value
    }

    func snapshot() -> ProviderCredentialStatus { value }

    func update(_ value: ProviderCredentialStatus) {
        self.value = value
    }
}

enum ProviderCredentialResolver {
    static func resolve(
        config: inout AppConfig,
        store: any ProviderCredentialStoring = KeychainProviderCredentialStore(),
        authoritativeSource: ProviderCredentialStatus.Source = .cliKeychain
    ) throws -> ProviderCredentialStatus {
        let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = config.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let yamlToken = try yamlCredential(at: config.configPath)
        guard let providerID, !providerID.isEmpty else {
            return fallback?.isEmpty == false
                ? ProviderCredentialStatus(source: .configFallback, state: .degraded, restartSafe: false)
                : .unconfigured
        }

        do {
            if let stored = try store.load(providerID: providerID) {
                config.providerToken = stored
                let layeredConflict = fallback?.isEmpty == false && fallback != stored
                let yamlConflict = yamlToken?.isEmpty == false && yamlToken != stored
                return ProviderCredentialStatus(
                    source: authoritativeSource,
                    state: layeredConflict || yamlConflict ? .conflict : .ready,
                    restartSafe: true,
                    migrationPending: yamlToken == stored
                )
            }
            guard let fallback, !fallback.isEmpty else {
                return ProviderCredentialStatus(
                    source: .none,
                    state: .missing,
                    restartSafe: false,
                    recoveryAction: .restoreOrReenroll
                )
            }
            do {
                try store.importIfAbsentOrMatches(providerID: providerID, token: fallback)
            } catch let conflict as ProviderCredentialStoreError {
                guard conflict == .conflict(providerID: providerID) else { throw conflict }
                guard let authoritative = try store.load(providerID: providerID) else { throw conflict }
                config.providerToken = authoritative
                return ProviderCredentialStatus(
                    source: authoritativeSource,
                    state: .conflict,
                    restartSafe: true,
                    migrationPending: false
                )
            }
            guard let verified = try store.load(providerID: providerID), verified == fallback else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
            config.providerToken = verified
            return ProviderCredentialStatus(
                source: authoritativeSource,
                state: yamlToken?.isEmpty == false && yamlToken != verified ? .conflict : .ready,
                restartSafe: true,
                migrationPending: yamlToken == verified
            )
        } catch {
            let fallbackAvailable = fallback?.isEmpty == false
            if authoritativeSource == .protectedFile {
                config.providerToken = nil
                return ProviderCredentialStatus.failure(
                    error,
                    fallbackAvailable: false,
                    authoritativeSource: .protectedFile
                )
            }
            if let fallback, fallbackAvailable {
                config.providerToken = fallback
            }
            return ProviderCredentialStatus.failure(error, fallbackAvailable: fallbackAvailable)
        }
    }

    private static func yamlCredential(at configPath: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: ConfigLoader.expandTilde(configPath)) else {
            return nil
        }
        return try ConfigLoader.load(
            cli: CLIOverrides(configPath: configPath),
            environment: [:]
        ).providerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
