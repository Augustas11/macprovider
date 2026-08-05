import CryptoKit
import Darwin
import XCTest
@testable import Malibu

final class ReferralOnboardingTests: XCTestCase {
    private let validCode = "MAL1-S-key_1-issuer_1-" + String(repeating: "A", count: 26)

    func testNormalizesExactCodeAndCanonicalJoinLink() throws {
        XCTAssertEqual(try ReferralOnboardingInput.normalize(validCode), validCode)
        XCTAssertEqual(
            try ReferralOnboardingInput.normalize("https://malibu.tech/j#/\(validCode)"),
            validCode
        )
        XCTAssertEqual(
            try ReferralOnboardingInput.normalize(
                "https://malibu.tech/j#/\(validCode)?c=\(String(repeating: "a", count: 64))"
            ),
            validCode
        )
        XCTAssertNil(try ReferralOnboardingInput.normalize("  \n"))
    }

    func testRejectsNonCanonicalOrAuthorityChangingLinks() {
        for input in [
            "http://malibu.tech/j/\(validCode)",
            "https://evil.example/j/\(validCode)",
            "https://coordinator.streamvc.live/j/\(validCode)",
            "https://user@malibu.tech/j/\(validCode)",
            "https://malibu.tech:443/j/\(validCode)",
            "https://malibu.tech/j#/\(validCode)?next=evil",
            "https://malibu.tech/j#/\(validCode)?c=\(String(repeating: "a", count: 64))&next=evil",
            "https://malibu.tech/j#/\(validCode)?c=\(String(repeating: "A", count: 64))",
            "https://malibu.tech/j#/%4D\(validCode.dropFirst())",
            "https://malibu.tech//j/\(validCode)",
            "https://malibu.tech/j#/\(validCode)/",
            validCode.lowercased(),
        ] {
            XCTAssertThrowsError(try ReferralOnboardingInput.normalize(input), input)
        }
    }

    func testInstallContractAcceptsExactRegularFiles() throws {
        let fixture = try Fixture(script: Data("#!/bin/bash\nexit 0\n".utf8))
        defer { fixture.remove() }

        XCTAssertNoThrow(
            try BundledInstallContractVerifier.verify(
                scriptURL: fixture.script,
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        )
    }

    func testInstallContractRejectsMismatchAndSymlink() throws {
        let fixture = try Fixture(script: Data("#!/bin/bash\nexit 0\n".utf8))
        defer { fixture.remove() }
        try Data("tampered\n".utf8).write(to: fixture.script)
        XCTAssertThrowsError(
            try BundledInstallContractVerifier.verify(
                scriptURL: fixture.script,
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        )

        let target = fixture.root.appendingPathComponent("target.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: target)
        let link = fixture.root.appendingPathComponent("linked.sh")
        XCTAssertEqual(symlink(target.path, link.path), 0)
        XCTAssertThrowsError(
            try BundledInstallContractVerifier.verify(
                scriptURL: link,
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        )
    }

    func testInstallContractRejectsUnsignedOrNonCanonicalManifest() throws {
        let fixture = try Fixture(script: Data("#!/bin/bash\nexit 0\n".utf8))
        defer { fixture.remove() }
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any]
        )
        envelope["signatures"] = []
        let unsigned = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
        try unsigned.write(to: fixture.manifest)

        XCTAssertThrowsError(
            try BundledInstallContractVerifier.verify(
                scriptURL: fixture.script,
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        )
    }

    func testReferralCodeFileIsOwnerOnlyRegularAndContainsOnlyCode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("referral-code-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try ReferralCodeFile.create(code: validCode, directory: root)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), validCode)
    }

    func testInstallerEnvironmentPassesOnlyReferralFilePath() throws {
        let referralURL = URL(fileURLWithPath: "/tmp/referral-secret")
        let environment = try CLIInstallRunner.installerEnvironment(
            parentEnvironment: [
                "MACPROVIDER_REFERRAL_CODE_FILE": "/tmp/attacker",
                "MACPROVIDER_REFERRAL_CODE": validCode,
            ],
            installPort: nil,
            pinnedVersion: nil,
            referralCodeFile: referralURL
        )

        XCTAssertEqual(environment["MACPROVIDER_REFERRAL_CODE_FILE"], referralURL.path)
        XCTAssertNil(environment["MACPROVIDER_REFERRAL_REPLACE_INCUMBENT"])
        XCTAssertNil(environment["MACPROVIDER_REFERRAL_CODE"])
        XCTAssertFalse(environment.values.contains(validCode))
    }

    func testInstallerEnvironmentPassesReplacementIntentOnlyWithReferralFile() throws {
        let referralURL = URL(fileURLWithPath: "/tmp/referral-secret")
        let replacementEnvironment = try CLIInstallRunner.installerEnvironment(
            parentEnvironment: [:],
            installPort: nil,
            pinnedVersion: nil,
            referralCodeFile: referralURL,
            replacingIncumbentProvider: true
        )
        XCTAssertEqual(replacementEnvironment["MACPROVIDER_REFERRAL_CODE_FILE"], referralURL.path)
        XCTAssertEqual(replacementEnvironment["MACPROVIDER_REFERRAL_REPLACE_INCUMBENT"], "1")

        let noReferralEnvironment = try CLIInstallRunner.installerEnvironment(
            parentEnvironment: [:],
            installPort: nil,
            pinnedVersion: nil,
            referralCodeFile: nil,
            replacingIncumbentProvider: true
        )
        XCTAssertNil(noReferralEnvironment["MACPROVIDER_REFERRAL_REPLACE_INCUMBENT"])
    }

    func testBundledInstallerEnablesReceiptsOnlyForFreshReferralBootstrap() throws {
        let scriptURL = try CLIInstallRunner.resolveInstallScriptURL()
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("FRESH_REFERRAL_BOOTSTRAP=0"))
        XCTAssertTrue(script.contains("enable_fresh_referral_receipts"))
        XCTAssertTrue(
            script.contains(#"[ "$FRESH_REFERRAL_BOOTSTRAP" -eq 1 ] || return 0"#)
        )
        XCTAssertTrue(script.contains(#""enable_receipts"] = "true""#))
    }

    private struct Fixture {
        let root: URL
        let script: URL
        let manifest: URL
        let publicKeyPEM: String

        init(script data: Data) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("install-contract-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            script = root.appendingPathComponent("install.sh")
            manifest = root.appendingPathComponent("compatibility-set.json")
            try data.write(to: script, options: .atomic)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let signingKey = P256.Signing.PrivateKey()
            publicKeyPEM = signingKey.publicKey.pemRepresentation
            let signed: [String: Any] = [
                "artifact_binding": [:],
                "compatibility_set_id": "Augustas11/macprovider:v1.8.41@" + String(repeating: "a", count: 40),
                "components": [
                    "catalog": [:],
                    "coordinator_admission": [:],
                    "launchd": [
                        "activation": "local",
                        "contract": "macprovider.launch-agent.v1",
                        "install_contract": [
                            "path": "compatibility-set-local/install.sh",
                            "sha256": digest,
                        ],
                        "label": "live.streamvc.macprovider",
                        "plist_template": [:],
                    ],
                    "malibu_app": [:],
                    "provider_cli": [:],
                    "updater_rollback": [:],
                    "watchdog": [:],
                ],
                "release": [:],
                "schema_version": "macprovider.compatibility-set.v1",
                "transaction": [:],
            ]
            var signedBytes = try JSONSerialization.data(
                withJSONObject: signed,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            signedBytes.append(0x0a)
            let signature = try signingKey.signature(for: SHA256.hash(data: signedBytes))
            let envelope: [String: Any] = [
                "schema_version": "macprovider.compatibility-set-envelope.v1",
                "signatures": [[
                    "algorithm": "ecdsa-p256-sha256",
                    "key_id": "macprovider-release-p256-v1",
                    "signature": signature.derRepresentation.base64EncodedString(),
                ]],
                "signed": signed,
            ]
            var manifestData = try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            manifestData.append(0x0a)
            try manifestData.write(to: manifest, options: .atomic)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
