import Foundation
import Darwin
import Yams

/// Atomic compatibility-token mutation for the provider YAML config.
///
/// Persist strategy: read the current config text, surgically replace
/// (or append) the top-level `provider_token:` line, write the result to
/// a temp file in the same directory with file mode 0600 set BEFORE the
/// secret is written, then `rename(2)` atomically over the original
/// path. Round-tripping through a YAML encoder is intentionally avoided
/// — comments and key ordering would be lost.
///
/// New credentials are never written to YAML. `write` remains for legacy
/// callers and regression coverage; the Option 2 migration uses `remove`
/// only after a restarted, CLI-Keychain-backed provider is admitted.
public enum ProviderTokenPersistError: Error, CustomStringConvertible {
    case readFailed(path: String, underlying: String)
    case writeFailed(path: String, underlying: String)
    case renameFailed(path: String, underlying: String)
    case chmodFailed(path: String, underlying: String)
    case syncFailed(path: String, underlying: String)
    case lockFailed(path: String, underlying: String)
    case parentDirectoryMissing(path: String)

    public var description: String {
        switch self {
        case let .readFailed(path, underlying):
            return "provider_token persist: failed to read config at \(path): \(underlying)"
        case let .writeFailed(path, underlying):
            return "provider_token persist: failed to write temp config at \(path): \(underlying)"
        case let .renameFailed(path, underlying):
            return "provider_token persist: atomic rename failed at \(path): \(underlying)"
        case let .chmodFailed(path, underlying):
            return "provider_token persist: chmod 0600 failed at \(path): \(underlying)"
        case let .syncFailed(path, underlying):
            return "provider_token persist: durable sync failed at \(path): \(underlying)"
        case let .lockFailed(path, underlying):
            return "provider_token persist: advisory lock failed at \(path): \(underlying)"
        case let .parentDirectoryMissing(path):
            return "provider_token persist: parent directory missing at \(path)"
        }
    }
}

/// Cross-process serialization for every mutation of the shared provider YAML.
///
/// The lock file is deliberately stable across atomic config renames. Writers
/// must hold it for the complete read/modify/write transaction, not merely for
/// the final rename, so credential cleanup cannot overwrite a concurrent model
/// or lifecycle update with a stale snapshot.
public enum ProviderConfigMutationLock {
    public final class Handle {
        public let configPath: String
        private let fileDescriptor: Int32

        fileprivate init(configPath: String, fileDescriptor: Int32) {
            self.configPath = configPath
            self.fileDescriptor = fileDescriptor
        }

        deinit {
            _ = flock(fileDescriptor, LOCK_UN)
            _ = close(fileDescriptor)
        }
    }

    public static func acquireExclusive(
        configPath: String,
        timeoutSeconds: TimeInterval? = nil
    ) throws -> Handle {
        let expanded = ConfigLoader.expandTilde(configPath)
        let resolved = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let parent = (resolved as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else {
            throw ProviderTokenPersistError.parentDirectoryMissing(path: parent)
        }

        let lockPath = parent + "/." + ((resolved as NSString).lastPathComponent) + ".lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard lockFD >= 0 else {
            throw ProviderTokenPersistError.lockFailed(
                path: lockPath,
                underlying: String(cString: strerror(errno))
            )
        }
        guard fchmod(lockFD, mode_t(0o600)) == 0 else {
            let failure = String(cString: strerror(errno))
            _ = close(lockFD)
            throw ProviderTokenPersistError.lockFailed(path: lockPath, underlying: failure)
        }

        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
            while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                let lockErrno = errno
                guard lockErrno == EWOULDBLOCK || lockErrno == EAGAIN,
                      Date() < deadline else {
                    _ = close(lockFD)
                    let detail = lockErrno == EWOULDBLOCK || lockErrno == EAGAIN
                        ? "timed out acquiring exclusive lock"
                        : String(cString: strerror(lockErrno))
                    throw ProviderTokenPersistError.lockFailed(path: lockPath, underlying: detail)
                }
                usleep(50_000)
            }
        } else if flock(lockFD, LOCK_EX) != 0 {
            let failure = String(cString: strerror(errno))
            _ = close(lockFD)
            throw ProviderTokenPersistError.lockFailed(path: lockPath, underlying: failure)
        }
        return Handle(configPath: resolved, fileDescriptor: lockFD)
    }

    public static func withExclusiveLock<T>(
        configPath: String,
        _ body: () throws -> T
    ) throws -> T {
        let handle = try acquireExclusive(configPath: configPath)
        defer { withExtendedLifetime(handle) {} }
        return try body()
    }
}

public enum ProviderTokenPersist {
    /// Persist `token` as the value of the top-level YAML key
    /// `provider_token` in the file at `configPath`. If the file does
    /// not exist, it is created (parent directory must exist). If a
    /// `provider_token:` line is already present, it is replaced;
    /// otherwise a new line is appended.
    ///
    /// Atomicity contract: the original file at `configPath` is either
    /// fully replaced by the new contents or unchanged — there is no
    /// partial-write window observable to a concurrent reader, because
    /// `rename(2)` is POSIX-atomic on same-filesystem renames and the
    /// temp file shares the parent directory.
    public static func write(token: String, configPath: String) throws {
        let resolved = canonicalConfigPath(configPath)
        let parent = (resolved as NSString).deletingLastPathComponent
        try ProviderConfigMutationLock.withExclusiveLock(configPath: resolved) {
            let existingText: String
            if FileManager.default.fileExists(atPath: resolved) {
                do {
                    existingText = try String(contentsOfFile: resolved, encoding: .utf8)
                } catch {
                    throw ProviderTokenPersistError.readFailed(path: resolved, underlying: String(describing: error))
                }
            } else {
                existingText = ""
            }

            let newText = applyProviderTokenLine(in: existingText, token: token)
            try replaceAtomically(newText, resolved: resolved, parent: parent)
        }
    }

    /// Remove the top-level compatibility token only when every top-level
    /// value exactly matches `expectedToken`. The comparison and atomic rename
    /// occur under the same advisory lock used by `write`, so a concurrent
    /// config update cannot turn admission proof for one token into deletion
    /// of another token.
    @discardableResult
    public static func remove(expectedToken: String, configPath: String) throws -> Bool {
        let resolved = canonicalConfigPath(configPath)
        let parent = (resolved as NSString).deletingLastPathComponent
        return try ProviderConfigMutationLock.withExclusiveLock(configPath: resolved) {
            try sanitizeAutotuneBackups(resolved: resolved, parent: parent)
            guard FileManager.default.fileExists(atPath: resolved) else { return false }
            let existingText: String
            do {
                existingText = try String(contentsOfFile: resolved, encoding: .utf8)
            } catch {
                throw ProviderTokenPersistError.readFailed(path: resolved, underlying: String(describing: error))
            }

            let expected = expectedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let entries = topLevelProviderTokenEntries(in: existingText)
            guard !expected.isEmpty,
                  !entries.isEmpty,
                  entries.allSatisfy({ $0.value == expected }) else {
                return false
            }

            try replaceAtomically(removingProviderTokenEntries(in: existingText, entries: entries), resolved: resolved, parent: parent)
            return true
        }
    }

    private static func canonicalConfigPath(_ configPath: String) -> String {
        URL(fileURLWithPath: ConfigLoader.expandTilde(configPath))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func replaceAtomically(_ newText: String, resolved: String, parent: String) throws {

        // Same-directory temp so atomic rename stays within one
        // filesystem. Suffix uses UUID so concurrent persists do not
        // collide (rare, but safer than a fixed `.tmp`).
        let tempPath = parent
            + "/." + ((resolved as NSString).lastPathComponent)
            + ".token-persist-" + UUID().uuidString + ".tmp"

        // Create the file empty with mode 0600 BEFORE writing the
        // secret, so the secret never lives on disk under more
        // permissive bits.
        FileManager.default.createFile(atPath: tempPath, contents: Data())
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: tempPath
            )
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ProviderTokenPersistError.chmodFailed(path: tempPath, underlying: String(describing: error))
        }

        do {
            try newText.write(toFile: tempPath, atomically: false, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ProviderTokenPersistError.writeFailed(path: tempPath, underlying: String(describing: error))
        }

        let tempFD = open(tempPath, O_RDONLY | O_NOFOLLOW)
        guard tempFD >= 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ProviderTokenPersistError.syncFailed(
                path: tempPath,
                underlying: String(cString: strerror(errno))
            )
        }
        let tempSyncResult = fsync(tempFD)
        let tempSyncErrno = errno
        close(tempFD)
        guard tempSyncResult == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ProviderTokenPersistError.syncFailed(
                path: tempPath,
                underlying: String(cString: strerror(tempSyncErrno))
            )
        }

        // POSIX rename(2). Foundation's
        // FileManager.replaceItem(at:withItemAt:...) on Darwin lowers
        // to renameat — same semantics, but it also tries to copy
        // attributes from the original which we explicitly do not want
        // (we just set 0600 deliberately). Use the lower-level call.
        let renameRet = rename(tempPath, resolved)
        if renameRet != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ProviderTokenPersistError.renameFailed(path: resolved, underlying: err)
        }


        let directoryFD = open(parent, O_RDONLY)
        guard directoryFD >= 0 else {
            throw ProviderTokenPersistError.syncFailed(
                path: parent,
                underlying: String(cString: strerror(errno))
            )
        }
        let directorySyncResult = fsync(directoryFD)
        let directorySyncErrno = errno
        close(directoryFD)
        guard directorySyncResult == 0 else {
            throw ProviderTokenPersistError.syncFailed(
                path: parent,
                underlying: String(cString: strerror(directorySyncErrno))
            )
        }
    }

    /// Redact legacy autotune backups created before v1.8.34. These files are
    /// machine-owned rollback snapshots (`config.yaml.bak-<unix>-<counter>`),
    /// not credential sources. Operator-named archives and emergency rollback
    /// evidence are deliberately outside this narrow pattern.
    private static func sanitizeAutotuneBackups(resolved: String, parent: String) throws {
        let baseName = (resolved as NSString).lastPathComponent
        let prefix = baseName + ".bak-"
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: parent)
        } catch {
            throw ProviderTokenPersistError.readFailed(path: parent, underlying: String(describing: error))
        }

        for name in names.sorted() {
            guard name.hasPrefix(prefix) else { continue }
            let suffix = name.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
            guard suffix.count == 2, suffix.allSatisfy({ Int($0) != nil }) else { continue }
            let path = parent + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw ProviderTokenPersistError.readFailed(path: path, underlying: String(describing: error))
            }
            let redacted = removingProviderTokenLines(in: text)
            guard redacted != text else { continue }
            try replaceAtomically(redacted, resolved: path, parent: parent)
        }
    }

    public static func removingProviderTokenLines(in existing: String) -> String {
        removingProviderTokenEntries(
            in: existing,
            entries: topLevelProviderTokenEntries(in: existing)
        )
    }

    private struct ProviderTokenEntry {
        let range: Range<Int>
        let value: String?
    }

    private static func topLevelProviderTokenEntries(in existing: String) -> [ProviderTokenEntry] {
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [ProviderTokenEntry] = []
        var index = 0
        while index < lines.count {
            guard let rest = providerTokenValueSource(fromTopLevelLine: lines[index]) else {
                index += 1
                continue
            }
            let start = index
            index += 1
            if rest.trimmingCharacters(in: .whitespaces).hasPrefix("|")
                || rest.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        index += 1
                        continue
                    }
                    guard candidate.first?.isWhitespace == true else { break }
                    index += 1
                }
            }
            let snippet = (["provider_token:\(rest)"] + Array(lines[start + 1..<index])).joined(separator: "\n")
            let raw = try? Yams.load(yaml: snippet)
            let value = (raw as? [String: Any])?["provider_token"] as? String
            entries.append(ProviderTokenEntry(range: start..<index, value: value?.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return entries
    }

    private static func removingProviderTokenEntries(
        in existing: String,
        entries: [ProviderTokenEntry]
    ) -> String {
        guard !entries.isEmpty else { return existing }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var removed = Set<Int>()
        for entry in entries {
            for index in entry.range {
                removed.insert(index)
            }
        }
        return lines.enumerated()
            .filter { !removed.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
    }

    private static func providerTokenValueSource(fromTopLevelLine line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#" else { return nil }
        let characters = Array(line)
        var index = 0
        let key: String
        if characters[index] == "'" {
            index += 1
            var decoded = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "'" {
                    if index < characters.count, characters[index] == "'" {
                        decoded.append("'")
                        index += 1
                        continue
                    }
                    break
                }
                decoded.append(character)
            }
            key = decoded
        } else if characters[index] == "\"" {
            index += 1
            var decoded = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" { break }
                if character == "\\", index < characters.count {
                    let escaped = characters[index]
                    index += 1
                    if let scalar = yamlDoubleQuotedEscape(escaped, characters: characters, index: &index) {
                        decoded.unicodeScalars.append(scalar)
                    } else {
                        decoded.append(escaped)
                    }
                    continue
                }
                decoded.append(character)
            }
            key = decoded
        } else {
            let start = index
            while index < characters.count, characters[index] != ":", !characters[index].isWhitespace {
                index += 1
            }
            key = String(characters[start..<index])
        }
        guard key == "provider_token" else { return nil }
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        guard index < characters.count, characters[index] == ":" else { return nil }
        return String(characters[(index + 1)...])
    }

    private static func yamlDoubleQuotedEscape(
        _ escaped: Character,
        characters: [Character],
        index: inout Int
    ) -> UnicodeScalar? {
        let width: Int
        switch escaped {
        case "x": width = 2
        case "u": width = 4
        case "U": width = 8
        case "0": return UnicodeScalar(0)
        case "a": return UnicodeScalar(0x07)
        case "b": return UnicodeScalar(0x08)
        case "t", "\t": return UnicodeScalar(0x09)
        case "n": return UnicodeScalar(0x0A)
        case "v": return UnicodeScalar(0x0B)
        case "f": return UnicodeScalar(0x0C)
        case "r": return UnicodeScalar(0x0D)
        case "e": return UnicodeScalar(0x1B)
        case "_": return UnicodeScalar(0xA0)
        default: return escaped.unicodeScalars.first
        }
        guard index + width <= characters.count else { return nil }
        let hex = String(characters[index..<index + width])
        index += width
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return UnicodeScalar(value)
    }

    /// Pure helper exposed for testing — given existing config text and
    /// a token, return the text after surgical replace/append of the
    /// top-level `provider_token:` line. Top-level keys ONLY; indented
    /// nested keys (e.g. `provider_token:` under `auth:`) are SKIPPED
    /// without modification. Codex code-reviewer + security-reviewer on
    /// PR #44 flagged the pre-fix version: trimming whitespace before
    /// the prefix check could clobber an indented `provider_token:` and
    /// rewrite it as a top-level key, breaking the parent block.
    ///
    /// Behavior:
    ///   - Lines that start with `provider_token:` at column 0 are
    ///     replaced. ALL such lines are replaced (not just the first)
    ///     so duplicate-key configs converge to a single canonical line
    ///     — code-reviewer MAJOR-2 fix.
    ///   - Lines that start with whitespace then `provider_token:` are
    ///     preserved verbatim — they belong to a nested block this
    ///     helper does not own.
    ///   - Comment lines (e.g. `# provider_token: legacy notes`) are
    ///     preserved verbatim because they do not start with the bare
    ///     key.
    ///   - If no top-level `provider_token:` line existed, one is
    ///     appended.
    public static func applyProviderTokenLine(in existing: String, token: String) -> String {
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        var replacedAny = false
        var output: [String] = []
        output.reserveCapacity(lines.count + 1)
        let newLine = "provider_token: \(token)"
        for line in lines {
            // Top-level match ONLY — no whitespace trim. An indented
            // `provider_token:` inside e.g. an `auth:` block stays put.
            if line.hasPrefix("provider_token:") {
                if !replacedAny {
                    output.append(newLine)
                    replacedAny = true
                }
                // Skip subsequent top-level provider_token lines so
                // duplicates do not survive in the rewritten file.
                continue
            }
            output.append(String(line))
        }
        if !replacedAny {
            if output.isEmpty {
                output.append(newLine)
            } else if !output.last!.isEmpty {
                output.append(newLine)
            } else {
                // File ended with \n — replace the trailing empty
                // sentinel with the token line and add a fresh \n.
                output[output.count - 1] = newLine
                output.append("")
            }
        }
        return output.joined(separator: "\n")
    }
}
