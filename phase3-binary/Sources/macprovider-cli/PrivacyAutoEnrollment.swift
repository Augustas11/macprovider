import Darwin
import Foundation
import MacProviderCore

/// SPEC-049-R024 provider privacy mode, resolved from non-secret inputs only.
enum PrivacyClassMode: Equatable {
    /// Explicit true: the R007 hardening refusal is unchanged.
    case forced
    /// Explicit false, or relay-blind explicitly disabled.
    case off
    /// Unset: enter privacy mode only on an eligible host.
    case automatic
}

/// Hooks for automatic mode. `eligibility` must not call `ptrace` or
/// `setrlimit`; `harden` runs the full SPEC-049-R007 sequence. Each returns
/// bounded reason codes, empty on success.
struct PrivacyAutoEnrollmentHooks {
    var eligibility: (AppConfig) -> [String]
    var harden: (AppConfig) -> [String]
    var log: (String) -> Void
}

enum PrivacyAutoEnrollment {
    /// Default relay-blind state directory for automatic and forced mode
    /// when none is configured. It sits beside the provider config, outside
    /// any install or repository directory.
    static let defaultStateDirectory = "~/.config/macprovider/relay-blind"

    static func mode(_ config: AppConfig) -> PrivacyClassMode {
        switch config.privacyClassRequested {
        case .some(true):
            return .forced
        case .some(false):
            return .off
        case .none:
            return config.relayBlindRequested == false ? .off : .automatic
        }
    }

    /// Privacy mode on, relay-blind on, and a state directory.
    static func enable(_ config: AppConfig) -> AppConfig {
        var enabled = withStateDirectory(config)
        enabled.privacyClassBeta = true
        enabled.relayBlindEnabled = true
        return enabled
    }

    static func withStateDirectory(_ config: AppConfig) -> AppConfig {
        var updated = config
        if updated.relayBlindStateDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            updated.relayBlindStateDirectory = ConfigLoader.expandTilde(defaultStateDirectory)
        }
        return updated
    }

    static func ineligibleLine(_ reasons: [String]) -> String {
        "privacy_class auto_ineligible reasons=\(reasons.isEmpty ? "unspecified" : reasons.joined(separator: ","))\n"
    }

    static func hardeningFailedLine(_ reasons: [String]) -> String {
        "privacy_class auto_hardening_failed reasons=\(reasons.isEmpty ? "unspecified" : reasons.joined(separator: ","))\n"
    }

    /// Production hooks. Read-only checks run first, so a dev, unsigned, or
    /// SIP-off host never creates a Secure Enclave key or state directory.
    static var live: PrivacyAutoEnrollmentHooks { PrivacyAutoEnrollmentHooks(
        eligibility: { config in
            var reasons = PrivacyRuntimeHardening.automaticEligibilityFailures(syscalls: .live, config: config)
            #if !arch(arm64)
            reasons.append(PrivacyHardeningCode.notArm64)
            #endif
            guard reasons.isEmpty else { return reasons }
            if !secureEnclaveIdentityAvailable() {
                reasons.append(PrivacyHardeningCode.seIdentityUnavailable)
            }
            if !prepareStateDirectory(config.relayBlindStateDirectory) {
                reasons.append(PrivacyHardeningCode.stateDirectoryUnavailable)
            }
            return reasons
        },
        harden: { config in
            if case .failure(let reasons) = PrivacyRuntimeHardening.apply(probe: SystemPrivacyPostureProbe(), config: config) {
                return reasons
            }
            return []
        },
        log: { line in
            FileHandle.standardError.write(Data(line.utf8))
        }
    ) }

    /// Loads or creates the Secure Enclave identity the posture key uses.
    static func secureEnclaveIdentityAvailable() -> Bool {
        #if arch(arm64)
        return (try? SecureEnclaveIdentity.loadOrCreate(quiet: true)) != nil
        #else
        return false
        #endif
    }

    /// Creates missing ancestors of the default directory at 0700 and then
    /// opens or creates the state directory with SPEC-041 custody modes.
    static func prepareStateDirectory(_ raw: String?) -> Bool {
        guard let raw, raw.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        return relayBlindStateDirectoryUsable(url)
    }
}

extension PrivacyRuntimeHardening {
    /// SPEC-049-R024 read-only eligibility. It reads code-signing status,
    /// code identity, SIP, P_TRACED, and the environment, and never calls
    /// `ptrace` or `setrlimit`, so an ineligible host is left untouched.
    static func automaticEligibilityFailures(syscalls: PrivacyPostureSyscalls, config: AppConfig) -> [String] {
        var reasons: [String] = []
        func add(_ code: String) {
            if !reasons.contains(code) { reasons.append(code) }
        }
        if let status = syscalls.codeSignStatus() {
            if status & PrivacyPostureFlags.csValid == 0 { add(PrivacyHardeningCode.missingCSValid) }
            if status & PrivacyPostureFlags.csHard == 0 { add(PrivacyHardeningCode.missingCSHard) }
            if status & PrivacyPostureFlags.csKill == 0 { add(PrivacyHardeningCode.missingCSKill) }
            if status & PrivacyPostureFlags.csRuntime == 0 { add(PrivacyHardeningCode.missingCSRuntime) }
            if status & PrivacyPostureFlags.csDebugged != 0 { add(PrivacyHardeningCode.csDebugged) }
            if status & PrivacyPostureFlags.csGetTaskAllow != 0 { add(PrivacyHardeningCode.csGetTaskAllow) }
        } else {
            add(PrivacyHardeningCode.csopsUnreadable)
        }
        let identity = syscalls.readCodeIdentity()
        if !identity.signatureValid { add(PrivacyHardeningCode.codeSignatureInvalid) }
        if !isCodeCDHash(identity.cdhashHex) { add(PrivacyHardeningCode.cdhashInvalid) }
        if !isTeamID(identity.teamID) { add(PrivacyHardeningCode.teamIDMissing) }
        if !isSigningIdentifier(identity.signingIdentifier) { add(PrivacyHardeningCode.signingIdentifierMissing) }
        if identity.grantedEntitlements.contains(PrivacyEntitlement.getTaskAllow) {
            add(PrivacyHardeningCode.entitlementGetTaskAllow)
        }
        if identity.grantedEntitlements.contains(PrivacyEntitlement.disableLibraryValidation) {
            add(PrivacyHardeningCode.entitlementDisableLibraryValidation)
        }
        if identity.grantedEntitlements.contains(PrivacyEntitlement.allowDyldEnvironmentVariables) {
            add(PrivacyHardeningCode.entitlementAllowDyldEnvironmentVariables)
        }
        if !PrivacySIP.unrestrictedFilesystemProtected(syscalls.csrCheck(PrivacyPostureFlags.csrAllowUnrestrictedFS)) {
            add(PrivacyHardeningCode.sipDisabled)
        }
        switch syscalls.processIsTraced() {
        case .none: add(PrivacyHardeningCode.pTracedUnreadable)
        case .some(true): add(PrivacyHardeningCode.pTraced)
        case .some(false): break
        }
        for code in refusedEnvironmentCodes(syscalls.environment()) {
            add(code)
        }
        if LoopbackServeSelection.select(config.model) != nil { add(PrivacyHardeningCode.loopbackRuntime) }
        if config.kvDiskCache.enabled { add(PrivacyHardeningCode.kvDiskTierEnabled) }
        if !hasConfiguredStateDirectory(config) { add(PrivacyHardeningCode.stateDirectoryMissing) }
        return reasons
    }
}
