import Combine
import Darwin
import Foundation

struct LogTailBuffer: Equatable {
    private(set) var lines: [String] = []
    let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    mutating func append(contentsOf newLines: [String]) {
        guard capacity > 0 else {
            lines = []
            return
        }
        lines.append(contentsOf: newLines.map(Self.redacted))
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    static func redacted(_ line: String) -> String {
        let lower = line.lowercased()
        let normalizedIdentifierText = lower.filter { $0.isLetter || $0.isNumber }
        if lower.contains("provider_token")
            || lower.contains("identity_signature")
            || lower.contains("authorization:")
            || lower.contains("token_sha256")
            || lower.contains("token_hash")
            || lower.contains("private_key")
            || lower.contains("api_key")
            || lower.contains("client_secret")
            || lower.contains("password")
            || lower.contains("set-cookie")
            || lower.contains("signed_payload")
            || lower.contains("payload_to_sign")
            || normalizedIdentifierText.contains("providertoken")
            || normalizedIdentifierText.contains("identitysignature")
            || normalizedIdentifierText.contains("privatekey")
            || normalizedIdentifierText.contains("apikey")
            || normalizedIdentifierText.contains("clientsecret")
            || normalizedIdentifierText.contains("password")
            || normalizedIdentifierText.contains("setcookie")
            || normalizedIdentifierText.contains("signedpayload")
            || normalizedIdentifierText.contains("payloadtosign")
            || normalizedIdentifierText.contains("tokensha256")
            || normalizedIdentifierText.contains("tokenhash")
            || (lower.contains("-----begin") && lower.contains("private key-----"))
            || Self.matchesSecretPattern(line) {
            return "[redacted]"
        }
        return line
    }

    private static func matchesSecretPattern(_ line: String) -> Bool {
        let patterns = [
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-=]{12,}"#,
            #"(?i)\b(provider|identity|auth|access|refresh|session)[_-]?token\b\s*[:=]\s*\S+"#,
            #"(?i)\b(api[_-]?key|client[_-]?secret|password|cookie)\b\s*[:=]\s*\S+"#,
            #"(?i)https?://\S+\?\S+"#
        ]
        return patterns.contains { pattern in
            line.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

@MainActor
final class LogTailReader: ObservableObject {
    @Published private(set) var lines: [String] = []

    private let fileURL: URL
    private let maxReadBytes: UInt64
    private let maxPendingFragmentCharacters: Int
    private var buffer: LogTailBuffer
    private var offset: UInt64 = 0
    private var pendingFragment = ""
    private var task: Task<Void, Never>?

    init(
        fileURL: URL,
        capacity: Int = 200,
        maxReadBytes: UInt64 = 128 * 1024,
        maxPendingFragmentCharacters: Int = 8 * 1024
    ) {
        self.fileURL = fileURL
        self.maxReadBytes = max(1, maxReadBytes)
        self.maxPendingFragmentCharacters = max(1, maxPendingFragmentCharacters)
        self.buffer = LogTailBuffer(capacity: capacity)
    }

    func start(intervalNanoseconds: UInt64 = 1_000_000_000) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readAvailable()
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func readAvailable() async {
        let fileURL = fileURL
        let previousOffset = offset
        let previousFragment = pendingFragment
        let maxReadBytes = maxReadBytes
        let maxPendingFragmentCharacters = maxPendingFragmentCharacters
        let result = await Task.detached(priority: .utility) {
            Self.readChunk(
                fileURL: fileURL,
                offset: previousOffset,
                pendingFragment: previousFragment,
                maxReadBytes: maxReadBytes,
                maxPendingFragmentCharacters: maxPendingFragmentCharacters
            )
        }.value
        guard let result else { return }
        offset = result.offset
        pendingFragment = result.pendingFragment
        appendCompleteLines(result.lines)
    }

    private func appendCompleteLines(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        buffer.append(contentsOf: newLines)
        lines = buffer.lines
    }

    nonisolated private static func readChunk(
        fileURL: URL,
        offset previousOffset: UInt64,
        pendingFragment previousFragment: String,
        maxReadBytes: UInt64,
        maxPendingFragmentCharacters: Int
    ) -> ReadResult? {
        guard maxReadBytes <= UInt64(Int.max) else { return nil }
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == getuid(),
              Int(fileInfo.st_nlink) == 1,
              fileInfo.st_size >= 0 else {
            return nil
        }

        let size = UInt64(fileInfo.st_size)
        var offset = previousOffset
        var pendingFragment = previousFragment
        var startedInsideExistingFile = false

        if size < offset {
            offset = 0
            pendingFragment = ""
        }
        if offset == 0, size > maxReadBytes {
            offset = size - maxReadBytes
            pendingFragment = ""
            startedInsideExistingFile = true
        } else if size - offset > maxReadBytes {
            offset = size - maxReadBytes
            pendingFragment = ""
            startedInsideExistingFile = true
        }

        guard Darwin.lseek(descriptor, off_t(offset), SEEK_SET) != -1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(maxReadBytes))
        let bytesRead = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard bytesRead >= 0 else { return nil }

        let nextOffset = offset + UInt64(bytesRead)
        guard bytesRead > 0,
              let data = String(bytes: bytes.prefix(bytesRead), encoding: .utf8) else {
            return ReadResult(offset: nextOffset, pendingFragment: pendingFragment, lines: [])
        }
        var chunk = data
        if startedInsideExistingFile, let newline = chunk.firstIndex(where: \.isNewline) {
            chunk = String(chunk[chunk.index(after: newline)...])
        }
        let parsed = parseChunk(
            chunk,
            pendingFragment: pendingFragment,
            maxPendingFragmentCharacters: maxPendingFragmentCharacters
        )
        return ReadResult(offset: nextOffset, pendingFragment: parsed.pendingFragment, lines: parsed.lines)
    }

    nonisolated private static func parseChunk(
        _ chunk: String,
        pendingFragment: String,
        maxPendingFragmentCharacters: Int
    ) -> (pendingFragment: String, lines: [String]) {
        let combined = pendingFragment + chunk
        var parts = combined.components(separatedBy: .newlines)
        let pendingFragment = String((parts.popLast() ?? "").suffix(maxPendingFragmentCharacters))
        let nonEmpty = parts.filter { !$0.isEmpty }
        return (pendingFragment, nonEmpty)
    }

    private struct ReadResult: Sendable {
        let offset: UInt64
        let pendingFragment: String
        let lines: [String]
    }
}
