#if DEBUG || MACPROVIDER_LAB_HARNESS
import Darwin
import Foundation
import MacProviderCore

/// Explicit lab evidence only: exact parser-input IDs, before any parsing.
/// The runtime call site exists only in MACPROVIDER_LAB_HARNESS builds.
enum LabOutputTokenCapture {
    private static let lock = NSLock()

    static func record(
        request: ChatCompletionRequest,
        tokenIDs: [Int],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let path = environment["MACPROVIDER_LAB_TOKEN_CAPTURE"], !path.isEmpty else { return }
        guard (path as NSString).isAbsolutePath, !path.utf8.contains(0) else {
            throw failure(EINVAL)
        }
        let record: [String: Any] = [
            "schema": "macprovider.lab-output-tokens.v1",
            "request_id": request.requestID.map { $0 as Any } ?? NSNull(),
            "model": request.model,
            "output_token_ids": tokenIDs,
        ]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        // NONBLOCK prevents an existing FIFO from hanging before fstat rejects
        // it. It has no effect on regular-file append semantics.
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure(errno) }
        var needsClose = true
        defer { if needsClose { _ = Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o600 else {
            throw failure(EACCES)
        }
        try rejectExtendedACL(fd)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws -> Void in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure(written < 0 ? errno : EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw failure(errno) }
        let result = Darwin.close(fd)
        needsClose = false
        guard result == 0 else { throw failure(errno) }
    }

    private static func rejectExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == 0 || errno == ENOENT else { throw failure(errno) }
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0, entry == nil else {
            throw failure(EACCES)
        }
    }

    private static func failure(_ code: Int32) -> NSError {
        NSError(domain: "MacProviderLabTokenCapture", code: Int(code))
    }
}
#endif
