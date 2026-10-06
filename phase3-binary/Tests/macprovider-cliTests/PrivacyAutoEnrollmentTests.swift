import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-049-R024 provider automatic mode and eligibility fallbacks.
final class PrivacyAutoEnrollmentTests: XCTestCase {
    func testModeResolutionAndOptOuts() throws {
        let empty = try autoTempConfig("")
        defer { try? FileManager.default.removeItem(at: empty) }
        let unset = try ConfigLoader.load(cli: CLIOverrides(configPath: empty.path), environment: [:])
        XCTAssertEqual(PrivacyAutoEnrollment.mode(unset), .automatic)
        XCTAssertFalse(unset.privacyClassBeta, "loading alone never turns the class on")
        XCTAssertFalse(unset.relayBlindEnabled)

        for (name, cli, environment) in [
            ("flag", CLIOverrides(configPath: empty.path, privacyClassBeta: false), [String: String]()),
            ("env", CLIOverrides(configPath: empty.path), ["MACPROVIDER_PRIVACY_CLASS_BETA": "false"]),
            ("relay-blind flag", CLIOverrides(configPath: empty.path, relayBlindEnabled: false), [String: String]()),
            ("relay-blind env", CLIOverrides(configPath: empty.path), ["MACPROVIDER_RELAY_BLIND_ENABLED": "false"]),
        ] {
            let loaded = try ConfigLoader.load(cli: cli, environment: environment)
            XCTAssertEqual(PrivacyAutoEnrollment.mode(loaded), .off, name)
        }
        let yamlOff = try autoTempConfig("privacy_class_beta: false\n")
        defer { try? FileManager.default.removeItem(at: yamlOff) }
        XCTAssertEqual(PrivacyAutoEnrollment.mode(try ConfigLoader.load(cli: CLIOverrides(configPath: yamlOff.path), environment: [:])), .off)

        let forced = try ConfigLoader.load(cli: CLIOverrides(configPath: empty.path, privacyClassBeta: true), environment: [:])
        XCTAssertEqual(PrivacyAutoEnrollment.mode(forced), .forced)
        XCTAssertTrue(forced.relayBlindEnabled, "forcing the class turns relay-blind on unless it is explicitly off")
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(configPath: empty.path, relayBlindEnabled: false, privacyClassBeta: true),
            environment: [:]
        ))
    }

    func testEligibleHostEntersPrivacyModeBeforeCredentials() throws {
        let yaml = try autoTempConfig("provider_token: AUTO-TOKEN-CANARY\n")
        defer { try? FileManager.default.removeItem(at: yaml) }
        var events: [String] = []
        let resolved = try ServeCommand.resolveServeConfig(
            load: { resolveCredentials in
                events.append("load:\(resolveCredentials)")
                return try ConfigLoader.load(cli: CLIOverrides(configPath: yaml.path), environment: [:], resolveCredentials: resolveCredentials)
            },
            canonicalReexec: { config in
                events.append("reexec")
                XCTAssertNil(config.providerToken)
                XCTAssertTrue(config.privacyClassBeta)
            },
            harden: { _ in XCTFail("forced-mode hardening ran in automatic mode") },
            automatic: PrivacyAutoEnrollmentHooks(
                eligibility: { config in
                    events.append("eligibility")
                    XCTAssertNil(config.providerToken)
                    XCTAssertTrue(config.relayBlindEnabled)
                    XCTAssertEqual(config.relayBlindStateDirectory, ConfigLoader.expandTilde(PrivacyAutoEnrollment.defaultStateDirectory))
                    return []
                },
                harden: { config in
                    events.append("harden")
                    XCTAssertNil(config.providerToken)
                    return []
                },
                log: { line in XCTFail("unexpected log \(line)") }
            )
        )
        XCTAssertEqual(events, ["load:false", "eligibility", "reexec", "harden", "load:true"])
        XCTAssertTrue(resolved.privacyClassBeta)
        XCTAssertTrue(resolved.relayBlindEnabled)
        XCTAssertEqual(resolved.providerToken, "AUTO-TOKEN-CANARY")
        XCTAssertNotNil(resolved.relayBlindStateDirectory)
    }

    func testIneligibleHostServesOrdinarilyWithoutHardening() throws {
        let yaml = try autoTempConfig("provider_token: PLAIN-TOKEN\n")
        defer { try? FileManager.default.removeItem(at: yaml) }
        var events: [String] = []
        var logged: [String] = []
        let resolved = try ServeCommand.resolveServeConfig(
            load: { resolveCredentials in
                events.append("load:\(resolveCredentials)")
                return try ConfigLoader.load(cli: CLIOverrides(configPath: yaml.path), environment: [:], resolveCredentials: resolveCredentials)
            },
            canonicalReexec: { _ in events.append("reexec") },
            harden: { _ in XCTFail("hardening ran on an ineligible host") },
            automatic: PrivacyAutoEnrollmentHooks(
                eligibility: { _ in [PrivacyHardeningCode.sipDisabled, PrivacyHardeningCode.codeSignatureInvalid] },
                harden: { _ in
                    XCTFail("automatic hardening ran on an ineligible host")
                    return []
                },
                log: { logged.append($0) }
            )
        )
        XCTAssertEqual(events, ["load:false", "load:true", "reexec"])
        XCTAssertFalse(resolved.privacyClassBeta)
        XCTAssertFalse(resolved.relayBlindEnabled)
        XCTAssertEqual(logged, ["privacy_class auto_ineligible reasons=sip_disabled,code_signature_invalid\n"])
    }

    func testHardeningFailureInAutomaticModeServesOrdinarily() throws {
        let yaml = try autoTempConfig("provider_token: PLAIN-TOKEN\n")
        defer { try? FileManager.default.removeItem(at: yaml) }
        var logged: [String] = []
        let resolved = try ServeCommand.resolveServeConfig(
            load: { resolveCredentials in
                try ConfigLoader.load(cli: CLIOverrides(configPath: yaml.path), environment: [:], resolveCredentials: resolveCredentials)
            },
            canonicalReexec: { _ in },
            harden: { _ in XCTFail("forced-mode hardening ran in automatic mode") },
            automatic: PrivacyAutoEnrollmentHooks(
                eligibility: { _ in [] },
                harden: { _ in [PrivacyHardeningCode.ptDenyAttach] },
                log: { logged.append($0) }
            )
        )
        XCTAssertFalse(resolved.privacyClassBeta)
        XCTAssertEqual(resolved.providerToken, "PLAIN-TOKEN")
        XCTAssertEqual(logged, ["privacy_class auto_hardening_failed reasons=pt_deny_attach\n"])
    }

    func testOptOutAndMissingHooksNeverRunAutomaticMode() throws {
        let yaml = try autoTempConfig("relay_blind_enabled: false\n")
        defer { try? FileManager.default.removeItem(at: yaml) }
        let hooks = PrivacyAutoEnrollmentHooks(
            eligibility: { _ in
                XCTFail("eligibility ran for an opted-out provider")
                return []
            },
            harden: { _ in [] },
            log: { _ in }
        )
        let optedOut = try ServeCommand.resolveServeConfig(
            load: { try ConfigLoader.load(cli: CLIOverrides(configPath: yaml.path), environment: [:], resolveCredentials: $0) },
            canonicalReexec: { _ in },
            harden: { _ in },
            automatic: hooks
        )
        XCTAssertFalse(optedOut.privacyClassBeta)

        let empty = try autoTempConfig("")
        defer { try? FileManager.default.removeItem(at: empty) }
        let noHooks = try ServeCommand.resolveServeConfig(
            load: { try ConfigLoader.load(cli: CLIOverrides(configPath: empty.path), environment: [:], resolveCredentials: $0) },
            canonicalReexec: { _ in },
            harden: { _ in XCTFail("hardening ran without automatic hooks") }
        )
        XCTAssertFalse(noHooks.privacyClassBeta, "autotune candidates and --no-join stay off")
    }

    func testForcedModeKeepsRefusalAndDefaultsStateDirectory() throws {
        let empty = try autoTempConfig("")
        defer { try? FileManager.default.removeItem(at: empty) }
        struct Refused: Error {}
        XCTAssertThrowsError(try ServeCommand.resolveServeConfig(
            load: { try ConfigLoader.load(cli: CLIOverrides(configPath: empty.path, privacyClassBeta: true), environment: [:], resolveCredentials: $0) },
            canonicalReexec: { _ in },
            harden: { config in
                XCTAssertEqual(config.relayBlindStateDirectory, ConfigLoader.expandTilde(PrivacyAutoEnrollment.defaultStateDirectory))
                throw Refused()
            },
            automatic: PrivacyAutoEnrollmentHooks(
                eligibility: { _ in
                    XCTFail("forced mode ran the automatic eligibility check")
                    return []
                },
                harden: { _ in [] },
                log: { _ in }
            )
        )) { error in
            XCTAssertTrue(error is Refused)
        }
    }

    func testAutomaticEligibilityIsReadOnlyAndNamesEveryFailure() {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-auto-eligibility.yaml")
        config.relayBlindStateDirectory = "/tmp/macprovider-auto-eligibility-state"
        let green = autoSyscalls()
        XCTAssertEqual(PrivacyRuntimeHardening.automaticEligibilityFailures(syscalls: green, config: config), [])

        let failing = autoSyscalls(
            codeSignStatus: { PrivacyPostureFlags.csValid | PrivacyPostureFlags.csDebugged },
            identity: PrivacyCodeIdentity(signatureValid: false, cdhashHex: "", teamID: "", signingIdentifier: "", grantedEntitlements: [PrivacyEntitlement.getTaskAllow]),
            csrCheck: { _ in 0 },
            traced: { true },
            environment: ["DYLD_INSERT_LIBRARIES": "/x.dylib", "MACPROVIDER_PERF_TRACE": "1"]
        )
        let reasons = PrivacyRuntimeHardening.automaticEligibilityFailures(syscalls: failing, config: config)
        for code in [
            PrivacyHardeningCode.missingCSHard, PrivacyHardeningCode.missingCSKill, PrivacyHardeningCode.missingCSRuntime,
            PrivacyHardeningCode.csDebugged, PrivacyHardeningCode.codeSignatureInvalid, PrivacyHardeningCode.cdhashInvalid,
            PrivacyHardeningCode.teamIDMissing, PrivacyHardeningCode.signingIdentifierMissing,
            PrivacyHardeningCode.entitlementGetTaskAllow, PrivacyHardeningCode.sipDisabled, PrivacyHardeningCode.pTraced,
            PrivacyHardeningCode.envDYLD, PrivacyHardeningCode.envPerfTrace,
        ] {
            XCTAssertTrue(reasons.contains(code), "missing \(code) in \(reasons)")
        }

        XCTAssertEqual(
            PrivacyRuntimeHardening.automaticEligibilityFailures(syscalls: autoSyscalls(codeSignStatus: { nil }, csrCheck: { _ in nil }, traced: { nil }), config: config),
            [PrivacyHardeningCode.csopsUnreadable, PrivacyHardeningCode.sipDisabled, PrivacyHardeningCode.pTracedUnreadable]
        )
        var kvDisk = config
        kvDisk.kvDiskCache.enabled = true
        XCTAssertEqual(PrivacyRuntimeHardening.automaticEligibilityFailures(syscalls: green, config: kvDisk), [PrivacyHardeningCode.kvDiskTierEnabled])
        var noState = config
        noState.relayBlindStateDirectory = nil
        XCTAssertEqual(PrivacyRuntimeHardening.automaticEligibilityFailures(syscalls: green, config: noState), [PrivacyHardeningCode.stateDirectoryMissing])
    }

    func testPrepareStateDirectoryCreatesPrivateDirectory() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macprovider-auto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let state = parent.appendingPathComponent("relay-blind", isDirectory: true)
        XCTAssertTrue(PrivacyAutoEnrollment.prepareStateDirectory(state.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777, 0o700)
        XCTAssertFalse(PrivacyAutoEnrollment.prepareStateDirectory("relative/path"))
        XCTAssertFalse(PrivacyAutoEnrollment.prepareStateDirectory(nil))
    }
}

private func autoSyscalls(
    codeSignStatus: @escaping @Sendable () -> UInt32? = { PrivacyPostureFlags.requiredStatus },
    identity: PrivacyCodeIdentity = PrivacyCodeIdentity(
        signatureValid: true,
        cdhashHex: String(repeating: "a", count: 40),
        teamID: "AB12CD34EF",
        signingIdentifier: "live.malibu.provider.cli",
        grantedEntitlements: []
    ),
    csrCheck: @escaping @Sendable (UInt32) -> Int32? = { _ in 1 },
    traced: @escaping @Sendable () -> Bool? = { false },
    environment: [String: String] = [:]
) -> PrivacyPostureSyscalls {
    PrivacyPostureSyscalls(
        disableCoreDumps: {
            XCTFail("eligibility called setrlimit")
            return false
        },
        denyAttach: {
            XCTFail("eligibility called ptrace")
            return false
        },
        processIsTraced: traced,
        codeSignStatus: codeSignStatus,
        readCodeIdentity: { identity },
        csrCheck: csrCheck,
        environment: { environment }
    )
}

private func autoTempConfig(_ text: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("privacy-auto-config-\(UUID().uuidString).yaml")
    try Data(text.utf8).write(to: url)
    return url
}
