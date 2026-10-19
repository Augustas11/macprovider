import Darwin
import Foundation

/// A selection is a directory descriptor, not a path prefix. Every intermediate
/// component is opened relative to that descriptor without following symlinks.
/// Replacement/rename races can change which in-scope file is read but cannot
/// redirect an open through an outside symlink.
actor AgentWorkspace {
    private let root: Int32
    nonisolated let name: String
    private let securityScopedURL: URL?
    static let fileByteLimit = 32 * 1024
    static let outputByteLimit = 64 * 1024
    static let entryLimit = 512
    private let beforeOpen: (@Sendable (String) -> Void)?

    init(url: URL, beforeOpen: (@Sendable (String) -> Void)? = nil) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        // Resolve the explicitly selected root once; all subsequent accesses
        // use the held descriptor, even if its original pathname is replaced.
        // Foundation deliberately preserves some system aliases (/var, /tmp)
        // even after resolvingSymlinksInPath. POSIX realpath supplies the actual
        // component path needed by the no-follow walk below. Never standardize
        // that result back through Foundation before opening it.
        guard url.isFileURL, !url.path.contains("\0"),
              let resolved = url.path.withCString({ Darwin.realpath($0, nil) }) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw ChatFailure.unsafePath
        }
        let canonicalPath = String(cString: resolved)
        free(resolved)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw ChatFailure.unsafePath
        }
        for part in canonicalPath.split(separator: "/") {
            let next = String(part).withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            Darwin.close(fd); fd = next
            if fd < 0 { break }
        }
        guard fd >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw ChatFailure.unsafePath
        }
        self.root = fd; self.name = URL(fileURLWithPath: canonicalPath).lastPathComponent
        self.securityScopedURL = scoped ? url : nil
        self.beforeOpen = beforeOpen
    }
    deinit {
        Darwin.close(root)
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    static var schemas: [[String: Any]] {
        [tool("list_files", "List immediate entries in a relative folder; symlinks are unavailable.", ["path": "Relative folder, or ." ]),
         tool("read_file", "Read a small UTF-8 regular file in the selected folder.", ["path": "Relative file path"]),
         tool("search_files", "Find literal text in small UTF-8 files, bounded to five directory levels.", ["path": "Relative folder, or .", "query": "Literal search text"]),
         tool("finish_answer", "Return the final answer to the user when enough information is available.", ["answer": "The final answer"])]
    }
    private static func tool(_ name: String, _ description: String, _ properties: [String: String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "properties": properties.mapValues { ["type": "string", "description": $0] },
                           "required": properties.keys.sorted(), "additionalProperties": false]]]
    }
    static func arguments(for call: ChatToolCall) throws -> [String: String] {
        guard call.arguments.utf8.count <= 32 * 1024,
              let data = call.arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw ChatFailure.invalidTool }
        try MalibuStrictJSON.rejectDuplicateKeys(data)
        let keys: Set<String>
        switch call.name {
        case "list_files", "read_file": keys = ["path"]
        case "search_files": keys = ["path", "query"]
        case "finish_answer": keys = ["answer"]
        default: throw ChatFailure.invalidTool
        }
        guard Set(object.keys) == keys, object.values.allSatisfy({ !$0.contains("\0") }),
              object["path"].map({ $0.utf8.count <= 4096 }) ?? true,
              object["query"].map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true
        else { throw ChatFailure.invalidTool }
        return object
    }
    func execute(_ call: ChatToolCall, deadline: ContinuousClock.Instant) throws -> String {
        try check(deadline)
        let args = try Self.arguments(for: call)
        switch call.name {
        case "read_file": return try read(path: args["path"]!, deadline: deadline)
        case "list_files":
            return try entries(path: args["path"]!, deadline: deadline).joined(separator: "\n")
        case "search_files":
            var visited = 0; var scanned = 0; var output: [String] = []; var outputBytes = 0
            try search(path: args["path"]!, query: args["query"]!, depth: 0, visited: &visited,
                       scanned: &scanned, output: &output, outputBytes: &outputBytes, deadline: deadline)
            return output.isEmpty ? "No matches within the bounded search." : output.joined(separator: "\n")
        default: throw ChatFailure.invalidTool
        }
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ChatFailure.timeout }
    }
    private func openPath(_ path: String, directory: Bool) throws -> Int32 {
        guard !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw ChatFailure.unsafePath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == "." || (!parts.isEmpty && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }))
        else { throw ChatFailure.unsafePath }
        var current = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ChatFailure.unsafePath }
        if path == "." {
            guard directory else { Darwin.close(current); throw ChatFailure.unsafePath }
            return current
        }
        for (index, part) in parts.enumerated() {
            beforeOpen?(String(part))
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | ((index < parts.count - 1 || directory) ? O_DIRECTORY : 0)
            let next = String(part).withCString { openat(current, $0, flags) }
            Darwin.close(current)
            guard next >= 0 else { throw ChatFailure.unsafePath }
            current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0,
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else {
            Darwin.close(current); throw ChatFailure.unsafePath
        }
        return current
    }
    private func read(path: String, deadline: ContinuousClock.Instant) throws -> String {
        let fd = try openPath(path, directory: false)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0,
              info.st_size <= Self.fileByteLimit else { throw ChatFailure.limit }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try check(deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw ChatFailure.unsafePath }
            if count == 0 { break }
            guard data.count + count <= Self.fileByteLimit else { throw ChatFailure.limit }
            data.append(buffer, count: count)
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ChatFailure.invalidTool }
        return text
    }
    private func entries(path: String, deadline: ContinuousClock.Instant) throws -> [String] {
        let fd = try openPath(path, directory: true)
        guard let directory = fdopendir(fd) else { Darwin.close(fd); throw ChatFailure.unsafePath }
        defer { closedir(directory) }
        var names: [String] = []; var bytes = 0
        while let entry = readdir(directory) {
            try check(deadline)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            bytes += name.utf8.count + 1
            guard names.count < Self.entryLimit, bytes <= Self.outputByteLimit else { throw ChatFailure.limit }
            names.append(name)
        }
        return names.sorted()
    }
    private func search(path: String, query: String, depth: Int, visited: inout Int, scanned: inout Int,
                        output: inout [String], outputBytes: inout Int, deadline: ContinuousClock.Instant) throws {
        guard depth <= 5 else { return }
        for name in try entries(path: path, deadline: deadline) {
            try check(deadline)
            visited += 1
            guard visited <= Self.entryLimit else { throw ChatFailure.limit }
            let child = path == "." ? name : path + "/" + name
            if let fd = try? openPath(child, directory: true) {
                Darwin.close(fd)
                try search(path: child, query: query, depth: depth + 1, visited: &visited,
                           scanned: &scanned, output: &output, outputBytes: &outputBytes, deadline: deadline)
            } else {
                // Symlinks, binary/oversized files, sockets, and unreadable files
                // are skipped. Cancellation/timeouts still propagate below.
                let text: String
                do { text = try read(path: child, deadline: deadline) }
                catch ChatFailure.unsafePath { continue }
                catch ChatFailure.invalidTool { continue }
                catch ChatFailure.limit { continue }
                scanned += text.utf8.count
                guard scanned <= 512 * 1024 else { throw ChatFailure.limit }
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(query) {
                    let match = "\(child):\(index + 1): \(line.prefix(400))"
                    outputBytes += match.utf8.count + 1
                    guard outputBytes <= Self.outputByteLimit else { throw ChatFailure.limit }
                    output.append(match)
                }
            }
        }
    }
}
