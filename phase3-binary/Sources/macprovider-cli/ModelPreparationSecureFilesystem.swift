import Darwin
import Foundation
import Security

enum ModelPreparationSecureFilesystemError: Error, Equatable, CustomStringConvertible {
    case io(path: String, operation: String, errnoCode: Int32)
    case unsafe(path: String, reason: String)
    case limitExceeded(String)
    case randomUnavailable

    var description: String {
        switch self {
        case .io(let path, let operation, let errnoCode):
            return "model preparation storage \(operation) failed for \(path) (errno \(errnoCode))"
        case .unsafe(let path, let reason):
            return "model preparation storage rejected \(path): \(reason)"
        case .limitExceeded(let reason):
            return "model preparation storage limit exceeded: \(reason)"
        case .randomUnavailable:
            return "model preparation storage could not generate secure random bytes"
        }
    }
}

protocol ModelPreparationRandomSource: Sendable {
    func randomBytes(count: Int) throws -> Data
    func uuidString() throws -> String
}

struct ModelPreparationSystemRandomSource: ModelPreparationRandomSource {
    func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ModelPreparationSecureFilesystemError.randomUnavailable
        }
        return Data(bytes)
    }

    func uuidString() throws -> String {
        UUID().uuidString.lowercased()
    }
}

enum ModelPreparationSecureFilesystem {
    static let namespaceLeaf = ".macprovider-prepared-v3"
    static let stateTempLeaf = "state-tmp"
    static let bootstrapTempLeaf = "bootstrap-tmp"
    static let objectsLeaf = "objects"
    static let workLeaf = "work"
    static let stagingLeaf = "staging"
    static let unpublishedLeaf = "unpublished"

    struct Directory: Sendable {
        let fd: Int32
        let path: String
        let identity: FileIdentity

        func close() {
            Darwin.close(fd)
        }
    }

    struct FileIdentity: Equatable, Sendable {
        let stDev: UInt64
        let stIno: UInt64
    }

    struct OpenFile: Sendable {
        let fd: Int32
        let path: String
        let identity: FileIdentity

        func close() {
            Darwin.close(fd)
        }
    }

    static func canonicalPrivatePath(_ url: URL) throws -> String {
        var path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            path = "/private" + path
        }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "invalid path")
        }
        return path
    }

    static func openOrCreatePrivateDirectory(at url: URL) throws -> Directory {
        let path = try canonicalPrivatePath(url)
        let components = try pathComponents(path)
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw openError(path: "/", operation: "open root directory") }
        var currentPath = ""
        var keepCurrent = false
        defer { if !keepCurrent { Darwin.close(current) } }

        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            let childPath = currentPath + "/" + component
            var child = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if child < 0, errno == ENOENT {
                guard mkdirat(current, component, S_IRWXU) == 0 else {
                    throw openError(path: childPath, operation: "create directory")
                }
                child = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw openError(path: childPath, operation: "open created directory") }
                do {
                    try secureNewDirectory(fd: child, path: childPath)
                    try syncDirectoryFD(current, path: currentPath.isEmpty ? "/" : currentPath)
                } catch {
                    removeNewEmptyDirectoryIfStillNamed(parentFD: current, name: component, childFD: child, path: childPath)
                    Darwin.close(child)
                    throw error
                }
            } else if child < 0 {
                throw openError(path: childPath, operation: "open directory")
            }

            do {
                if isLeaf {
                    _ = try validateDirectory(fd: child, path: childPath, requireOwnerOnly: true)
                } else {
                    try validateTraversableDirectory(fd: child, path: childPath)
                }
            } catch {
                Darwin.close(child)
                throw error
            }
            Darwin.close(current)
            current = child
            currentPath = childPath
        }

        let stat = try validateDirectory(fd: current, path: path, requireOwnerOnly: true)
        let directory = Directory(fd: current, path: path, identity: identity(from: stat))
        try revalidateDirectory(directory)
        keepCurrent = true
        return directory
    }

    static func openPrivateChildDirectory(parent: Directory, name: String, create: Bool = true) throws -> Directory {
        try requireLeaf(name)
        try revalidateDirectory(parent)
        let path = parent.path + "/" + name
        var fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0, create, errno == ENOENT {
            guard mkdirat(parent.fd, name, S_IRWXU) == 0 else {
                throw openError(path: path, operation: "create directory")
            }
            fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw openError(path: path, operation: "open created directory") }
            do {
                try secureNewDirectory(fd: fd, path: path)
                try syncDirectoryFD(parent.fd, path: parent.path)
            } catch {
                removeNewEmptyDirectoryIfStillNamed(parentFD: parent.fd, name: name, childFD: fd, path: path)
                Darwin.close(fd)
                throw error
            }
        } else if fd < 0 {
            throw openError(path: path, operation: "open directory")
        }

        do {
            let stat = try validateDirectory(fd: fd, path: path, requireOwnerOnly: true)
            try validateNamedDirectory(parentFD: parent.fd, name: name, opened: stat, path: path)
            try revalidateDirectory(parent)
            let directory = Directory(fd: fd, path: path, identity: identity(from: stat))
            try revalidateDirectory(directory)
            return directory
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func openPrivateFile(parent: Directory, name: String, maxBytes: Int, allowEmpty: Bool) throws -> OpenFile? {
        try requireLeaf(name)
        try revalidateDirectory(parent)
        let path = parent.path + "/" + name
        var named = Darwin.stat()
        guard fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw openError(path: path, operation: "stat file")
        }
        guard (named.st_mode & S_IFMT) == S_IFREG else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "not a regular file")
        }
        // A hostile replacement may become a FIFO after fstatat. O_NONBLOCK keeps
        // the open bounded until the descriptor and name can be checked together.
        let fd = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw openError(path: path, operation: "open file")
        }
        do {
            let stat = try validateRegularFile(fd: fd, path: path, maxBytes: maxBytes, allowEmpty: allowEmpty)
            try validateNamedFile(parentFD: parent.fd, name: name, opened: stat, path: path)
            let file = OpenFile(fd: fd, path: path, identity: identity(from: stat))
            try revalidateFile(file, parent: parent, name: name, maxBytes: maxBytes, allowEmpty: allowEmpty)
            return file
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func createPrivateFile(parent: Directory, name: String) throws -> OpenFile {
        try requireLeaf(name)
        try revalidateDirectory(parent)
        let path = parent.path + "/" + name
        let fd = openat(parent.fd, name, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw openError(path: path, operation: "create file") }
        do {
            try secureNewFile(fd: fd, path: path)
            let stat = try validateRegularFile(fd: fd, path: path, maxBytes: 0, allowEmpty: true)
            try validateNamedFile(parentFD: parent.fd, name: name, opened: stat, path: path)
            let file = OpenFile(fd: fd, path: path, identity: identity(from: stat))
            try revalidateFile(file, parent: parent, name: name, maxBytes: 0, allowEmpty: true)
            return file
        } catch {
            var opened = Darwin.stat()
            let isStillNamed = fstat(fd, &opened) == 0 && opened.st_size == 0 &&
                (try? validateNamedFile(parentFD: parent.fd, name: name, opened: opened, path: path)) != nil
            Darwin.close(fd)
            if isStillNamed { _ = unlinkat(parent.fd, name, 0) }
            throw error
        }
    }

    static func writeAll(fd: Int32, data: Data, path: String) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw openError(path: path, operation: "write") }
                offset += count
            }
        }
    }

    static func readAll(fd: Int32, path: String, maxBytes: Int) throws -> Data {
        var stat = Darwin.stat()
        guard fstat(fd, &stat) == 0 else { throw openError(path: path, operation: "stat") }
        guard stat.st_size >= 0, stat.st_size <= maxBytes else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "invalid size")
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw openError(path: path, operation: "seek") }
        var data = Data()
        data.reserveCapacity(Int(stat.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, max(1, maxBytes)))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw openError(path: path, operation: "read") }
            if count == 0 { break }
            guard data.count + count <= maxBytes else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "too large")
            }
            data.append(buffer, count: count)
        }
        return data
    }

    static func syncFileAndFullSync(fd: Int32, path: String) throws {
        guard fsync(fd) == 0 else { throw openError(path: path, operation: "fsync") }
        #if os(macOS)
        let result = fcntl(fd, F_FULLFSYNC)
        if result != 0 {
            throw openError(path: path, operation: "full fsync")
        }
        #endif
    }

    static func syncDirectory(_ directory: Directory) throws {
        try revalidateDirectory(directory)
        try syncDirectoryFD(directory.fd, path: directory.path)
    }

    static func syncDirectoryFD(_ fd: Int32, path: String) throws {
        guard fsync(fd) == 0 else { throw openError(path: path, operation: "sync directory") }
        #if os(macOS)
        let result = fcntl(fd, F_FULLFSYNC)
        if result != 0 {
            throw openError(path: path, operation: "full sync directory")
        }
        #endif
    }

    static func renameReplacing(parent: Directory, source: String, destination: String, sourceFile: OpenFile? = nil) throws {
        try renameReplacing(sourceParent: parent, source: source, targetParent: parent, destination: destination, sourceFile: sourceFile)
    }

    static func renameReplacing(
        sourceParent: Directory,
        source: String,
        targetParent: Directory,
        destination: String,
        sourceFile: OpenFile? = nil
    ) throws {
        try withValidatedSource(sourceFile, parent: sourceParent, name: source) { opened in
            try requireLeaf(destination)
            try validateReplaceTarget(parent: targetParent, name: destination)
            try revalidateFile(opened, parent: sourceParent, name: source, maxBytes: Int.max, allowEmpty: true)
            try revalidateDirectory(targetParent)
            guard renameat(sourceParent.fd, source, targetParent.fd, destination) == 0 else {
                throw openError(path: targetParent.path + "/" + destination, operation: "rename")
            }
            try finishRename(source: opened, sourceParent: sourceParent, targetParent: targetParent, destination: destination)
        }
    }

    static func renameExclusive(parent: Directory, source: String, destination: String, sourceFile: OpenFile? = nil) throws {
        try renameExclusive(sourceParent: parent, source: source, targetParent: parent, destination: destination, sourceFile: sourceFile)
    }

    static func renameExclusive(
        sourceParent: Directory,
        source: String,
        targetParent: Directory,
        destination: String,
        sourceFile: OpenFile? = nil
    ) throws {
        try withValidatedSource(sourceFile, parent: sourceParent, name: source) { opened in
            try requireLeaf(destination)
            try revalidateFile(opened, parent: sourceParent, name: source, maxBytes: Int.max, allowEmpty: true)
            try revalidateDirectory(targetParent)
            let result = Darwin.renameatx_np(sourceParent.fd, source, targetParent.fd, destination, UInt32(RENAME_EXCL))
            guard result == 0 else {
                throw openError(path: targetParent.path + "/" + destination, operation: "rename exclusive")
            }
            try finishRename(source: opened, sourceParent: sourceParent, targetParent: targetParent, destination: destination)
        }
    }

    static func unlinkFile(parent: Directory, name: String, expected: OpenFile? = nil) throws {
        try requireLeaf(name)
        if let expected {
            try revalidateFile(expected, parent: parent, name: name, maxBytes: Int.max, allowEmpty: true)
        } else {
            guard let opened = try openPrivateFile(parent: parent, name: name, maxBytes: Int.max, allowEmpty: true) else { return }
            defer { opened.close() }
            try revalidateFile(opened, parent: parent, name: name, maxBytes: Int.max, allowEmpty: true)
        }
        guard unlinkat(parent.fd, name, 0) == 0 else {
            throw openError(path: parent.path + "/" + name, operation: "unlink")
        }
        try syncDirectory(parent)
    }

    private static func withValidatedSource<T>(
        _ expected: OpenFile?,
        parent: Directory,
        name: String,
        body: (OpenFile) throws -> T
    ) throws -> T {
        try requireLeaf(name)
        if let expected {
            try revalidateFile(expected, parent: parent, name: name, maxBytes: Int.max, allowEmpty: true)
            return try body(expected)
        }
        guard let opened = try openPrivateFile(parent: parent, name: name, maxBytes: Int.max, allowEmpty: true) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: parent.path + "/" + name, reason: "source missing")
        }
        defer { opened.close() }
        return try body(opened)
    }

    private static func validateReplaceTarget(parent: Directory, name: String) throws {
        try revalidateDirectory(parent)
        guard let target = try openPrivateFile(parent: parent, name: name, maxBytes: Int.max, allowEmpty: true) else { return }
        defer { target.close() }
        try revalidateFile(target, parent: parent, name: name, maxBytes: Int.max, allowEmpty: true)
    }

    private static func finishRename(
        source: OpenFile,
        sourceParent: Directory,
        targetParent: Directory,
        destination: String
    ) throws {
        let stat = try validateRegularFile(fd: source.fd, path: source.path, maxBytes: Int.max, allowEmpty: true)
        try validateNamedFile(parentFD: targetParent.fd, name: destination, opened: stat, path: targetParent.path + "/" + destination)
        try syncDirectory(sourceParent)
        if sourceParent.identity != targetParent.identity {
            try syncDirectory(targetParent)
        }
    }

    static func forEachDirectoryEntry(_ directory: Directory, body: (String) throws -> Void) throws {
        try revalidateDirectory(directory)
        let copy = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copy >= 0 else { throw openError(path: directory.path, operation: "open directory copy") }
        guard let stream = fdopendir(copy) else {
            Darwin.close(copy)
            throw openError(path: directory.path, operation: "read directory")
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw openError(path: directory.path, operation: "read directory") }
                break
            }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { raw -> String? in
                let end = raw.firstIndex(of: 0) ?? raw.count
                return String(bytes: raw[..<end], encoding: .utf8)
            }) else {
                throw ModelPreparationSecureFilesystemError.unsafe(path: directory.path, reason: "invalid directory entry")
            }
            if name != "." && name != ".." { try body(name) }
        }
    }

    static func validateDirectory(fd: Int32, path: String, requireOwnerOnly: Bool) throws -> stat {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw openError(path: path, operation: "stat directory") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "not a directory")
        }
        guard info.st_uid == geteuid() else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "wrong owner")
        }
        guard info.st_nlink > 0 else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "unlinked directory")
        }
        if requireOwnerOnly, (info.st_mode & 0o777) != S_IRWXU {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "mode is not 0700")
        }
        try rejectExtendedACL(fd: fd, path: path)
        return info
    }

    static func validateTraversableDirectory(fd: Int32, path: String) throws {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw openError(path: path, operation: "stat directory") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "not a directory")
        }
    }

    static func validateRegularFile(fd: Int32, path: String, maxBytes: Int, allowEmpty: Bool) throws -> stat {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw openError(path: path, operation: "stat file") }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "not a regular file")
        }
        guard info.st_uid == geteuid() else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "wrong owner")
        }
        guard info.st_nlink == 1 else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "hard link")
        }
        guard (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "mode is not 0600")
        }
        try rejectExtendedACL(fd: fd, path: path)
        let minimum = allowEmpty ? 0 : 1
        guard info.st_size >= minimum, info.st_size <= maxBytes else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "invalid size")
        }
        return info
    }

    // Recheck both the held descriptor and the directory entry immediately
    // before using the bytes or identity. A name-only stat cannot establish
    // that the operation still addresses the validated descriptor.
    static func revalidateFile(
        _ file: OpenFile,
        parent: Directory,
        name: String,
        maxBytes: Int,
        allowEmpty: Bool
    ) throws {
        try requireLeaf(name)
        guard file.path == parent.path + "/" + name else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "path changed")
        }
        try revalidateDirectory(parent)
        let info = try validateRegularFile(fd: file.fd, path: file.path, maxBytes: maxBytes, allowEmpty: allowEmpty)
        guard identity(from: info) == file.identity else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: file.path, reason: "descriptor changed")
        }
        try validateNamedFile(parentFD: parent.fd, name: name, opened: info, path: file.path)
    }

    static func revalidateDirectory(_ directory: Directory) throws {
        let info = try validateDirectory(fd: directory.fd, path: directory.path, requireOwnerOnly: true)
        guard identity(from: info) == directory.identity else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: directory.path, reason: "directory descriptor changed")
        }

        // Rewalk without following symlinks so a renamed/replaced ancestor
        // cannot leave an old private directory reachable only by its fd.
        let components = try pathComponents(directory.path)
        var ancestor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard ancestor >= 0 else { throw openError(path: "/", operation: "open root directory") }
        defer { Darwin.close(ancestor) }
        var currentPath = ""
        for (index, component) in components.enumerated() {
            currentPath += "/" + component
            let child = openat(ancestor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard child >= 0 else { throw openError(path: currentPath, operation: "reopen directory") }
            Darwin.close(ancestor)
            ancestor = child
            if index == components.count - 1 {
                let named = try validateDirectory(fd: child, path: currentPath, requireOwnerOnly: true)
                guard identity(from: named) == directory.identity else {
                    throw ModelPreparationSecureFilesystemError.unsafe(path: directory.path, reason: "directory path changed")
                }
            } else {
                try validateTraversableDirectory(fd: child, path: currentPath)
            }
        }
    }

    static func validateNamedFile(parentFD: Int32, name: String, opened: stat, path: String) throws {
        try requireLeaf(name)
        var named = Darwin.stat()
        guard fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino,
              named.st_uid == opened.st_uid,
              named.st_nlink == opened.st_nlink,
              (named.st_mode & 0o777) == (opened.st_mode & 0o777) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "path changed")
        }
    }

    static func validateNamedDirectory(parentFD: Int32, name: String, opened: stat, path: String) throws {
        try requireLeaf(name)
        var named = Darwin.stat()
        guard fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino,
              named.st_uid == opened.st_uid,
              named.st_nlink == opened.st_nlink,
              (named.st_mode & 0o777) == (opened.st_mode & 0o777) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "path changed")
        }
    }

    static func rejectExtendedACL(fd: Int32, path: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return }
            throw openError(path: path, operation: "inspect ACL")
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result == 0 else { throw openError(path: path, operation: "inspect ACL") }
        guard entry == nil else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "extended ACL")
        }
    }

    static func stripAndVerifyEmptyACL(fd: Int32, path: String) throws {
        guard let emptyACL = acl_init(0) else {
            throw openError(path: path, operation: "initialize empty ACL")
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(emptyACL)) }
        if acl_set_fd_np(fd, emptyACL, ACL_TYPE_EXTENDED) != 0 {
            throw openError(path: path, operation: "delete ACL")
        }
        try rejectExtendedACL(fd: fd, path: path)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func requireLeaf(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= Int(NAME_MAX) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: name, reason: "invalid leaf")
        }
    }

    static func identity(from info: stat) -> FileIdentity {
        FileIdentity(stDev: UInt64(info.st_dev), stIno: UInt64(info.st_ino))
    }

    static func openError(path: String, operation: String) -> ModelPreparationSecureFilesystemError {
        if errno == ELOOP {
            return .unsafe(path: path, reason: "symlink")
        }
        return .io(path: path, operation: operation, errnoCode: errno)
    }

    private static func secureNewDirectory(fd: Int32, path: String) throws {
        guard fchmod(fd, S_IRWXU) == 0 else { throw openError(path: path, operation: "chmod directory") }
        try stripAndVerifyEmptyACL(fd: fd, path: path)
        _ = try validateDirectory(fd: fd, path: path, requireOwnerOnly: true)
    }

    private static func removeNewEmptyDirectoryIfStillNamed(parentFD: Int32, name: String, childFD: Int32, path: String) {
        var opened = Darwin.stat()
        guard fstat(childFD, &opened) == 0,
              (try? validateNamedDirectory(parentFD: parentFD, name: name, opened: opened, path: path)) != nil else {
            return
        }
        // AT_REMOVEDIR itself refuses to remove a directory that acquired
        // contents after creation.
        _ = unlinkat(parentFD, name, AT_REMOVEDIR)
    }

    private static func secureNewFile(fd: Int32, path: String) throws {
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw openError(path: path, operation: "chmod file") }
        try stripAndVerifyEmptyACL(fd: fd, path: path)
        _ = try validateRegularFile(fd: fd, path: path, maxBytes: 0, allowEmpty: true)
    }

    private static func pathComponents(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.contains("/")
        }) else {
            throw ModelPreparationSecureFilesystemError.unsafe(path: path, reason: "invalid path")
        }
        return components
    }
}
