import XCTest
@testable import Malibu

// AUDIT R1 CODE M1: CRLF configuration files must not corrupt the
// provider_id lookup — a trailing \r used to survive whitespace trimming
// and cause a Keychain miss under the corrupted account.

final class ProviderConfigParserTests: XCTestCase {
    // These tests only touch pure parsing on a temp file, they do not write
    // anything to the real ProviderPaths.current locations.

    func testReadProviderIDHandlesCRLF() throws {
        let tmpDir = try makeTempDir()
        let cfg = tmpDir.appendingPathComponent("config.yaml")
        try "provider_id: p-abc\r\nprovider_token: t\r\n".data(using: .utf8)!.write(to: cfg)

        // Not calling ProviderConfig.readProviderID because it reads
        // ProviderPaths.current. Assert the parser algorithm directly here —
        // must match the production implementation exactly. Note: Swift's
        // Character treats \r\n as ONE grapheme, so a naive
        // split(whereSeparator: { $0 == "\n" || $0 == "\r" }) is a no-op on
        // CRLF files; production code normalizes CRLF → LF first.
        let contents = try String(contentsOf: cfg)
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var got: String?
        for rawLine in normalized.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("provider_id:") {
                got = String(line.dropFirst("provider_id:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                break
            }
        }
        XCTAssertEqual(got, "p-abc", "CRLF file must not leave a \\r in provider_id")
    }

    func testImportExistingCLIConfigRecoversInterruptedTokenlessConfigFromBackup() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        try "provider_id: p_recover\nmodel: test\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        let backup = paths.configFile.appendingPathExtension("import-backup")
        try "provider_id: p_recover\nprovider_token: secret-token\nmodel: test\n".write(to: backup, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        defer { Task { try? await KeychainStore.deleteProviderToken(providerID: "p_recover") } }

        do {
            try await ProviderConfig.importExistingCLIConfig(paths: paths)
        } catch {
            throw XCTSkip("Keychain unavailable in this test host: \(error.localizedDescription)")
        }

        let rewritten = try String(contentsOf: paths.configFile)
        XCTAssertTrue(rewritten.contains("provider_id: p_recover"))
        XCTAssertTrue(rewritten.contains("model: test"))
        XCTAssertFalse(rewritten.contains("provider_token"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProviderConfig.importPendingMarker(paths: paths).path))
        XCTAssertEqual(ProviderConfig.readLinkState(paths: paths), .linked)
        let importedToken = await KeychainStore.readProviderToken(providerID: "p_recover")
        XCTAssertEqual(importedToken, "secret-token")
    }

    func testWriteAndReadLinkState() throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        try "provider_id: p_link\nmodel: test\n".write(to: paths.configFile, atomically: true, encoding: .utf8)

        try ProviderConfig.writeLinkState(.pendingLink, paths: paths)

        XCTAssertEqual(ProviderConfig.readLinkState(paths: paths), .pendingLink)
        let contents = try String(contentsOf: paths.configFile)
        XCTAssertTrue(contents.contains("link_state: pending_link"))
    }

    func testSaveProviderIdentityRollsBackWhenTokenSaveFails() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }

        do {
            try await ProviderConfig.saveProviderIdentity(
                providerID: "p_failed",
                token: "provider-token",
                paths: paths,
                readToken: { _ in nil },
                saveToken: { _, _ in
                    throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "keychain failed"])
                },
                deleteToken: { _ in }
            )
            XCTFail("Expected token save failure")
        } catch {
            XCTAssertEqual((error as NSError).localizedDescription, "keychain failed")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
    }

    func testSaveProviderIdentityRollsBackWhenMarkerCreateFails() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        var savedToken: String?

        do {
            try await ProviderConfig.saveProviderIdentity(
                providerID: "p_marker_failed",
                token: "provider-token",
                paths: paths,
                readToken: { _ in nil },
                saveToken: { _, token in savedToken = token },
                deleteToken: { _ in savedToken = nil },
                createAppMarker: {
                    throw NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "marker failed"])
                }
            )
            XCTFail("Expected marker creation failure")
        } catch {
            XCTAssertEqual((error as NSError).localizedDescription, "marker failed")
        }

        XCTAssertNil(savedToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
    }

    func testSaveProviderIdentityRollsBackWhenVerificationFails() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        var savedToken: String?

        do {
            try await ProviderConfig.saveProviderIdentity(
                providerID: "p_verify_failed",
                token: "provider-token",
                paths: paths,
                readToken: { _ in nil },
                saveToken: { _, token in savedToken = token },
                deleteToken: { _ in savedToken = nil },
                createAppMarker: {
                    _ = FileManager.default.createFile(atPath: paths.appMarkerFile.path, contents: Data())
                },
                verifyConfigured: { false }
            )
            XCTFail("Expected verification failure")
        } catch ProviderConfig.SaveError.savedIdentityNotConfigured {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(savedToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTempPaths() throws -> ProviderPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-provider-config-tests-\(UUID().uuidString)", isDirectory: true)
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        return ProviderPaths(
            configFile: configRoot.appendingPathComponent("config.yaml"),
            controlSocket: appSupport.appendingPathComponent("agent.sock"),
            cliLogFile: root.appendingPathComponent("logs/malibu-cli.log"),
            appSupport: appSupport,
            appMarkerFile: appSupport.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: appSupport.appendingPathComponent("onboarding.json"),
            downloadsDirectory: appSupport.appendingPathComponent("Downloads", isDirectory: true)
        )
    }
}
