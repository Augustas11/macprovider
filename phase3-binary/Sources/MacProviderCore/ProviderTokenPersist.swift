import Foundation

/// SPEC-003 v0.8 FR-C9.3 — atomically persist a self-minted provisional
/// `provider_token` into the on-disk YAML config so the next reconnect
/// (or the next process restart) authenticates with `Authorization:
/// Bearer <token>`.
///
/// Persist strategy: read the current config text, surgically replace
/// (or append) the top-level `provider_token:` line, write the result to
/// a temp file in the same directory with file mode 0600 set BEFORE the
/// secret is written, then `rename(2)` atomically over the original
/// path. Round-tripping through a YAML encoder is intentionally avoided
/// — comments and key ordering would be lost.
///
/// FR-C9.3 mandates that persist failure MUST NOT crash the binary.
/// Callers catch `ProviderTokenPersistError` and log a warning; the
/// next reconnect will mint another token (FR-C9.4) which gives the
/// persist a fresh attempt.
public enum ProviderTokenPersistError: Error, CustomStringConvertible {
    case readFailed(path: String, underlying: String)
    case writeFailed(path: String, underlying: String)
    case renameFailed(path: String, underlying: String)
    case chmodFailed(path: String, underlying: String)
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
        case let .parentDirectoryMissing(path):
            return "provider_token persist: parent directory missing at \(path)"
        }
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
        let resolved = ConfigLoader.expandTilde(configPath)
        let parent = (resolved as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else {
            throw ProviderTokenPersistError.parentDirectoryMissing(path: parent)
        }

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
