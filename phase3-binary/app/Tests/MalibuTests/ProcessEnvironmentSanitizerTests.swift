import XCTest
@testable import Malibu

final class ProcessEnvironmentSanitizerTests: XCTestCase {
    func testChildEnvironmentKeepsOnlyAllowlistedInheritedValuesAndExplicitToken() throws {
        let sanitized = try ProcessEnvironmentSanitizer.sanitized(
            from: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/test",
                "LC_CTYPE": "UTF-8",
                "MACPROVIDER_EVIL": "1",
                "MALIBU_CLI_PATH": "/tmp/fake"
            ],
            extraEnvironment: [
                "MACPROVIDER_PROVIDER_TOKEN": "provider-token"
            ]
        )

        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(sanitized["MACPROVIDER_PROVIDER_TOKEN"], "provider-token")
        XCTAssertNil(sanitized["MACPROVIDER_EVIL"])
        XCTAssertNil(sanitized["MALIBU_CLI_PATH"])
    }

    func testChildEnvironmentRejectsUnsafeInheritedValue() {
        XCTAssertThrowsError(try ProcessEnvironmentSanitizer.sanitized(from: [
            "PATH": "/usr/bin;evil"
        ]))
    }

    func testAutotuneRecommendationEnvironmentUsesAllowlist() throws {
        let sanitized = try AutotuneRecommendationRunner.sanitizedProcessEnvironment(from: [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/test",
            "LC_CTYPE": "UTF-8",
            "MACPROVIDER_PROVIDER_TOKEN": "secret",
            "PYTHONPATH": "/tmp/injected"
        ])

        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["HOME"], "/Users/test")
        XCTAssertEqual(sanitized["LC_CTYPE"], "UTF-8")
        XCTAssertNil(sanitized["MACPROVIDER_PROVIDER_TOKEN"])
        XCTAssertNil(sanitized["PYTHONPATH"])
    }

    func testReleaseCLIPathFallsBackWhenPinnedTeamMissing() throws {
        #if !DEBUG
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-cli-path-tests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Malibu.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let bundled = macos.appendingPathComponent("malibu-cli")
        FileManager.default.createFile(atPath: bundled.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try MalibuAgent.resolveCLIExecutable(
            environment: ["MALIBU_CLI_PATH": "/tmp/unsigned-cli"],
            bundleURL: app
        )

        XCTAssertEqual(resolved, bundled)
        #endif
    }
}
