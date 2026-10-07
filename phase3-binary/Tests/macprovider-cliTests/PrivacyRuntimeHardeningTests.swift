import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class PrivacyRuntimeHardeningTests: XCTestCase {
    func testFakeProbeAllGreenPasses() {
        let result = PrivacyRuntimeHardening.apply(probe: scripted(greenObservation()), config: greenConfig())
        guard case .success(let observation) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(observation.runtimeSource, PrivacyClassConstants.runtimeSource)
        XCTAssertTrue(observation.failureReasons.isEmpty)
        XCTAssertEqual(
            PrivacyRuntimeHardening.fatalLine(reasons: ["sip_disabled"]),
            "FATAL privacy_class_hardening_failed reasons=sip_disabled\n"
        )
    }

    func testEachRequiredFlagFalseFailsWithReason() {
        let cases: [(String, (inout PrivacyPostureObservation) -> Void, String)] = [
            ("hardenedRuntime", { $0.hardenedRuntime = false }, PrivacyHardeningCode.missingCSRuntime),
            ("libraryValidation", { $0.libraryValidation = false }, PrivacyHardeningCode.libraryValidation),
            ("getTaskAllow", { $0.getTaskAllow = true }, PrivacyHardeningCode.getTaskAllow),
            ("csDebugged", { $0.csDebugged = true }, PrivacyHardeningCode.csDebugged),
            ("pTraced", { $0.pTraced = true }, PrivacyHardeningCode.pTraced),
            ("ptDenyAttachApplied", { $0.ptDenyAttachApplied = false }, PrivacyHardeningCode.ptDenyAttach),
            ("coreDumpsDisabled", { $0.coreDumpsDisabled = false }, PrivacyHardeningCode.coreDumps),
            ("sipEnabled", { $0.sipEnabled = false }, PrivacyHardeningCode.sipDisabled),
            ("diagnosticEnvClear", { $0.diagnosticEnvClear = false }, PrivacyHardeningCode.diagnosticEnv),
            ("kvDiskTierDisabled", { $0.kvDiskTierDisabled = false }, PrivacyHardeningCode.kvDiskTierEnabled),
        ]
        for (name, mutate, code) in cases {
            var observation = greenObservation()
            mutate(&observation)
            XCTAssertEqual(
                reasons(probe: scripted(observation), config: greenConfig()),
                [code],
                name
            )
        }
    }

    func testTraceEnvRefused() {
        let named: [(String, String)] = [
            ("DYLD_INSERT_LIBRARIES", PrivacyHardeningCode.envDYLD),
            ("DYLD_LIBRARY_PATH", PrivacyHardeningCode.envDYLD),
            ("DYLD_FRAMEWORK_PATH", PrivacyHardeningCode.envDYLD),
            ("DYLD_FOO", PrivacyHardeningCode.envDYLD),
            ("MACPROVIDER_CB_TRACE", PrivacyHardeningCode.envCBTrace),
            ("MACPROVIDER_PERF_TRACE", PrivacyHardeningCode.envPerfTrace),
            ("MACPROVIDER_KEEPALIVE_DEBUG", PrivacyHardeningCode.envKeepaliveDebug),
            ("MACPROVIDER_ALLOW_TEST_FIXTURES", PrivacyHardeningCode.envAllowTestFixtures),
        ]
        for (name, code) in named {
            let probe = systemProbe(environment: { [name: ""] })
            XCTAssertEqual(
                reasons(probe: probe, config: greenConfig()),
                [PrivacyHardeningCode.diagnosticEnv, code],
                name
            )
        }
        let clean = systemProbe(environment: { ["PATH": "/usr/bin", "DYLDINSERT": "1", "HOME": "/tmp"] })
        guard case .success = PrivacyRuntimeHardening.apply(probe: clean, config: greenConfig()) else {
            return XCTFail("unrelated environment must not fail hardening")
        }
        let combined = systemProbe(environment: {
            [
                "DYLD_INSERT_LIBRARIES": "/tmp/x",
                "MACPROVIDER_CB_TRACE": "1",
                "MACPROVIDER_PERF_TRACE": "1",
                "MACPROVIDER_KEEPALIVE_DEBUG": "1",
                "MACPROVIDER_ALLOW_TEST_FIXTURES": "1",
            ]
        })
        XCTAssertEqual(
            reasons(probe: combined, config: greenConfig()),
            [
                PrivacyHardeningCode.diagnosticEnv,
                PrivacyHardeningCode.envDYLD,
                PrivacyHardeningCode.envCBTrace,
                PrivacyHardeningCode.envPerfTrace,
                PrivacyHardeningCode.envKeepaliveDebug,
                PrivacyHardeningCode.envAllowTestFixtures,
            ]
        )
    }

    func testLoopbackAndDiskTierRefused() {
        var loopback = greenConfig()
        loopback.model = "ollama:llama3"
        XCTAssertEqual(
            reasons(probe: scripted(greenObservation()), config: loopback),
            [PrivacyHardeningCode.runtimeSource, PrivacyHardeningCode.loopbackRuntime]
        )
        var mlxlm = greenConfig()
        mlxlm.model = "mlxlm:demo"
        XCTAssertTrue(reasons(probe: scripted(greenObservation()), config: mlxlm).contains(PrivacyHardeningCode.loopbackRuntime))

        var disk = greenConfig()
        disk.kvDiskCache.enabled = true
        XCTAssertEqual(
            reasons(probe: scripted(greenObservation()), config: disk),
            [PrivacyHardeningCode.kvDiskTierEnabled]
        )

        var relayOff = greenConfig()
        relayOff.relayBlindEnabled = false
        XCTAssertEqual(
            reasons(probe: scripted(greenObservation()), config: relayOff),
            [PrivacyHardeningCode.relayBlindDisabled]
        )

        var missing = greenConfig()
        missing.relayBlindStateDirectory = nil
        XCTAssertEqual(
            reasons(probe: scripted(greenObservation()), config: missing),
            [PrivacyHardeningCode.stateDirectoryMissing]
        )
        missing.relayBlindStateDirectory = "relative/state"
        XCTAssertEqual(
            reasons(probe: scripted(greenObservation()), config: missing),
            [PrivacyHardeningCode.stateDirectoryMissing]
        )

        var padded = greenConfig()
        padded.relayBlindStateDirectory = "  /tmp/privacy-class-state  "
        guard case .success = PrivacyRuntimeHardening.apply(probe: scripted(greenObservation()), config: padded) else {
            return XCTFail("absolute state directory with surrounding whitespace must pass")
        }
    }

    func testUnsignedBuildFailsCodeIdentity() {
        // Injected deny-attach. Do not call PrivacyPostureSyscalls.live or
        // PrivacyPostureLiveSyscalls.ptraceDenyAttach from this test.
        let deny = CallCounter()
        let mask = MaskBox()
        let probe = SystemPrivacyPostureProbe(syscalls: PrivacyPostureSyscalls(
            disableCoreDumps: { true },
            denyAttach: {
                deny.increment()
                return true
            },
            processIsTraced: PrivacyPostureLiveSyscalls.processIsTraced,
            codeSignStatus: PrivacyPostureLiveSyscalls.codeSignStatus,
            readCodeIdentity: PrivacyCodeSignature.readSelf,
            csrCheck: { value in
                mask.record(value)
                return 1
            },
            environment: { [:] }
        ))
        let failed = reasons(probe: probe, config: greenConfig())
        XCTAssertEqual(deny.current, 1)
        XCTAssertEqual(mask.value, PrivacyPostureFlags.csrAllowUnrestrictedFS)
        XCTAssertTrue(
            failed.contains(PrivacyHardeningCode.teamIDMissing) || failed.contains(PrivacyHardeningCode.missingCSRuntime),
            "expected missing team or hardened runtime, got \(failed.joined(separator: ","))"
        )
    }

    func testDefaultsOff() throws {
        XCTAssertFalse(AppConfig.defaults().privacyClassBeta)

        let empty = try tempConfig("")
        defer { try? FileManager.default.removeItem(at: empty) }
        let loaded = try ConfigLoader.load(cli: CLIOverrides(configPath: empty.path), environment: [:])
        XCTAssertFalse(loaded.privacyClassBeta)
        XCTAssertFalse(loaded.relayBlindEnabled)

        let yaml = try tempConfig("""
        relay_blind_enabled: true
        privacy_class_beta: true
        relay_blind_state_directory: /tmp/privacy-class-state

        """)
        defer { try? FileManager.default.removeItem(at: yaml) }
        let fromYAML = try ConfigLoader.load(cli: CLIOverrides(configPath: yaml.path), environment: [:])
        XCTAssertTrue(fromYAML.privacyClassBeta)
        XCTAssertTrue(fromYAML.relayBlindEnabled)

        let envOff = try ConfigLoader.load(
            cli: CLIOverrides(configPath: yaml.path),
            environment: ["MACPROVIDER_PRIVACY_CLASS_BETA": "false"]
        )
        XCTAssertFalse(envOff.privacyClassBeta)

        let cliOn = try ConfigLoader.load(
            cli: CLIOverrides(configPath: yaml.path, relayBlindEnabled: true, privacyClassBeta: true),
            environment: ["MACPROVIDER_PRIVACY_CLASS_BETA": "false"]
        )
        XCTAssertTrue(cliOn.privacyClassBeta)

        // SPEC-049-R024: forcing the class on turns relay-blind on unless it
        // is explicitly off; explicitly off is a configuration error.
        let forcedImplicitRelay = try ConfigLoader.load(
            cli: CLIOverrides(configPath: empty.path, privacyClassBeta: true),
            environment: [:]
        )
        XCTAssertTrue(forcedImplicitRelay.privacyClassBeta)
        XCTAssertTrue(forcedImplicitRelay.relayBlindEnabled)
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(configPath: empty.path, relayBlindEnabled: false, privacyClassBeta: true),
            environment: [:]
        )) { error in
            guard case let ConfigError.invalidValue(key, value, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(key, "privacy_class_beta")
            XCTAssertEqual(value, "true")
        }

        let enabled = try ServeCommand.parse(["--privacy-class-beta"])
        XCTAssertEqual(enabled.privacyClassBeta, true)
        let disabled = try ServeCommand.parse(["--no-privacy-class-beta"])
        XCTAssertEqual(disabled.privacyClassBeta, false)
        let absent = try ServeCommand.parse([])
        XCTAssertNil(absent.privacyClassBeta)
    }

    func testCSRCheckZeroMeansProtectionDisabled() {
        XCTAssertFalse(PrivacySIP.unrestrictedFilesystemProtected(0))
        XCTAssertFalse(PrivacySIP.unrestrictedFilesystemProtected(nil))
        XCTAssertTrue(PrivacySIP.unrestrictedFilesystemProtected(1))
        XCTAssertTrue(PrivacySIP.unrestrictedFilesystemProtected(-1))

        let mask = MaskBox()
        func make(result: Int32?) -> SystemPrivacyPostureProbe {
            systemProbe(csrCheck: { value in
                mask.record(value)
                return result
            })
        }

        let on = PrivacyRuntimeHardening.apply(probe: make(result: 1), config: greenConfig())
        guard case .success(let observation) = on else {
            return XCTFail("non-zero csr_check must be SIP on, got \(on)")
        }
        XCTAssertTrue(observation.sipEnabled)
        XCTAssertEqual(mask.value, PrivacyPostureFlags.csrAllowUnrestrictedFS)
        XCTAssertGreaterThan(mask.calls, 0)

        XCTAssertEqual(
            reasons(probe: make(result: 0), config: greenConfig()),
            [PrivacyHardeningCode.sipDisabled]
        )
        XCTAssertEqual(
            reasons(probe: make(result: nil), config: greenConfig()),
            [PrivacyHardeningCode.sipDisabled]
        )
        let eperm = PrivacyRuntimeHardening.apply(probe: make(result: -1), config: greenConfig())
        guard case .success(let enforced) = eperm else {
            return XCTFail("non-zero csr_check must be SIP on, got \(eperm)")
        }
        XCTAssertTrue(enforced.sipEnabled)
    }

    func testRecheckBeforeDecryptDoesNotCallDenyAttach() {
        let deny = CallCounter()
        let clean = systemProbe(
            codeSignStatus: { PrivacyPostureFlags.requiredStatus },
            denyAttach: {
                deny.increment()
                return true
            }
        )
        XCTAssertTrue(PrivacyRuntimeHardening.recheckBeforeDecrypt(probe: clean))
        XCTAssertEqual(deny.current, 0)

        let traced = systemProbe(processIsTraced: { true }, denyAttach: {
            deny.increment()
            return true
        })
        XCTAssertFalse(PrivacyRuntimeHardening.recheckBeforeDecrypt(probe: traced))

        let debugged = systemProbe(
            codeSignStatus: { PrivacyPostureFlags.requiredStatus | PrivacyPostureFlags.csDebugged },
            denyAttach: {
                deny.increment()
                return true
            }
        )
        XCTAssertFalse(PrivacyRuntimeHardening.recheckBeforeDecrypt(probe: debugged))

        let unreadable = systemProbe(processIsTraced: { nil }, denyAttach: {
            deny.increment()
            return true
        })
        XCTAssertFalse(PrivacyRuntimeHardening.recheckBeforeDecrypt(probe: unreadable))
        XCTAssertEqual(deny.current, 0)

        _ = PrivacyRuntimeHardening.apply(probe: clean, config: greenConfig())
        XCTAssertEqual(deny.current, 1)
    }

    func testIdentityDocumentIsPublicMaterialOnly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("privacy-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = try PrivacyClassIdentityReport.relayBlindPublic(stateDirectory: root, models: ["demo-model"])
        let publicKey = try RelayBlindBase64URL.decode(relay.publicKey, exactCount: 32)
        let fingerprint = try RelayBlindBase64URL.decode(relay.fingerprint, exactCount: 32)
        XCTAssertEqual(publicKey.count, 32)
        XCTAssertEqual(fingerprint.count, 32)

        let secret = try Data(contentsOf: root.appendingPathComponent("identity.ed25519"))
        let agreement = try Data(contentsOf: root.appendingPathComponent("encryption.current.x25519"))
        XCTAssertEqual(secret.count, 32)
        XCTAssertEqual(agreement.count, 32)

        let document = PrivacyClassIdentityReport.document(
            sePublicKey: Data(repeating: 0x11, count: 64).base64EncodedString(),
            seKeyBackend: PrivacyClassConstants.seBackendFile,
            relayBlindIdentityPublicKey: relay.publicKey,
            relayBlindFingerprint: relay.fingerprint,
            codeCDHash: String(repeating: "ab", count: 20),
            teamID: "ABCDE12345",
            binaryVersion: CoordinatorClient.binaryVersion
        )
        XCTAssertEqual(
            Set(document.keys),
            [
                "binary_version",
                "code_cdhash",
                "relay_blind_fingerprint",
                "relay_blind_identity_public_key",
                "se_key_backend",
                "se_public_key",
                "team_id",
            ]
        )
        let encoded = try PrivacyClassIdentityReport.encode(document)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.hasSuffix("\n"))
        XCTAssertFalse(jsonContainsSecret(json, secret))
        XCTAssertFalse(jsonContainsSecret(json, agreement))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(parsed["binary_version"], CoordinatorClient.binaryVersion)
        XCTAssertEqual(parsed["se_key_backend"], "file")
        XCTAssertEqual(parsed["relay_blind_identity_public_key"], relay.publicKey)
    }

    private func reasons(probe: some PrivacyPostureProbe, config: AppConfig) -> [String] {
        switch PrivacyRuntimeHardening.apply(probe: probe, config: config) {
        case .success:
            return []
        case .failure(let codes):
            return codes
        }
    }

    private func scripted(_ observation: PrivacyPostureObservation) -> ScriptedPrivacyPostureProbe {
        ScriptedPrivacyPostureProbe(observation: observation)
    }

    // SPEC-049-R007: in privacy mode the token is not resolved before the
    // canonical re-exec decision and hardening.
    func testPrivacyModeHardensBeforeResolvingProviderToken() throws {
        let token = "PRIVACY-TOKEN-CANARY"
        let yaml = try tempConfig("""
        relay_blind_enabled: true
        privacy_class_beta: true
        relay_blind_state_directory: /tmp/privacy-class-state
        provider_token: \(token)

        """)
        defer { try? FileManager.default.removeItem(at: yaml) }
        let tokenFile = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("privacy-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tokenFile) }

        for (name, cli, environment, want) in [
            ("yaml", CLIOverrides(configPath: yaml.path), [String: String](), token),
            ("env", CLIOverrides(configPath: yaml.path), ["MACPROVIDER_PROVIDER_TOKEN": "ENV-TOKEN-CANARY"], "ENV-TOKEN-CANARY"),
            ("token file", CLIOverrides(configPath: yaml.path, providerTokenFile: tokenFile.path), [String: String](), "FILE-TOKEN-CANARY"),
        ] {
            try? FileManager.default.removeItem(at: tokenFile)
            var events: [String] = []
            let resolved = try ServeCommand.resolveServeConfig(
                load: { resolveCredentials in
                    events.append("load:\(resolveCredentials)")
                    return try ConfigLoader.load(cli: cli, environment: environment, resolveCredentials: resolveCredentials)
                },
                canonicalReexec: { config in
                    events.append("reexec")
                    XCTAssertNil(config.providerToken, name)
                },
                harden: { config in
                    events.append("harden")
                    XCTAssertTrue(config.privacyClassBeta, name)
                    XCTAssertNil(config.providerToken, name)
                    // The token file does not exist until hardening has run,
                    // so any earlier read would have thrown.
                    try Data("FILE-TOKEN-CANARY\n".utf8).write(to: tokenFile)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
                }
            )
            XCTAssertEqual(events, ["load:false", "reexec", "harden", "load:true"], name)
            XCTAssertEqual(resolved.providerToken, want, name)
            XCTAssertTrue(resolved.privacyClassBeta, name)
        }
    }

    func testHardeningFailureStopsBeforeProviderTokenLoad() throws {
        let yaml = try tempConfig("""
        relay_blind_enabled: true
        relay_blind_state_directory: /tmp/privacy-class-state
        provider_token: PRIVACY-TOKEN-CANARY

        """)
        defer { try? FileManager.default.removeItem(at: yaml) }
        struct Refused: Error {}
        var credentialLoads = 0
        XCTAssertThrowsError(try ServeCommand.resolveServeConfig(
            load: { resolveCredentials in
                if resolveCredentials { credentialLoads += 1 }
                return try ConfigLoader.load(
                    cli: CLIOverrides(configPath: yaml.path),
                    environment: ["MACPROVIDER_PRIVACY_CLASS_BETA": "true"],
                    resolveCredentials: resolveCredentials
                )
            },
            canonicalReexec: { _ in },
            harden: { _ in throw Refused() }
        )) { error in
            XCTAssertTrue(error is Refused)
        }
        XCTAssertEqual(credentialLoads, 0)
    }

    func testForcedLabScopeRejectionStopsBeforeProviderTokenLoad() throws {
        let stateRoot = try makeOwnerOnlyLabStateRoot()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let yaml = try tempConfig("""
        relay_blind_enabled: true
        privacy_class_beta: true
        credential_store: protected_file
        coordinator_url: wss://coordinator.malibu.tech/v2/provider
        relay_blind_state_directory: \(stateRoot.path)
        provider_token: PRIVACY-TOKEN-CANARY

        """)
        defer { try? FileManager.default.removeItem(at: yaml) }

        var credentialLoads = 0
        XCTAssertThrowsError(try ServeCommand.resolveServeConfig(
            load: { resolveCredentials in
                if resolveCredentials { credentialLoads += 1 }
                return try ConfigLoader.load(
                    cli: CLIOverrides(configPath: yaml.path),
                    environment: [:],
                    resolveCredentials: resolveCredentials
                )
            },
            canonicalReexec: { _ in },
            harden: { config in
                _ = try ServeCommand.validatePrivacyLabIdentityScopeIfRequested(
                    config: config,
                    isolateLifecycle: true,
                    requested: true
                )
            }
        )) { error in
            XCTAssertEqual(error as? PrivacyLabIdentityScopeError, .loopbackLiteralRequired)
        }
        XCTAssertEqual(credentialLoads, 0)
    }

    func testNonLabIsolatedPrivacyKeepsPreviousCredentialOrdering() throws {
        let yaml = try tempConfig("""
        relay_blind_enabled: true
        privacy_class_beta: true
        credential_store: protected_file
        coordinator_url: wss://coordinator.malibu.tech/v2/provider
        relay_blind_state_directory: /tmp/privacy-class-state
        provider_token: PRIVACY-TOKEN-CANARY

        """)
        defer { try? FileManager.default.removeItem(at: yaml) }

        var events: [String] = []
        let resolved = try ServeCommand.resolveServeConfig(
            load: { resolveCredentials in
                events.append("load:\(resolveCredentials)")
                return try ConfigLoader.load(
                    cli: CLIOverrides(configPath: yaml.path),
                    environment: [:],
                    resolveCredentials: resolveCredentials
                )
            },
            canonicalReexec: { _ in events.append("reexec") },
            harden: { config in
                events.append("harden")
                XCTAssertNil(try ServeCommand.validatePrivacyLabIdentityScopeIfRequested(
                    config: config,
                    isolateLifecycle: true,
                    requested: false
                ))
            }
        )

        XCTAssertEqual(events, ["load:false", "reexec", "harden", "load:true"])
        XCTAssertEqual(resolved.providerToken, "PRIVACY-TOKEN-CANARY")
        XCTAssertTrue(resolved.privacyClassBeta)
    }

    func testNonPrivacyServeConfigOrderAndResultUnchanged() throws {
        let yaml = try tempConfig("""
        relay_blind_enabled: true
        privacy_class_beta: true
        relay_blind_state_directory: /tmp/privacy-class-state
        provider_token: PLAIN-TOKEN

        """)
        defer { try? FileManager.default.removeItem(at: yaml) }
        for (name, cli, environment) in [
            ("flag off overrides env and yaml", CLIOverrides(configPath: yaml.path, privacyClassBeta: false), ["MACPROVIDER_PRIVACY_CLASS_BETA": "true"]),
            ("env off overrides yaml", CLIOverrides(configPath: yaml.path), ["MACPROVIDER_PRIVACY_CLASS_BETA": "false"]),
        ] {
            var events: [String] = []
            let resolved = try ServeCommand.resolveServeConfig(
                load: { resolveCredentials in
                    events.append("load:\(resolveCredentials)")
                    return try ConfigLoader.load(cli: cli, environment: environment, resolveCredentials: resolveCredentials)
                },
                canonicalReexec: { config in
                    events.append("reexec")
                    XCTAssertEqual(config.providerToken, "PLAIN-TOKEN", name)
                },
                harden: { _ in events.append("harden") }
            )
            XCTAssertEqual(events, ["load:false", "load:true", "reexec"], name)
            XCTAssertEqual(resolved, try ConfigLoader.load(cli: cli, environment: environment), name)
            XCTAssertFalse(resolved.privacyClassBeta, name)
        }
    }
}

private struct ScriptedPrivacyPostureProbe: PrivacyPostureProbe {
    var observation: PrivacyPostureObservation
    func observe() -> PrivacyPostureObservation { observation }
    func isTracedOrDebugged() -> Bool { observation.pTraced || observation.csDebugged }
}

private func greenObservation() -> PrivacyPostureObservation {
    PrivacyPostureObservation(
        hardenedRuntime: true,
        libraryValidation: true,
        getTaskAllow: false,
        csDebugged: false,
        pTraced: false,
        ptDenyAttachApplied: true,
        coreDumpsDisabled: true,
        sipEnabled: true,
        diagnosticEnvClear: true,
        kvDiskTierDisabled: true,
        runtimeSource: PrivacyClassConstants.runtimeSource,
        codeCDHash: String(repeating: "ab", count: 20),
        teamID: "ABCDE12345",
        signingIdentifier: "live.malibu.provider.cli",
        binaryVersion: CoordinatorClient.binaryVersion,
        failureReasons: []
    )
}

private func greenIdentity() -> PrivacyCodeIdentity {
    PrivacyCodeIdentity(
        signatureValid: true,
        cdhashHex: String(repeating: "ab", count: 20),
        teamID: "ABCDE12345",
        signingIdentifier: "live.malibu.provider.cli",
        grantedEntitlements: []
    )
}

private func greenConfig() -> AppConfig {
    var config = AppConfig.defaults(configPath: "/tmp/privacy-class-test.yaml")
    config.privacyClassBeta = true
    config.relayBlindEnabled = true
    config.relayBlindStateDirectory = "/tmp/privacy-class-state"
    config.model = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    config.kvDiskCache.enabled = false
    return config
}

private func systemProbe(
    environment: @escaping @Sendable () -> [String: String] = { [:] },
    csrCheck: @escaping @Sendable (UInt32) -> Int32? = { _ in 1 },
    readCodeIdentity: @escaping @Sendable () -> PrivacyCodeIdentity = { greenIdentity() },
    processIsTraced: @escaping @Sendable () -> Bool? = { false },
    codeSignStatus: @escaping @Sendable () -> UInt32? = { PrivacyPostureFlags.requiredStatus },
    denyAttach: @escaping @Sendable () -> Bool = { true },
    disableCoreDumps: @escaping @Sendable () -> Bool = { true }
) -> SystemPrivacyPostureProbe {
    SystemPrivacyPostureProbe(syscalls: PrivacyPostureSyscalls(
        disableCoreDumps: disableCoreDumps,
        denyAttach: denyAttach,
        processIsTraced: processIsTraced,
        codeSignStatus: codeSignStatus,
        readCodeIdentity: readCodeIdentity,
        csrCheck: csrCheck,
        environment: environment
    ))
}

private func tempConfig(_ text: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("privacy-class-config-\(UUID().uuidString).yaml")
    try Data(text.utf8).write(to: url)
    return url
}

private func makeOwnerOnlyLabStateRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("privacy-lab-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

private func jsonContainsSecret(_ json: String, _ secret: Data) -> Bool {
    json.contains(RelayBlindBase64URL.encode(secret)) || json.contains(secret.base64EncodedString())
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class MaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt32 = 0
    private var callCount = 0
    func record(_ mask: UInt32) {
        lock.lock()
        stored = mask
        callCount += 1
        lock.unlock()
    }
    var value: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}
