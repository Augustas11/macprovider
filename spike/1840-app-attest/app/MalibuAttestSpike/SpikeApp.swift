import AppKit
import CryptoKit
import DeviceCheck
import Foundation
import Security

@main
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    static let shared = SpikeDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let code = await SpikeRun().execute()
            exit(code)
        }
    }
}

struct SpikeOptions {
    var resultPath: String
    var childPath: String?
    var childRequirement: String?

    static func parse() -> SpikeOptions {
        let env = ProcessInfo.processInfo.environment
        var child = nonEmpty(env["SPIKE_CHILD_PATH"])
        var requirement = nonEmpty(env["SPIKE_CHILD_REQUIREMENT"])
        var positional: [String] = []
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--child", index + 1 < arguments.count {
                child = arguments[index + 1]
                index += 2
                continue
            }
            if argument == "--child-requirement", index + 1 < arguments.count {
                requirement = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") {
                FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
                index += 1
                continue
            }
            positional.append(argument)
            index += 1
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MalibuAttestSpike/result.json")
            .path
        let result: String
        if let envPath = nonEmpty(env["SPIKE_RESULT_PATH"]) {
            result = SpikeSupport.expandPath(envPath)
        } else if let first = positional.first {
            result = SpikeSupport.expandPath(first)
        } else {
            result = fallback
        }
        return SpikeOptions(
            resultPath: result,
            childPath: child.map(SpikeSupport.expandPath),
            childRequirement: requirement
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct SpikeRun {
    func execute() async -> Int32 {
        let options = SpikeOptions.parse()
        let identity = selfIdentity()
        let attestation = await attest(teamID: identity.teamID)
        var object: [String: Any] = [
            "os_version": osVersion(),
            "os_version_string": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle_identifier": Bundle.main.bundleIdentifier ?? "",
            "bundle_version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            "is_supported": attestation.isSupported,
            "secure_enclave_available": SecureEnclave.isAvailable,
            "identity": identity.object,
            "key_id": attestation.keyID,
            "nonce_b64": attestation.nonceB64,
            "attestation_b64": attestation.attestationB64,
            "client_data": attestation.clientData,
            "assertion_b64": attestation.assertionB64,
            "assertions": attestation.assertions,
            "attest_stage": attestation.stage,
            "attest_error": attestation.error ?? NSNull(),
        ]
        if let childPath = options.childPath {
            object["child"] = childProbe(
                path: childPath,
                teamID: identity.teamID,
                requirementOverride: options.childRequirement
            )
        } else {
            object["child"] = NSNull()
        }
        let code = write(object, to: options.resultPath)
        if code == 0 {
            let supported = attestation.isSupported ? "true" : "false"
            let line = "wrote \(options.resultPath) is_supported=\(supported) attest_stage=\(attestation.stage)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        return code
    }

    private func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func selfIdentity() -> (object: [String: Any], teamID: String) {
        let profileURL = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        var isDirectory = ObjCBool(false)
        let profileExists = FileManager.default.fileExists(atPath: profileURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
        var profileBytes: Int64 = 0
        if profileExists, let attributes = try? FileManager.default.attributesOfItem(atPath: profileURL.path) {
            profileBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }

        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        var facts = SpikeSupport.SigningFacts()
        if selfStatus != errSecSuccess {
            facts.status = selfStatus
            facts.errorDescription = "SecCodeCopySelf \(SpikeSupport.osStatusName(selfStatus))"
        } else if let code {
            // Entitlements are only returned with kSecCSRequirementInformation.
            facts = SpikeSupport.readSigningFacts(
                code,
                flags: kSecCSSigningInformation | kSecCSRequirementInformation
            )
        } else {
            facts.status = errSecCSNoSuchCode
            facts.errorDescription = "SecCodeCopySelf returned no code"
        }

        var object: [String: Any] = [
            "team_id": facts.teamID,
            "identifier": facts.identifier,
            "cdhash": facts.cdhash,
            "embedded_provisioning_profile": profileExists,
            "profile_bytes": NSNumber(value: profileBytes),
            "os_status": NSNumber(value: facts.status),
            "entitlements": facts.entitlements,
        ]
        if !facts.errorDescription.isEmpty {
            object["error_description"] = facts.errorDescription
        }
        return (object, facts.teamID)
    }

    private struct AttestationOutcome {
        var isSupported = false
        var stage = "skipped"
        var keyID = ""
        var nonceB64 = ""
        var attestationB64 = ""
        var clientData = ""
        var assertionB64 = ""
        var assertions: [[String: Any]] = []
        var error: [String: Any]?
    }

    private func attest(teamID: String) async -> AttestationOutcome {
        var outcome = AttestationOutcome()
        let service = DCAppAttestService.shared
        outcome.isSupported = service.isSupported
        // macOS 26 and earlier report this as false. Do not call generateKey then.
        guard outcome.isSupported else {
            outcome.stage = "skipped"
            return outcome
        }
        do {
            outcome.stage = "nonce"
            var nonce = Data(count: 32)
            let randomStatus = nonce.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let address = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
            }
            guard randomStatus == errSecSuccess else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(randomStatus),
                    userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes \(SpikeSupport.osStatusName(randomStatus))"]
                )
            }
            outcome.nonceB64 = nonce.base64EncodedString()
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            outcome.stage = "generate_key"
            let keyID = try await service.generateKey()
            outcome.keyID = keyID
            outcome.stage = "attest_key"
            let clientDataHash = Data(SHA256.hash(data: nonce))
            let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
            outcome.attestationB64 = attestation.base64EncodedString()
            for seq in [1, 2] {
                outcome.stage = seq == 1 ? "assertion_1" : "assertion_2"
                let document = try postureDocument(
                    bundleID: bundleID,
                    teamID: teamID,
                    challenge: outcome.nonceB64,
                    seq: seq
                )
                let documentHash = Data(SHA256.hash(data: Data(document.utf8)))
                let assertion = try await service.generateAssertion(keyID, clientDataHash: documentHash)
                let record: [String: Any] = [
                    "client_data": document,
                    "client_data_b64": Data(document.utf8).base64EncodedString(),
                    "assertion_b64": assertion.base64EncodedString(),
                ]
                outcome.assertions.append(record)
                if seq == 1 {
                    outcome.clientData = document
                    outcome.assertionB64 = assertion.base64EncodedString()
                }
            }
            outcome.stage = "complete"
        } catch {
            outcome.error = SpikeSupport.probeError(error)
        }
        return outcome
    }

    /// The challenge member carries the attestation nonce so the verifier can
    /// apply Apple's "embedded challenge matches" assertion step.
    private func postureDocument(bundleID: String, teamID: String, challenge: String, seq: Int) throws -> String {
        let object: [String: Any] = [
            "bundle_id": bundleID,
            "challenge": challenge,
            "purpose": "spike-1840-posture",
            "seq": seq,
            "team_id": teamID,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "spike.attestation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "posture document is not UTF-8"]
            )
        }
        return text
    }

    private func childProbe(path: String, teamID: String, requirementOverride: String?) -> [String: Any] {
        let requirement: String
        if let requirementOverride, !requirementOverride.isEmpty {
            requirement = requirementOverride
        } else if let built = SpikeSupport.defaultChildRequirement(teamID: teamID) {
            requirement = built
        } else {
            let shown = String(teamID.prefix(64))
            return childObject(
                path: path,
                requirement: "",
                pid: 0,
                pass: false,
                status: 0,
                cdhash: "",
                teamID: "",
                identifier: "",
                flags: 0,
                flagsPresent: false,
                audit: auditUnavailable("team identifier \(shown) is empty or not alphanumeric; child check was not run"),
                error: "team identifier is empty or not alphanumeric; child check was not run"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--spike-sleep", "5"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var started = false
        defer {
            if started {
                if process.isRunning {
                    process.terminate()
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
        }
        do {
            try process.run()
            started = true
        } catch {
            let ns = error as NSError
            return childObject(
                path: path,
                requirement: requirement,
                pid: 0,
                pass: false,
                status: OSStatus(ns.code),
                cdhash: "",
                teamID: "",
                identifier: "",
                flags: 0,
                flagsPresent: false,
                audit: auditUnavailable(ns.localizedDescription),
                error: "launch failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)"
            )
        }

        let pid = process.processIdentifier
        let guest = SpikeSupport.guest(pid: pid, auditToken: nil)
        guard let code = guest.code else {
            return childObject(
                path: path,
                requirement: requirement,
                pid: pid,
                pass: false,
                status: guest.status,
                cdhash: "",
                teamID: "",
                identifier: "",
                flags: 0,
                flagsPresent: false,
                audit: auditUnavailable("pid guest was not created"),
                error: "SecCodeCopyGuestWithAttributes \(SpikeSupport.osStatusName(guest.status))"
            )
        }

        let validity = SpikeSupport.checkValidity(code, requirement: requirement)
        let signing = SpikeSupport.readSigningFacts(code, flags: kSecCSSigningInformation)
        let dynamic = SpikeSupport.readSigningFacts(code, flags: kSecCSDynamicInformation)
        var error = validity.error
        if dynamic.status != errSecSuccess {
            let detail = "dynamic SecCodeCopySigningInformation \(SpikeSupport.osStatusName(dynamic.status))"
            error = error.isEmpty ? detail : error + "; " + detail
        }
        let audit = auditCheck(pid: pid, requirement: requirement)
        return childObject(
            path: path,
            requirement: requirement,
            pid: pid,
            pass: validity.pass,
            status: validity.status,
            cdhash: signing.cdhash,
            teamID: signing.teamID,
            identifier: signing.identifier.isEmpty ? dynamic.identifier : signing.identifier,
            flags: dynamic.flags,
            flagsPresent: dynamic.flagsPresent,
            audit: audit,
            error: error
        )
    }

    private func auditCheck(pid: pid_t, requirement: String) -> [String: Any] {
        let copied = SpikeSupport.copyAuditToken(pid: pid)
        guard let token = copied.token else {
            return auditUnavailable(copied.error)
        }
        let guest = SpikeSupport.guest(pid: nil, auditToken: token)
        guard let code = guest.code else {
            return [
                "available": true,
                "pass": false,
                "os_status": NSNumber(value: guest.status),
                "os_status_name": SpikeSupport.osStatusName(guest.status),
                "error_description": "SecCodeCopyGuestWithAttributes(audit) \(SpikeSupport.osStatusName(guest.status))",
            ]
        }
        let validity = SpikeSupport.checkValidity(code, requirement: requirement)
        var object: [String: Any] = [
            "available": true,
            "pass": validity.pass,
            "os_status": NSNumber(value: validity.status),
            "os_status_name": SpikeSupport.osStatusName(validity.status),
        ]
        if !validity.error.isEmpty && !validity.pass {
            object["error_description"] = validity.error
        }
        return object
    }

    private func auditUnavailable(_ message: String) -> [String: Any] {
        var object: [String: Any] = [
            "available": false,
            "pass": false,
            "os_status": NSNumber(value: 0),
            "os_status_name": "",
        ]
        if !message.isEmpty {
            object["error_description"] = message
        }
        return object
    }

    private func childObject(
        path: String,
        requirement: String,
        pid: pid_t,
        pass: Bool,
        status: OSStatus,
        cdhash: String,
        teamID: String,
        identifier: String,
        flags: UInt32,
        flagsPresent: Bool,
        audit: [String: Any],
        error: String
    ) -> [String: Any] {
        let decoded = SpikeSupport.statusFlagNames(flagsPresent ? flags : 0)
        var object: [String: Any] = [
            "path": path,
            "requirement": requirement,
            "pid": NSNumber(value: pid),
            "pass": pass,
            "os_status": NSNumber(value: status),
            "os_status_name": status == 0 && !pass ? "" : SpikeSupport.osStatusName(status),
            "cdhash": cdhash,
            "team_id": teamID,
            "identifier": identifier,
            "flags": NSNumber(value: flagsPresent ? flags : 0),
            "flags_hex": String(format: "0x%08x", flagsPresent ? flags : 0),
            "flag_names": decoded.names,
            "unnamed_bits_hex": String(format: "0x%08x", decoded.unnamed),
            "audit_token": audit,
        ]
        if !error.isEmpty && !pass {
            object["error_description"] = error
        } else if !error.isEmpty && pass {
            object["error_description"] = error
        }
        return object
    }

    private func write(_ object: [String: Any], to path: String) -> Int32 {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return 0
        } catch {
            let line = "result write failed: \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return 1
        }
    }
}
