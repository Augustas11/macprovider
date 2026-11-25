import Darwin
import Foundation

enum ChatTranscriptFailure: Error, Equatable {
    case unsafeFile, invalid
}

/// The visible conversation as markdown. Attachment bytes are not included.
enum ChatTranscript {
    static let byteLimit = 8 * 1024 * 1024
    static let exportFailed = "This chat could not be exported."

    static func markdown(title: String, turns: [ChatTurn]) -> String {
        var lines = ["# \(oneLine(title))", ""]
        for turn in turns {
            if !turn.prompt.isEmpty {
                lines.append("## You")
                lines.append(turn.prompt)
                lines.append("")
            }
            for item in turn.attachments {
                lines.append("Attachment: \(oneLine(item.name))")
            }
            if !turn.reasoning.isEmpty {
                lines.append("### Thinking")
                lines.append(turn.reasoning)
                lines.append("")
            }
            if !turn.answer.isEmpty {
                lines.append("## Malibu")
                lines.append(turn.answer)
                lines.append("")
            }
            for name in turn.citations {
                lines.append("Source: \(oneLine(name))")
            }
            for tool in turn.tools {
                lines.append("Tool: \(oneLine(tool))")
            }
            if let note = turn.note, !note.isEmpty {
                lines.append("Note: \(oneLine(note))")
            }
            if !turn.citations.isEmpty || !turn.tools.isEmpty || turn.note != nil {
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Owner-only write. `rename` replaces a symlink entry and does not follow it.
    static func write(_ text: String, to url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"), !url.lastPathComponent.isEmpty else {
            throw ChatTranscriptFailure.unsafeFile
        }
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= byteLimit else { throw ChatTranscriptFailure.invalid }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".malibu-export-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatTranscriptFailure.unsafeFile }
        var failed = false
        defer {
            Darwin.close(fd)
            if failed { unlink(temporary.path) }
        }
        if fchmod(fd, 0o600) != 0 { failed = true; throw ChatTranscriptFailure.unsafeFile }
        var info = stat()
        // A raced hard link would publish the chat through another name.
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            failed = true
            throw ChatTranscriptFailure.unsafeFile
        }
        var remaining = data
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                let wrote = Darwin.write(fd, base, remaining.count)
                return wrote
            }
            if count < 0 {
                if errno == EINTR { continue }
                failed = true
                throw ChatTranscriptFailure.unsafeFile
            }
            if count == 0 { failed = true; throw ChatTranscriptFailure.unsafeFile }
            remaining.removeFirst(count)
        }
        if fsync(fd) != 0 { failed = true; throw ChatTranscriptFailure.unsafeFile }
        if rename(temporary.path, url.path) != 0 {
            failed = true
            throw ChatTranscriptFailure.unsafeFile
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
