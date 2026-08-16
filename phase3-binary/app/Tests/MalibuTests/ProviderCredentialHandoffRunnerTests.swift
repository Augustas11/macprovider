import Security
import XCTest
@testable import Malibu

final class ProviderCredentialHandoffRunnerTests: XCTestCase {
    func testSigningInformationRequestsExtendedSigningMetadata() throws {
        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecStaticCodeCreateWithPath(
                URL(fileURLWithPath: "/usr/bin/true") as CFURL,
                [],
                &staticCode
            ),
            errSecSuccess
        )
        let code = try XCTUnwrap(staticCode)
        var observedFlags: SecCSFlags?
        let expected = [
            kSecCodeInfoTeamIdentifier as String: "YF7XNRJUG4",
            kSecCodeInfoUnique as String: Data([0x01, 0x02]),
        ] as CFDictionary

        let result = try ProviderCredentialHandoffRunner.signingInformation(
            for: code,
            copy: { _, flags, information in
                observedFlags = flags
                information.pointee = expected
                return errSecSuccess
            }
        )

        XCTAssertEqual(
            observedFlags?.rawValue,
            SecCSFlags(rawValue: kSecCSSigningInformation).rawValue
        )
        XCTAssertEqual(result[kSecCodeInfoTeamIdentifier as String] as? String, "YF7XNRJUG4")
        XCTAssertEqual(result[kSecCodeInfoUnique as String] as? Data, Data([0x01, 0x02]))
    }

    func testSigningInformationFailsClosedWhenSecurityReadFails() throws {
        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecStaticCodeCreateWithPath(
                URL(fileURLWithPath: "/usr/bin/true") as CFURL,
                [],
                &staticCode
            ),
            errSecSuccess
        )

        XCTAssertThrowsError(
            try ProviderCredentialHandoffRunner.signingInformation(
                for: try XCTUnwrap(staticCode),
                copy: { _, _, _ in errSecCSUnsigned }
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialHandoffRunner.Error,
                .invalidCLI("code signing metadata is unavailable")
            )
        }
    }

    func testHandoffImportsThenVerifiesWithFreshInvocation() async throws {
        let recorder = HandoffInvocationRecorder(exitCodes: [0, 0])
        let executable = URL(fileURLWithPath: "/tmp/macprovider-cli")
        let config = URL(fileURLWithPath: "/tmp/config with spaces.yaml")

        try await ProviderCredentialHandoffRunner.migrate(
            configURL: config,
            executableURL: executable,
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].executable, executable)
        XCTAssertEqual(invocations[0].arguments, ["credentials", "import", "--config", config.path])
        XCTAssertEqual(invocations[1].arguments, ["credentials", "verify", "--config", config.path])
    }

    func testHandoffDoesNotVerifyAfterImportFailure() async throws {
        let recorder = HandoffInvocationRecorder(exitCodes: [17])

        do {
            try await ProviderCredentialHandoffRunner.migrate(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                run: { executable, arguments in
                    await recorder.run(executable: executable, arguments: arguments)
                }
            )
            XCTFail("expected import failure")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .importFailed(17))
        }

        let invocationCount = await recorder.invocations.count
        XCTAssertEqual(invocationCount, 1)
    }

    func testHandoffReportsFreshProcessVerificationFailure() async throws {
        let recorder = HandoffInvocationRecorder(exitCodes: [0, 23])

        do {
            try await ProviderCredentialHandoffRunner.migrate(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                run: { executable, arguments in
                    await recorder.run(executable: executable, arguments: arguments)
                }
            )
            XCTFail("expected verification failure")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .freshProcessVerificationFailed(23))
        }

        let invocationCount = await recorder.invocations.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testResolveInstalledExecutableUsesManifestCustomPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-handoff-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("custom/bin/macprovider-cli")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("test".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manifest = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [
            "install_prefix": executable.deletingLastPathComponent().path,
            "binary_path": executable.path,
        ])
            .write(to: manifest)

        XCTAssertEqual(
            try ProviderCredentialHandoffRunner.resolveInstalledExecutable(home: home),
            executable.standardizedFileURL
        )
    }

    func testResolveInstalledExecutableRejectsRelativeManifestPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-handoff-relative-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let manifest = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["binary_path": "relative/macprovider-cli"])
            .write(to: manifest)

        XCTAssertThrowsError(
            try ProviderCredentialHandoffRunner.resolveInstalledExecutable(home: home)
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialHandoffRunner.Error,
                .invalidCLI("install manifest binary_path is not absolute")
            )
        }
    }

    func testProcessRunnerTimesOutAndTerminatesChild() async throws {
        do {
            _ = try await ProviderCredentialHandoffRunner.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05
            )
            XCTFail("expected timeout")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testCapturedProcessReturnsBoundedStandardOutput() async throws {
        let result = try await ProviderCredentialHandoffRunner.runCapturedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "{\"contract_version\":1}"],
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "{\"contract_version\":1}")
    }

    func testCapturedProcessRejectsOutputBeyondLimit() async throws {
        do {
            _ = try await ProviderCredentialHandoffRunner.runCapturedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s", String(repeating: "x", count: 128)],
                timeout: 2,
                outputLimit: 32
            )
            XCTFail("expected bounded-output rejection")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .invalidOutput("output exceeds configured limit"))
        }
    }

    func testCapturedProcessCancellationTerminatesAndAwaitsChild() async throws {
        let started = Date()
        let task = Task {
            try await ProviderCredentialHandoffRunner.runCapturedProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 10
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testCapturedProcessIdentityFailureTerminatesAndAwaitsChild() async throws {
        let started = Date()
        do {
            _ = try await ProviderCredentialHandoffRunner.runCapturedProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 10,
                validateProcess: { _ in
                    throw ProviderCredentialHandoffRunner.Error.invalidCLI("live child mismatch")
                }
            )
            XCTFail("expected live-child identity rejection")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .invalidCLI("live child mismatch"))
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testCredentialStatusUsesVersionedRedactedJSONContract() async throws {
        let recorder = CapturedInvocationRecorder(results: [
            .init(exitCode: 0, standardOutput: Self.credentialJSON(operation: "status"))
        ])
        let executable = URL(fileURLWithPath: "/tmp/macprovider-cli")
        let config = URL(fileURLWithPath: "/tmp/config with spaces.yaml")

        let status = try await ProviderCredentialHandoffRunner.credentialStatus(
            configURL: config,
            executableURL: executable,
            expectedProviderID: "provider-a",
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        XCTAssertEqual(status.contractVersion, 1)
        XCTAssertEqual(status.condition, "missing")
        XCTAssertEqual(status.action, "repair_from_protected_source")
        XCTAssertFalse(String(decoding: Self.credentialJSON(operation: "status"), as: UTF8.self).contains("secret"))
        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.map(\.arguments), [
            [
                "credentials", "status", "--config", config.path,
                "--expected-provider-id", "provider-a",
            ]
        ])
    }

    func testCredentialRepairRemainsCLITransaction() async throws {
        let recorder = CapturedInvocationRecorder(results: [
            .init(exitCode: 0, standardOutput: Self.credentialJSON(operation: "repair", condition: "ready", action: "none"))
        ])
        let config = URL(fileURLWithPath: "/tmp/config.yaml")

        let status = try await ProviderCredentialHandoffRunner.repairCredential(
            configURL: config,
            executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            expectedProviderID: "provider-a",
            proveRestart: true,
            previousServiceInstanceID: "instance-old",
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        XCTAssertEqual(status.condition, "ready")
        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.map(\.arguments), [
            [
                "credentials", "repair", "--config", config.path,
                "--expected-provider-id", "provider-a",
                "--prove-restart",
                "--previous-service-instance", "instance-old",
            ]
        ])
    }

    func testCredentialResultMustMatchExpectedProviderIdentity() async throws {
        let result = ProviderCredentialHandoffRunner.CapturedCommandResult(
            exitCode: 0,
            standardOutput: Self.credentialJSON(operation: "status", providerID: "provider-b")
        )

        do {
            _ = try await ProviderCredentialHandoffRunner.credentialStatus(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                expectedProviderID: "provider-a",
                run: { _, _ in result }
            )
            XCTFail("expected identity mismatch")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .invalidOutput("provider identity mismatch"))
        }
    }

    func testCredentialRepairRefusalDoesNotTrustDiagnosticPayload() async throws {
        let recorder = CapturedInvocationRecorder(results: [
            .init(exitCode: 4, standardOutput: Self.credentialJSON(operation: "repair_refused"))
        ])

        do {
            _ = try await ProviderCredentialHandoffRunner.repairCredential(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                run: { executable, arguments in
                    await recorder.run(executable: executable, arguments: arguments)
                }
            )
            XCTFail("expected refusal")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .repairFailed(4))
        }
    }

    func testAdmissionIdentityRecoveryStagesThroughInstalledCLIContract() async throws {
        let candidate = String(repeating: "a", count: 64)
        let recorder = CapturedInvocationRecorder(results: [
            .init(
                exitCode: 0,
                standardOutput: Self.admissionRecoveryStageJSON(candidate: candidate)
            )
        ])
        let config = URL(fileURLWithPath: "/tmp/config with spaces.yaml")
        let executable = URL(fileURLWithPath: "/tmp/macprovider-cli")

        let result = try await ProviderCredentialHandoffRunner.stageAdmissionIdentityRecovery(
            configURL: config,
            executableURL: executable,
            expectedProviderID: "provider-a",
            incidentID: "incident-585",
            reason: "Malibu network verification repair",
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        XCTAssertEqual(result.candidatePublicKeySHA256, candidate)
        XCTAssertEqual(
            result.approvalInstruction,
            "POST /admin/provider-admission-identity/recover for incident incident-585, then have a distinct second operator approve /admin/provider-admission-identity/recover/{pending_id}/approve."
        )
        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.map(\.arguments), [[
            "credentials", "recover-admission-identity",
            "--config", config.path,
            "--expected-provider-id", "provider-a",
            "--incident-id", "incident-585",
            "--reason", "Malibu network verification repair",
            "--approval-ttl-minutes", "60",
        ]])
    }

    func testAdmissionIdentityRecoveryActivationRestartsAndProvesThroughCLI() async throws {
        let committed = String(repeating: "b", count: 64)
        let recorder = CapturedInvocationRecorder(results: [
            .init(
                exitCode: 0,
                standardOutput: try JSONSerialization.data(withJSONObject: [
                    "contract_version": 1,
                    "operation": "recover_admission_identity",
                    "provider_id": "provider-a",
                    "owner": "macprovider_cli",
                    "state": "committed",
                    "public_key_sha256": committed,
                    "restart_safe": true,
                ])
            )
        ])
        let config = URL(fileURLWithPath: "/tmp/config.yaml")

        let result = try await ProviderCredentialHandoffRunner.activateAdmissionIdentityRecovery(
            configURL: config,
            executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            expectedProviderID: "provider-a",
            previousServiceInstanceID: "instance-old",
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        XCTAssertEqual(result.publicKeySHA256, committed)
        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.map(\.arguments), [[
            "credentials", "recover-admission-identity",
            "--config", config.path,
            "--expected-provider-id", "provider-a",
            "--activate",
            "--previous-service-instance", "instance-old",
        ]])
    }

    func testAdmissionIdentityRecoveryStatusRestoresExactOperatorRequestAfterAppRestart() async throws {
        let candidate = String(repeating: "c", count: 64)
        let recorder = CapturedInvocationRecorder(results: [
            .init(
                exitCode: 0,
                standardOutput: Self.admissionRecoveryStatusJSON(candidate: candidate)
            )
        ])
        let config = URL(fileURLWithPath: "/tmp/config with spaces.yaml")

        let result = try await ProviderCredentialHandoffRunner.admissionIdentityRecoveryStatus(
            configURL: config,
            executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            expectedProviderID: "provider-a",
            run: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )

        XCTAssertEqual(result.state, "approval_required")
        XCTAssertEqual(result.candidatePublicKeySHA256, candidate)
        let request = try XCTUnwrap(result.operatorRequest)
        XCTAssertTrue(request.contains("\"candidate_public_key_sha256\" : \"\(candidate)\""), request)
        XCTAssertTrue(request.contains("\"requested_until\" : \"2026-07-14T13:00:00Z\""), request)
        XCTAssertTrue(request.contains("\"reason\" : \"Malibu admission identity recovery\""), request)
        XCTAssertTrue(request.contains("\"incident_id\" : \"incident-585\""), request)
        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.map(\.arguments), [[
            "credentials", "admission-identity-recovery-status",
            "--config", config.path,
            "--expected-provider-id", "provider-a",
        ]])
    }

    func testCredentialStatusRejectsFutureContractVersion() async throws {
        let data = Self.credentialJSON(operation: "status", contractVersion: 2)
        do {
            _ = try await ProviderCredentialHandoffRunner.credentialStatus(
                configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
                executableURL: URL(fileURLWithPath: "/tmp/macprovider-cli"),
                run: { _, _ in .init(exitCode: 0, standardOutput: data) }
            )
            XCTFail("expected incompatible contract")
        } catch let error as ProviderCredentialHandoffRunner.Error {
            XCTAssertEqual(error, .invalidOutput("unsupported contract version 2"))
        }
    }

    private static func credentialJSON(
        operation: String,
        providerID: String = "provider-a",
        condition: String = "missing",
        action: String = "repair_from_protected_source",
        contractVersion: Int = 1
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "contract_version": contractVersion,
            "credential_store": "live.malibu.provider.provider-token.v1",
            "operation": operation,
            "provider_id": providerID,
            "source": "config_fallback",
            "condition": condition,
            "restart_safe": condition == "ready",
            "migration_pending": true,
            "recoverable": action != "none",
            "action": action,
        ])
    }

    private static func admissionRecoveryStageJSON(candidate: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "contract_version": 1,
            "operation": "recover_admission_identity",
            "provider_id": "provider-a",
            "owner": "macprovider_cli",
            "state": "approval_required",
            "candidate_public_key_sha256": candidate,
            "restart_safe": true,
            "admin_request": [
                "method": "POST",
                "path": "/admin/provider-admission-identity/recover",
                "body": [
                    "provider_id": "provider-a",
                    "candidate_public_key_sha256": candidate,
                    "requested_until": "2026-07-14T13:00:00Z",
                    "reason": "Malibu admission identity recovery",
                    "incident_id": "incident-585",
                ],
                "approval_path_template": "/admin/provider-admission-identity/recover/{pending_id}/approve",
            ],
            "next_action": "submit the admin request and obtain approval",
        ])
    }

    private static func admissionRecoveryStatusJSON(candidate: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "contract_version": 1,
            "operation": "admission_identity_recovery_status",
            "provider_id": "provider-a",
            "owner": "macprovider_cli",
            "state": "approval_required",
            "candidate_public_key_sha256": candidate,
            "restart_safe": true,
            "admin_request": [
                "method": "POST",
                "path": "/admin/provider-admission-identity/recover",
                "body": [
                    "provider_id": "provider-a",
                    "candidate_public_key_sha256": candidate,
                    "requested_until": "2026-07-14T13:00:00Z",
                    "reason": "Malibu admission identity recovery",
                    "incident_id": "incident-585",
                ],
                "approval_path_template": "/admin/provider-admission-identity/recover/{pending_id}/approve",
            ],
        ])
    }
}

private actor HandoffInvocationRecorder {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var exitCodes: [Int32]

    init(exitCodes: [Int32]) {
        self.exitCodes = exitCodes
    }

    func run(executable: URL, arguments: [String]) -> Int32 {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        return exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
    }
}

private actor CapturedInvocationRecorder {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var results: [ProviderCredentialHandoffRunner.CapturedCommandResult]

    init(results: [ProviderCredentialHandoffRunner.CapturedCommandResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String]) -> ProviderCredentialHandoffRunner.CapturedCommandResult {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        return results.removeFirst()
    }
}
