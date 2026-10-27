import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import Security

/// Only the explicit isolated command opens this task-local scope. A provider
/// listener cannot acquire it through configuration or environment variables.
enum NativeMTPQualificationScope {
    @TaskLocal static var identity: NativeMTPMeasurementIdentity?

    static var permitsFixtureHooks: Bool {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        return true
#else
        return identity != nil
        #endif
    }

    static func run(_ body: () async throws -> Void) async throws {
        let measured = try NativeMTPMeasurementIdentity.captureSelf()
        try await $identity.withValue(measured) { try await body() }
    }

    static func bind(_ document: [String: Any]) -> [String: Any] {
        guard let identity else { return document }
        var result = document
        result["measurement_identity"] = identity.document
        return result
    }
}

struct NativeMTPMeasurementIdentity: Equatable, Sendable {
    let binarySHA256: String
    let binaryCDHash: String
    var document: [String: String] { ["binary_sha256": binarySHA256, "binary_cdhash": binaryCDHash] }

    static func captureSelf() throws -> Self {
        var dynamic: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamic) == errSecSuccess, let dynamic,
              SecCodeCheckValidity(dynamic, SecCSFlags(), nil) == errSecSuccess else {
            throw ValidationError("qualification requires a valid signed running executable")
        }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw ValidationError("qualification executable identity unavailable")
        }
        func information() throws -> NSDictionary {
            var raw: CFDictionary?
            guard SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 1 << 1), &raw) == errSecSuccess,
                  let raw else { throw ValidationError("qualification executable signature invalid") }
            return raw as NSDictionary
        }
        let before = try information()
        guard let executable = before[kSecCodeInfoMainExecutable as String] as? URL,
              let cdhash = before[kSecCodeInfoUnique as String] as? Data, cdhash.count == 20,
              let teamID = before[kSecCodeInfoTeamIdentifier as String] as? String, !teamID.isEmpty,
              let flags = before[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 2 == 0 else {
            throw ValidationError("qualification requires a non-ad-hoc signed acceptance executable")
        }
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(handle.fileDescriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("qualification executable file unavailable")
        }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        var final = stat()
        let after = try information()
        guard fstat(handle.fileDescriptor, &final) == 0,
              initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
              after[kSecCodeInfoUnique as String] as? Data == cdhash,
              PrivacyCodeSignature.readSelf().cdhashHex == cdhash.map({ String(format: "%02x", $0) }).joined() else {
            throw ValidationError("qualification executable changed during identity capture")
        }
        return Self(binarySHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                    binaryCDHash: cdhash.map { String(format: "%02x", $0) }.joined())
    }
}

struct NativeMTPQualificationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-qualify", abstract: "Isolated signed SPEC-048 qualification; never joins a coordinator.",
        shouldDisplay: false,
        subcommands: [NativeMTPSignedAcceptanceCommand.self, NativeMTPSignedBenchCommand.self, NativeMTPSignedReplayCommand.self])
}

struct NativeMTPSignedBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bench", shouldDisplay: false)
    @OptionGroup var arguments: NativeMTPBenchCommand
    func run() async throws {
        guard let path = arguments.policyPath, arguments.policyList.isEmpty else {
            throw ValidationError("signed qualification requires one formal bench policy")
        }
        let policy = try NativeMTPBenchPolicy.load(from: URL(fileURLWithPath: ConfigLoader.expandTilde(path)))
        guard !policy.exploratory, !policy.diagnosticEligibilityBypass else {
            throw ValidationError("signed qualification forbids exploratory or diagnostic policies")
        }
        try await NativeMTPQualificationScope.run { try await arguments.run() }
    }
}

struct NativeMTPSignedReplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replay", shouldDisplay: false)
    @OptionGroup var arguments: NativeMTPRequestShapeReplayCommand
    func run() async throws {
        let policy = try NativeMTPBenchPolicy.load(from: URL(fileURLWithPath: ConfigLoader.expandTilde(arguments.benchPolicyPath)))
        guard !policy.exploratory, !policy.diagnosticEligibilityBypass else {
            throw ValidationError("signed qualification requires formal replay bench policy")
        }
        try await NativeMTPQualificationScope.run { try await arguments.run() }
    }
}

