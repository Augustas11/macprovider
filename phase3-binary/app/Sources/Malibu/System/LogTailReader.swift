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
        let sanitized = scrubNonSecretIdentifiers(line)
        if containsSecret(line) || containsSecret(sanitized) {
            return "[redacted]"
        }
        return sanitized
    }

    private static func containsSecret(_ line: String) -> Bool {
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
            return true
        }
        return false
    }

    private static func matchesSecretPattern(_ line: String) -> Bool {
        let patterns = [
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-=]{12,}"#,
            #"(?i)(^|[^A-Za-z0-9_-])["']?authorization["']?\s*[:=]\s*["']?\S+"#,
            #"(?i)\b(provider|identity|auth|access|refresh|session)[_-]?token\b\s*[:=]\s*\S+"#,
            #"(?i)\b(api[_-]?key|client[_-]?secret|password|cookie)\b\s*[:=]\s*\S+"#,
            #"(?i)https?://\S+\?\S+"#
        ]
        return patterns.contains { pattern in
            line.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func scrubNonSecretIdentifiers(_ line: String) -> String {
        scrubNonSecretIdentifiers(
            line,
            usernameCandidates: [
                NSUserName(),
                FileManager.default.homeDirectoryForCurrentUser.lastPathComponent,
            ],
            hostnameCandidates: currentHostnameCandidates()
        )
    }

    static func redactedForTest(
        _ line: String,
        usernameCandidates: [String],
        hostnameCandidates: [String?] = []
    ) -> String {
        let sanitized = scrubNonSecretIdentifiers(
            line,
            usernameCandidates: usernameCandidates,
            hostnameCandidates: hostnameCandidates
        )
        if containsSecret(line) || containsSecret(sanitized) {
            return "[redacted]"
        }
        return sanitized
    }

    private static func currentHostnameCandidates() -> [String?] {
        var candidates: [String?] = [
            ProcessInfo.processInfo.hostName,
            ProcessInfo.processInfo.hostName.components(separatedBy: ".").first,
        ]
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buffer, buffer.count) == 0 {
            let hostname = String(cString: buffer)
            candidates.append(hostname)
            candidates.append(hostname.components(separatedBy: ".").first)
        }
        return candidates
    }

    private static func scrubNonSecretIdentifiers(
        _ line: String,
        usernameCandidates rawUsernameCandidates: [String],
        hostnameCandidates rawHostnameCandidates: [String?]
    ) -> String {
        var output = String(line.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !(value <= 0x1F || (0x7F...0x9F).contains(value))
        })

        let usernameCandidates = rawUsernameCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        for username in orderedIdentifierCandidates(usernameCandidates) {
            output = output.replacingOccurrences(of: username, with: "[user]")
        }

        let hostnameCandidates = rawHostnameCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        for hostname in orderedIdentifierCandidates(hostnameCandidates) {
            output = output.replacingOccurrences(of: hostname, with: "[host]")
        }

        let replacements: [(String, String)] = [
            (#"(?i)\b(user(?:name)?|login|account)=([^\s,;]+)"#, "$1=[user]"),
            (#"(?i)\b(host(?:name)?|computer[_-]?name|machine|nodename)=([^\s,;]+)"#, "$1=[host]"),
            (#"\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)*\.local\b"#, "[host]"),
            (#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b"#, "[ip]"),
        ]
        for (pattern, template) in replacements {
            output = output.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        return scrubAbsolutePaths(scrubIPAddresses(output))
    }

    private static func orderedIdentifierCandidates(_ candidates: [String]) -> [String] {
        Array(Set(candidates)).sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs < rhs
        }
    }

    private static func scrubAbsolutePaths(_ line: String) -> String {
        let line = line.replacingOccurrences(of: #"\/"#, with: "/")
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line.lowercasedRange(from: index, hasPrefix: "file:///") {
                let pathStart = line.index(index, offsetBy: "file://".count)
                output += "file://[path]"
                index = line.indexAfterAbsolutePath(startingAt: pathStart)
                continue
            }
            let character = line[index]
            if character == "/", isPathBoundary(before: index, in: line) {
                output += "[path]"
                index = line.indexAfterAbsolutePath(startingAt: index)
            } else {
                output.append(character)
                index = line.index(after: index)
            }
        }
        return output
    }

    private static func scrubIPAddresses(_ line: String) -> String {
        var output = ""
        var token = ""

        func flushToken() {
            guard !token.isEmpty else { return }
            output += redactedIPToken(token) ?? token
            token = ""
        }

        for character in line {
            if isIPTokenCharacter(character) {
                token.append(character)
            } else {
                flushToken()
                output.append(character)
            }
        }
        flushToken()
        return output
    }

    private static func isIPTokenCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "."
            || character == ":"
            || character == "%"
            || character == "["
            || character == "]"
    }

    private static func redactedIPToken(_ token: String) -> String? {
        guard token.contains(".") || token.contains(":") else { return nil }
        let split = splitTrailingPunctuation(from: token)
        let candidate = split.candidate
        if candidate.hasPrefix("["),
           let closeBracket = candidate.firstIndex(of: "]") {
            let addressStart = candidate.index(after: candidate.startIndex)
            let address = String(candidate[addressStart..<closeBracket])
            let suffix = candidate[candidate.index(after: closeBracket)...]
            guard suffix.isEmpty || isPortSuffix(suffix),
                  isIPAddress(address) else {
                return nil
            }
            return "[ip]" + split.trailing
        }
        if isIPAddress(candidate) {
            return "[ip]" + split.trailing
        }
        if let colon = candidate.lastIndex(of: ":") {
            let suffix = candidate[colon...]
            let prefix = String(candidate[..<colon])
            if isPortSuffix(suffix), isIPAddress(prefix) {
                return "[ip]" + split.trailing
            }
        }
        return nil
    }

    private static func splitTrailingPunctuation(from token: String) -> (candidate: String, trailing: String) {
        var candidate = token
        var trailing = ""
        while let last = candidate.last,
              last == "." || last == "," || last == ";" {
            trailing.insert(last, at: trailing.startIndex)
            candidate.removeLast()
        }
        return (candidate, trailing)
    }

    private static func isPortSuffix(_ suffix: Substring) -> Bool {
        guard suffix.first == ":" else { return false }
        let digits = suffix.dropFirst()
        return (1...5).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }

    private static func isIPAddress(_ rawAddress: String) -> Bool {
        let address = rawAddress.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? rawAddress
        guard !address.isEmpty else { return false }
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private static func isPathBoundary(before index: String.Index, in line: String) -> Bool {
        guard index > line.startIndex else { return true }
        let previous = line[line.index(before: index)]
        if previous == ":" {
            let next = line.index(after: index)
            return next == line.endIndex || line[next] != "/"
        }
        return previous.isWhitespace || #""'(<[{="#.contains(previous)
    }
}

private extension String {
    func lowercasedRange(from index: String.Index, hasPrefix prefix: String) -> Bool {
        let end = self.index(index, offsetBy: prefix.count, limitedBy: endIndex) ?? endIndex
        guard distance(from: index, to: end) == prefix.count else { return false }
        return self[index..<end].lowercased() == prefix
    }

    func indexAfterAbsolutePath(startingAt start: String.Index) -> String.Index {
        var index = self.index(after: start)
        while index < endIndex {
            let character = self[index]
            if #""'`<>|;,"#.contains(character) {
                break
            }
            if character.isWhitespace {
                let next = self.index(after: index)
                if next == endIndex || tokenAfterWhitespaceStartsKeyValue(at: next) {
                    break
                }
            }
            index = self.index(after: index)
        }
        return index
    }

    private func tokenAfterWhitespaceStartsKeyValue(at start: String.Index) -> Bool {
        var index = start
        guard index < endIndex,
              self[index].isLetter || self[index] == "_" else {
            return false
        }
        index = self.index(after: index)
        while index < endIndex {
            let character = self[index]
            if character == "=" || character == ":" {
                return true
            }
            if character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." {
                index = self.index(after: index)
            } else {
                return false
            }
        }
        return false
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
              fileInfo.st_mode & (S_IWGRP | S_IWOTH) == 0,
              hasNoExtendedACL(descriptor),
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

    private nonisolated static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        _ = acl_free(UnsafeMutableRawPointer(acl))
        return false
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
