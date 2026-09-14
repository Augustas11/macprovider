import CryptoKit
import Darwin
import Foundation

struct MalibuPayloadInventory: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let relativePath: String
        let size: UInt64
        let sha256: String
        enum CodingKeys: String, CodingKey { case relativePath, size, sha256 }
        init(relativePath: String, size: UInt64, sha256: String) { self.relativePath = relativePath; self.size = size; self.sha256 = sha256 }
        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, allowed: ["relativePath", "size", "sha256"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            relativePath = try c.decode(String.self, forKey: .relativePath); size = try c.decode(UInt64.self, forKey: .size); sha256 = try c.decode(String.self, forKey: .sha256)
        }
    }
    let files: [File]
    let directories: [String]
    static let empty = Self(files: [], directories: [])
    enum CodingKeys: String, CodingKey { case files, directories }
    init(files: [File], directories: [String]) { self.files = files; self.directories = directories }
    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["files", "directories"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decode([File].self, forKey: .files); directories = try c.decode([String].self, forKey: .directories)
        try MalibuTransactionPayload.validate(self, complete: true)
    }
}

// Execution requires a complete frozen inventory. Disposal deliberately uses a
// separate, bounded safe-subset predicate: a partial copy is never executable.
enum MalibuTransactionPayload {
    static let maximumBytes: UInt64 = 512 * 1024 * 1024
    static let requiredFiles: Set<String> = ["macprovider-cli", "mlx.metallib", "compatibility-set.json"]
    static let localFiles: Set<String> = ["install.sh", "provider-launch-agent.plist.template", "updater-rollback.json", "watchdog-launch-agent.plist.template", "watchdog.sh"]
    static let catalogFiles: Set<String> = ["release.json", "trusted-keys.json", "tier2-catalog.json", "autotune-candidates.json", "autotune-candidates.json.sig", "demand-rank.json", "demand-rank.json.sig", "rate-card.json", "rate-card.json.sig"]
    static let bundles: Set<String> = ["mlx-swift_Cmlx.bundle", "swift-nio_NIOPosix.bundle"]
    static let topNames = requiredFiles.union(["compatibility-set-local", "catalog-release", "THIRD-PARTY-NOTICES.txt"]).union(bundles)
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t, mode: mode_t, size: off_t, seconds: Int, nanoseconds: Int
        init(_ st: stat) { device = st.st_dev; inode = st.st_ino; mode = st.st_mode; size = st.st_size; seconds = st.st_mtimespec.tv_sec; nanoseconds = st.st_mtimespec.tv_nsec }
    }
    struct Scan {
        let inventory: MalibuPayloadInventory
        let identities: [String: Identity]
    }
    static func allows(_ path: String, directory: Bool) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 256 else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 6, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if parts.count == 1 { return directory ? (["compatibility-set-local", "catalog-release"].contains(path) || bundles.contains(path)) : requiredFiles.contains(path) || path == "THIRD-PARTY-NOTICES.txt" }
        if parts[0] == "compatibility-set-local" { return !directory && parts.count == 2 && localFiles.contains(parts[1]) }
        if parts[0] == "catalog-release" { return !directory && parts.count == 2 && catalogFiles.contains(parts[1]) }
        guard bundles.contains(parts[0]) else { return false }
        let tail = parts.dropFirst().joined(separator: "/")
        if directory { return ["Contents", "Contents/Resources", "_CodeSignature", "Contents/_CodeSignature"].contains(tail) }
        let metadata = ["Info.plist", "Contents/Info.plist", "PrivacyInfo.xcprivacy", "Contents/Resources/PrivacyInfo.xcprivacy", "_CodeSignature/CodeResources", "Contents/_CodeSignature/CodeResources"]
        return metadata.contains(tail) || (parts[0] == "mlx-swift_Cmlx.bundle" && ["default.metallib", "Contents/Resources/default.metallib"].contains(tail))
    }
    static func validate(_ inventory: MalibuPayloadInventory, complete: Bool) throws {
        let names = inventory.files.map(\.relativePath), directories = inventory.directories
        guard names == names.sorted(), directories == directories.sorted(), Set(names).count == names.count,
              Set(directories).count == directories.count, names.count <= 256, directories.count <= 32,
              inventory.files.allSatisfy({ allows($0.relativePath, directory: false) && malibuDigest($0.sha256) && $0.size <= ($0.relativePath == "macprovider-cli" ? maximumBytes : maximumBytes / 2) }),
              directories.allSatisfy({ allows($0, directory: true) }), inventory.files.reduce(UInt64(0), { $0 + $1.size }) <= maximumBytes else { throw ModelManagementError.invalidCatalog }
        let all = Set(names)
        for bundle in bundles {
            for pair in [["Info.plist", "Contents/Info.plist"], ["default.metallib", "Contents/Resources/default.metallib"], ["PrivacyInfo.xcprivacy", "Contents/Resources/PrivacyInfo.xcprivacy"], ["_CodeSignature/CodeResources", "Contents/_CodeSignature/CodeResources"]] {
                guard !pair.allSatisfy({ all.contains(bundle + "/" + $0) }) else { throw ModelManagementError.invalidCatalog }
            }
        }
        if complete {
            for bundle in bundles where directories.contains(bundle) {
                guard all.contains(bundle + "/Info.plist") || all.contains(bundle + "/Contents/Info.plist") else { throw ModelManagementError.invalidCatalog }
            }
            guard requiredFiles.isSubset(of: all), localFiles.allSatisfy({ all.contains("compatibility-set-local/" + $0) }),
                  catalogFiles.allSatisfy({ all.contains("catalog-release/" + $0) }),
                  directories.contains("compatibility-set-local"), directories.contains("catalog-release"),
                  !bundles.isDisjoint(with: Set(directories)), inventory.files.allSatisfy({ $0.size > 0 }) else { throw ModelManagementError.invalidCatalog }
        }
    }
    static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw ModelManagementError.invalidCatalog }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= 300 else { throw ModelManagementError.invalidCatalog }
        }
        guard errno == 0 else { throw ModelManagementError.invalidCatalog }
        return result.sorted()
    }
    static func directoryFD(_ url: URL, privateDirectory: Bool) throws -> Int32 {
        try MalibuTransactionFiles.safeParents(url)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        do { try checkDirectory(fd, privateDirectory: privateDirectory); return fd } catch { close(fd); throw error }
    }
    static func checkDirectory(_ fd: Int32, privateDirectory: Bool) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
              st.st_mode & (privateDirectory ? 0o077 : 0o022) == 0, MalibuTransactionFiles.noACL(fd) else { throw ModelManagementError.invalidCatalog }
    }
    static func scan(_ root: URL, source: Bool, complete: Bool = true, request: MalibuTransactionRequest? = nil) throws -> Scan {
        try request?.check()
        let fd = try directoryFD(root, privateDirectory: !source)
        defer { close(fd) }
        var files: [MalibuPayloadInventory.File] = [], directories: [String] = [], identities: [String: Identity] = [:], total: UInt64 = 0
        func visit(_ parent: Int32, prefix: String) throws {
            try request?.check()
            var initial = stat()
            guard fstat(parent, &initial) == 0 else { throw ModelManagementError.invalidCatalog }
            identities[prefix] = Identity(initial)
            for name in try names(parent) {
                try request?.check()
                if prefix.isEmpty && source && !topNames.contains(name) { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var st = stat()
                guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw ModelManagementError.invalidCatalog }
                let isDirectory = st.st_mode & S_IFMT == S_IFDIR
                guard allows(relative, directory: isDirectory) else { throw ModelManagementError.invalidCatalog }
                if isDirectory {
                    directories.append(relative)
                    guard directories.count <= 32 else { throw ModelManagementError.invalidCatalog }
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ModelManagementError.invalidCatalog }
                    defer { close(child) }
                    try checkDirectory(child, privateDirectory: !source)
                    var opened = stat()
                    guard fstat(child, &opened) == 0, Identity(opened) == Identity(st) else { throw ModelManagementError.invalidCatalog }
                    try visit(child, prefix: relative)
                } else {
                    let limit = relative == "macprovider-cli" ? maximumBytes : maximumBytes / 2
                    guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
                          st.st_mode & (source ? 0o022 : 0o077) == 0, st.st_size >= 0,
                          UInt64(st.st_size) <= limit, files.count < 256 else { throw ModelManagementError.invalidCatalog }
                    total += UInt64(st.st_size)
                    guard total <= maximumBytes else { throw ModelManagementError.invalidCatalog }
                    let child = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ModelManagementError.invalidCatalog }
                    defer { close(child) }
                    var before = stat()
                    guard fstat(child, &before) == 0, Identity(before) == Identity(st), MalibuTransactionFiles.noACL(child) else { throw ModelManagementError.invalidCatalog }
                    var hash = SHA256(), count: UInt64 = 0, buffer = [UInt8](repeating: 0, count: 65536), plist = Data(), magic = Data()
                    while complete {
                        try request?.check()
                        request?.beforeResourceRead?()
                        let readCount = Darwin.read(child, &buffer, buffer.count)
                        try request?.check()
                        if readCount == 0 { break }
                        guard readCount > 0, count + UInt64(readCount) <= UInt64(st.st_size) else { throw ModelManagementError.invalidCatalog }
                        count += UInt64(readCount)
                        let data = Data(buffer.prefix(readCount)); hash.update(data: data)
                        if magic.isEmpty { magic = data.prefix(4) }
                        if complete && name == "Info.plist" {
                            guard plist.count + readCount <= 65536 else { throw ModelManagementError.invalidCatalog }
                            plist.append(data)
                        }
                    }
                    var after = stat()
                    guard fstat(child, &after) == 0, Identity(before) == Identity(after), (count == UInt64(st.st_size) || !complete) else { throw ModelManagementError.invalidCatalog }
                    if complete && relative != "macprovider-cli" {
                        let nativeMagics: [Data] = [[0xfe,0xed,0xfa,0xce], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xcf,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].map { Data($0) }
                        guard !nativeMagics.contains(magic) else { throw ModelManagementError.invalidCatalog }
                        if name == "Info.plist" {
                            guard let object = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any], object["CFBundleExecutable"] == nil else { throw ModelManagementError.invalidCatalog }
                        }
                    }
                    files.append(.init(relativePath: relative, size: UInt64(st.st_size), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
                    identities[relative] = Identity(after)
                }
            }
            var final = stat()
            guard fstat(parent, &final) == 0, Identity(initial) == Identity(final) else { throw ModelManagementError.invalidCatalog }
        }
        try visit(fd, prefix: "")
        let inventory = MalibuPayloadInventory(files: files.sorted { $0.relativePath < $1.relativePath }, directories: directories.sorted())
        try validate(inventory, complete: complete)
        return Scan(inventory: inventory, identities: identities)
    }
    static func copy(source: URL, destination: URL, scan: Scan, request: MalibuTransactionRequest) throws {
        try request.check()
        guard mkdir(destination.path, 0o700) == 0 else { throw ModelManagementError.invalidCatalog }
        let sourceFD = try directoryFD(source, privateDirectory: false), targetFD = try directoryFD(destination, privateDirectory: true)
        defer { close(sourceFD); close(targetFD) }
        // Every relative parent is reopened without following links, then checked
        // against the source inventory before a leaf can be read.
        func parentFD(_ root: Int32, path: String, sourceParent: Bool) throws -> Int32 {
            var current = dup(root), prefix = ""
            guard current >= 0 else { throw ModelManagementError.invalidCatalog }
            do {
                for component in path.split(separator: "/").dropLast() {
                    try request.check(); prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                    let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw ModelManagementError.invalidCatalog }
                    close(current); current = next
                    try checkDirectory(current, privateDirectory: !sourceParent)
                    if sourceParent { var st = stat(); guard fstat(current, &st) == 0, scan.identities[prefix] == Identity(st) else { throw ModelManagementError.invalidCatalog } }
                }
                return current
            } catch { close(current); throw error }
        }
        for directory in scan.inventory.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            try request.check()
            let parent = try parentFD(targetFD, path: directory, sourceParent: false); defer { close(parent) }
            guard mkdirat(parent, (directory as NSString).lastPathComponent, 0o700) == 0 else { throw ModelManagementError.invalidCatalog }
        }
        for file in scan.inventory.files {
            try request.check()
            let fromParent = try parentFD(sourceFD, path: file.relativePath, sourceParent: true), toParent = try parentFD(targetFD, path: file.relativePath, sourceParent: false)
            defer { close(fromParent); close(toParent) }
            let name = (file.relativePath as NSString).lastPathComponent
            let input = openat(fromParent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw ModelManagementError.invalidCatalog }
            defer { close(input) }
            var before = stat()
            guard fstat(input, &before) == 0, scan.identities[file.relativePath] == Identity(before), MalibuTransactionFiles.noACL(input) else { throw ModelManagementError.invalidCatalog }
            let output = openat(toParent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, file.relativePath == "macprovider-cli" ? 0o700 : 0o600)
            guard output >= 0 else { throw ModelManagementError.invalidCatalog }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 65536), count: UInt64 = 0, hash = SHA256()
            while true {
                try request.check()
                let n = Darwin.read(input, &buffer, buffer.count)
                try request.check()
                if n == 0 { break }
                guard n > 0, count + UInt64(n) <= file.size else { throw ModelManagementError.invalidCatalog }
                count += UInt64(n); hash.update(data: Data(buffer.prefix(n)))
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < n { try request.check(); let wrote = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), n - offset); guard wrote > 0 else { throw ModelManagementError.invalidCatalog }; offset += wrote }
                }
                request.afterPayloadWrite?(request)
                try request.check()
            }
            var after = stat()
            guard fstat(input, &after) == 0, Identity(before) == Identity(after), count == file.size,
                  hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw ModelManagementError.invalidCatalog }
            try request.check(); guard fsync(output) == 0 else { throw ModelManagementError.invalidCatalog }; try request.check()
        }
        for directory in scan.inventory.directories.sorted(by: { $0.count > $1.count }) { try request.check(); try MalibuTransactionFiles.syncDirectory(destination.appendingPathComponent(directory)) }
        try request.check(); guard fsync(targetFD) == 0 else { throw ModelManagementError.invalidCatalog }
    }
    static func removePartial(_ root: URL, request: MalibuTransactionRequest? = nil, checkAbsent: () throws -> Void) throws {
        try checkAbsent()
        let observed = try scan(root, source: false, complete: false, request: request)
        let rootFD = try directoryFD(root, privateDirectory: true)
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, observed.identities[""] == Identity(rootInfo) else { throw ModelManagementError.invalidCatalog }
        func verifyReachable(_ prefix: String) throws {
            var named = stat()
            guard lstat(root.path, &named) == 0, named.st_dev == rootInfo.st_dev, named.st_ino == rootInfo.st_ino, named.st_mode & S_IFMT == S_IFDIR else { throw ModelManagementError.invalidCatalog }
            var current = dup(rootFD), path = ""
            guard current >= 0 else { throw ModelManagementError.invalidCatalog }
            defer { close(current) }
            for component in prefix.split(separator: "/") {
                path = path.isEmpty ? String(component) : path + "/" + component
                let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ModelManagementError.invalidCatalog }
                close(current); current = next
                var st = stat()
                guard fstat(current, &st) == 0, let expected = observed.identities[path], st.st_dev == expected.device, st.st_ino == expected.inode else { throw ModelManagementError.invalidCatalog }
            }
        }
        func remove(_ parent: Int32, prefix: String) throws {
            for name in try names(parent) {
                try request?.check(); try checkAbsent(); try verifyReachable(prefix)
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var st = stat()
                guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0, observed.identities[relative] == Identity(st) else { throw ModelManagementError.invalidCatalog }
                if st.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ModelManagementError.invalidCatalog }
                    defer { close(child) }
                    var opened = stat(); guard fstat(child, &opened) == 0, Identity(opened) == Identity(st) else { throw ModelManagementError.invalidCatalog }
                    try remove(child, prefix: relative)
                    try request?.check(); try checkAbsent()
                    var remaining = stat(); guard fstatat(parent, name, &remaining, AT_SYMLINK_NOFOLLOW) == 0, remaining.st_dev == st.st_dev, remaining.st_ino == st.st_ino, unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw ModelManagementError.invalidCatalog }
                } else { guard unlinkat(parent, name, 0) == 0 else { throw ModelManagementError.invalidCatalog } }
            }
        }
        try remove(rootFD, prefix: ""); try checkAbsent(); try request?.check()
        var now = stat(); guard lstat(root.path, &now) == 0, now.st_dev == rootInfo.st_dev, now.st_ino == rootInfo.st_ino, rmdir(root.path) == 0 else { throw ModelManagementError.invalidCatalog }
        try MalibuTransactionFiles.syncDirectory(root.deletingLastPathComponent())
    }
}
