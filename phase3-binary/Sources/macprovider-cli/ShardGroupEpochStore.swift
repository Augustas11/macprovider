import Darwin
import Foundation

// Issue #2084 the last group epoch the coordinator accepted for a head (SPEC-051-R005,
// R023). The coordinator refuses any record whose epoch is not above the last one it
// accepted, so a head that rebuilt its chain (after a takeover, a lost member, or a
// restart) at its configured epoch could never register again. The head keeps the
// last accepted epoch in a small owner-only file and builds every chain at
// max(configured epoch, last accepted + 1).

struct ShardGroupEpochStore: Sendable {
    static let schema = "macprovider.shard-group-epoch.v1"

    let url: URL
    let groupProviderID: String

    private struct Contents: Codable {
        let schema: String
        let groupProviderID: String
        let lastRegisteredEpoch: UInt64

        enum CodingKeys: String, CodingKey {
            case schema
            case groupProviderID = "group_provider_id"
            case lastRegisteredEpoch = "last_registered_epoch"
        }
    }

    /// `~/Library/Application Support/macprovider/shard-groups/<group>.json`.
    static func defaultStore(groupProviderID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ShardGroupEpochStore {
        ShardGroupEpochStore(
            url: home.appendingPathComponent("Library/Application Support/macprovider/shard-groups", isDirectory: true)
                .appendingPathComponent("\(groupProviderID).json"),
            groupProviderID: groupProviderID)
    }

    /// The last accepted epoch; nil when none was recorded. A file for another group,
    /// of another schema, or unreadable is an error, not an absence.
    func lastRegisteredEpoch() throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
        guard contents.schema == Self.schema, contents.groupProviderID == groupProviderID else {
            throw ShardGroupConfigError.invalid("\(url.path) is not this group's epoch state")
        }
        return contents.lastRegisteredEpoch
    }

    /// The epoch to build a chain at.
    func buildEpoch(configured: UInt64) throws -> UInt64 {
        guard let last = try lastRegisteredEpoch() else { return configured }
        return max(configured, last + 1)
    }

    /// Record `epoch` when it is above the recorded one: written to a temporary file,
    /// fsynced, renamed over the old file and the directory fsynced, mode 0600.
    func record(_ epoch: UInt64) throws {
        if let last = try lastRegisteredEpoch(), last >= epoch { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Contents(schema: Self.schema, groupProviderID: groupProviderID, lastRegisteredEpoch: epoch))
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Error?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        Darwin.close(fd)
        if let failure {
            unlink(temporary.path)
            throw failure
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            Darwin.close(directoryFD)
        }
    }
}
