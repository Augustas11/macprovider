import Foundation

public struct ClaimURLRecord: Equatable, Sendable {
    public let pairOT: String
    public let claimURL: String
    public let expiresAt: Date
}

public enum ClaimURLFileError: Error, CustomStringConvertible {
    case parentDirectoryMissing(path: String)
    case writeFailed(path: String, underlying: String)
    case chmodFailed(path: String, underlying: String)
    case renameFailed(path: String, underlying: String)
    case invalidBody

    public var description: String {
        switch self {
        case let .parentDirectoryMissing(path):
            return "claim_url: parent directory missing at \(path)"
        case let .writeFailed(path, underlying):
            return "claim_url: failed to write \(path): \(underlying)"
        case let .chmodFailed(path, underlying):
            return "claim_url: chmod 0600 failed at \(path): \(underlying)"
        case let .renameFailed(path, underlying):
            return "claim_url: atomic rename failed at \(path): \(underlying)"
        case .invalidBody:
            return "claim_url: invalid body"
        }
    }
}

public final class ClaimURLFile: @unchecked Sendable {
    public let fileURL: URL
    public let ownerURL: URL

    public init(configPath: String) {
        let resolved = ConfigLoader.expandTilde(configPath)
        let directory = URL(fileURLWithPath: (resolved as NSString).deletingLastPathComponent, isDirectory: true)
        self.fileURL = directory.appendingPathComponent("claim_url")
        self.ownerURL = directory.appendingPathComponent("owner.txt")
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("claim_url")
        self.ownerURL = directory.appendingPathComponent("owner.txt")
    }

    public func write(pairOT: String, claimURL: String, expiresAt: Date) throws {
        let body = """
        pair_ot=\(pairOT)
        claim_url=\(claimURL)
        expires_at=\(Self.formatDate(expiresAt))

        """
        try Self.atomicWrite0600(body, to: fileURL)
    }

    public func writeMigrationStub() throws {
        try Self.atomicWrite0600("needs_refresh=true\n", to: fileURL)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func writeOwner(githubLogin: String) throws {
        try Self.atomicWrite0600("github_login=\(githubLogin)\n", to: ownerURL)
    }

    public func read() throws -> ClaimURLRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let body = try String(contentsOf: fileURL, encoding: .utf8)
        if body.trimmingCharacters(in: .whitespacesAndNewlines) == "needs_refresh=true" {
            return nil
        }
        var values: [String: String] = [:]
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        guard let pairOT = values["pair_ot"],
              let claimURL = values["claim_url"],
              let expiresText = values["expires_at"],
              let expiresAt = Self.parseDate(expiresText)
        else {
            throw ClaimURLFileError.invalidBody
        }
        return ClaimURLRecord(pairOT: pairOT, claimURL: claimURL, expiresAt: expiresAt)
    }

    public static func atomicWrite0600(_ text: String, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ClaimURLFileError.parentDirectoryMissing(path: parent.path)
        }
        let tempURL = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data())
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: tempURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ClaimURLFileError.chmodFailed(path: tempURL.path, underlying: String(describing: error))
        }
        do {
            try text.write(to: tempURL, atomically: false, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ClaimURLFileError.writeFailed(path: tempURL.path, underlying: String(describing: error))
        }
        if rename(tempURL.path, destination.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tempURL)
            throw ClaimURLFileError.renameFailed(path: destination.path, underlying: err)
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
