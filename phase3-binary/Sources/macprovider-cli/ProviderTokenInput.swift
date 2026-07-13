import ArgumentParser
import Foundation
import MacProviderCore

enum ProviderTokenInput {
    /// Reads a provider bearer from an inherited descriptor. Callers write the
    /// token bytes and close their end; the credential never enters argv, the
    /// process environment, or a filesystem-backed token file.
    static func read(fromFileDescriptor fd: Int32) throws -> String {
        guard fd >= 0 else {
            throw ValidationError("--token-fd must be a non-negative file descriptor")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw ValidationError("could not read provider token from --token-fd \(fd): \(error)")
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ValidationError("provider token on --token-fd \(fd) is not valid UTF-8")
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ValidationError("provider token on --token-fd \(fd) was empty")
        }
        return token
    }

    static func apply(fileDescriptor: Int?, to config: inout AppConfig) throws {
        guard let fileDescriptor else { return }
        config.providerToken = try read(fromFileDescriptor: Int32(fileDescriptor))
    }
}
