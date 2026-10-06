import Darwin
import Foundation
import MacProviderCore
import Security

// SPEC-049-R007 posture flags. The SDK does not import these macros, so the
// values are spelled out. Sources: <sys/codesign.h>, <sys/ptrace.h>,
// <sys/proc.h>, <sys/csr.h>.

enum PrivacyPostureFlags {
    /// `<sys/codesign.h>` CS_OPS_STATUS.
    static let csOpsStatus: UInt32 = 0
    /// `<sys/codesign.h>` CS_VALID.
    static let csValid: UInt32 = 0x0000_0001
    /// `<sys/codesign.h>` CS_GET_TASK_ALLOW.
    static let csGetTaskAllow: UInt32 = 0x0000_0004
    /// `<sys/codesign.h>` CS_HARD.
    static let csHard: UInt32 = 0x0000_0100
    /// `<sys/codesign.h>` CS_KILL.
    static let csKill: UInt32 = 0x0000_0200
    /// `<sys/codesign.h>` CS_RUNTIME. Hardened runtime.
    static let csRuntime: UInt32 = 0x0001_0000
    /// `<sys/codesign.h>` CS_DEBUGGED.
    static let csDebugged: UInt32 = 0x1000_0000
    /// `<sys/ptrace.h>` PT_DENY_ATTACH. Swift does not import this request.
    static let ptDenyAttach: Int32 = 31
    /// `<sys/proc.h>` P_TRACED. Debugged process being traced.
    static let pTraced: UInt32 = 0x0000_0800
    /// `<sys/csr.h>` CSR_ALLOW_UNRESTRICTED_FS `(1 << 1)`.
    /// `csr_check` returns 0 when this protection is disabled.
    static let csrAllowUnrestrictedFS: UInt32 = 0x2

    static let requiredStatus: UInt32 = csValid | csHard | csKill | csRuntime
}

enum PrivacyEntitlement {
    static let getTaskAllow = "com.apple.security.get-task-allow"
    static let disableLibraryValidation = "com.apple.security.cs.disable-library-validation"
    static let allowDyldEnvironmentVariables = "com.apple.security.cs.allow-dyld-environment-variables"
}

enum PrivacyHardeningCode {
    static let coreDumps = "core_dumps"
    static let ptDenyAttach = "pt_deny_attach"
    static let pTraced = "p_traced"
    static let pTracedUnreadable = "p_traced_unreadable"
    static let csopsUnreadable = "csops_unreadable"
    static let missingCSValid = "missing_cs_valid"
    static let missingCSHard = "missing_cs_hard"
    static let missingCSKill = "missing_cs_kill"
    static let missingCSRuntime = "missing_cs_runtime"
    static let csDebugged = "cs_debugged"
    static let csGetTaskAllow = "cs_get_task_allow"
    static let getTaskAllow = "get_task_allow"
    static let libraryValidation = "library_validation"
    static let codeSignatureInvalid = "code_signature_invalid"
    static let cdhashInvalid = "cdhash_invalid"
    static let teamIDMissing = "team_id_missing"
    static let signingIdentifierMissing = "signing_identifier_missing"
    static let entitlementGetTaskAllow = "entitlement_get_task_allow"
    static let entitlementDisableLibraryValidation = "entitlement_disable_library_validation"
    static let entitlementAllowDyldEnvironmentVariables = "entitlement_allow_dyld_environment_variables"
    static let sipDisabled = "sip_disabled"
    static let envDYLD = "env_dyld"
    static let envCBTrace = "env_macprovider_cb_trace"
    static let envPerfTrace = "env_macprovider_perf_trace"
    static let envKeepaliveDebug = "env_macprovider_keepalive_debug"
    static let envAllowTestFixtures = "env_macprovider_allow_test_fixtures"
    static let diagnosticEnv = "diagnostic_env"
    static let loopbackRuntime = "loopback_runtime"
    static let kvDiskTierEnabled = "kv_disk_tier_enabled"
    static let relayBlindDisabled = "relay_blind_disabled"
    static let stateDirectoryMissing = "state_directory_missing"
    static let runtimeSource = "runtime_source"
    static let binaryVersion = "binary_version"
    static let probeRejected = "probe_rejected"
    static let notArm64 = "not_arm64"
    static let seIdentityUnavailable = "se_identity_unavailable"
    static let stateDirectoryUnavailable = "state_directory_unavailable"
}

enum PrivacySIP {
    /// `csr_check(CSR_ALLOW_UNRESTRICTED_FS)` returns 0 when that protection is
    /// disabled (the operation is allowed). SIP-on is any non-zero return.
    /// `nil` means the symbol is missing, which SPEC-049-R007 treats as SIP off.
    static func unrestrictedFilesystemProtected(_ csrCheckResult: Int32?) -> Bool {
        guard let csrCheckResult else { return false }
        return csrCheckResult != 0
    }
}

struct PrivacyCodeIdentity: Equatable, Sendable {
    var signatureValid: Bool
    var cdhashHex: String
    var teamID: String
    var signingIdentifier: String
    var grantedEntitlements: Set<String>

    static let unavailable = PrivacyCodeIdentity(
        signatureValid: false,
        cdhashHex: "",
        teamID: "",
        signingIdentifier: "",
        grantedEntitlements: []
    )
}

struct PrivacyPostureObservation: Equatable, Sendable {
    var hardenedRuntime: Bool
    var libraryValidation: Bool
    var getTaskAllow: Bool
    var csDebugged: Bool
    var pTraced: Bool
    var ptDenyAttachApplied: Bool
    var coreDumpsDisabled: Bool
    var sipEnabled: Bool
    var diagnosticEnvClear: Bool
    var kvDiskTierDisabled: Bool
    var runtimeSource: String
    var codeCDHash: String
    var teamID: String
    var signingIdentifier: String
    var binaryVersion: String
    var failureReasons: [String]
}

protocol PrivacyPostureProbe: Sendable {
    func observe() -> PrivacyPostureObservation
    /// Read-only P_TRACED and CS_DEBUGGED. Must not call ptrace or setrlimit.
    func isTracedOrDebugged() -> Bool
}

struct PrivacyPostureSyscalls: Sendable {
    var disableCoreDumps: @Sendable () -> Bool
    var denyAttach: @Sendable () -> Bool
    var processIsTraced: @Sendable () -> Bool?
    var codeSignStatus: @Sendable () -> UInt32?
    var readCodeIdentity: @Sendable () -> PrivacyCodeIdentity
    /// `nil` means `csr_check` is missing. Otherwise the raw `csr_check` result
    /// for the mask the probe passes (`CSR_ALLOW_UNRESTRICTED_FS`).
    var csrCheck: @Sendable (UInt32) -> Int32?
    var environment: @Sendable () -> [String: String]

    /// Production hooks. `denyAttach` calls `ptrace(PT_DENY_ATTACH)`.
    /// Tests pass their own hooks and must not use this value.
    static let live = PrivacyPostureSyscalls(
        disableCoreDumps: PrivacyPostureLiveSyscalls.disableCoreDumps,
        denyAttach: PrivacyPostureLiveSyscalls.ptraceDenyAttach,
        processIsTraced: PrivacyPostureLiveSyscalls.processIsTraced,
        codeSignStatus: PrivacyPostureLiveSyscalls.codeSignStatus,
        readCodeIdentity: PrivacyCodeSignature.readSelf,
        csrCheck: PrivacyPostureLiveSyscalls.csrCheck,
        environment: { ProcessInfo.processInfo.environment }
    )
}

struct SystemPrivacyPostureProbe: PrivacyPostureProbe {
    var syscalls: PrivacyPostureSyscalls

    /// Live process probe. `observe()` calls `ptrace(PT_DENY_ATTACH)`.
    /// Tests must use `init(syscalls:)` and must not call this initializer.
    init() {
        self.init(syscalls: .live)
    }

    init(syscalls: PrivacyPostureSyscalls) {
        self.syscalls = syscalls
    }

    func observe() -> PrivacyPostureObservation {
        // SPEC-049-R007 order. Later steps still run after an earlier failure
        // so the fatal line names every broken check.
        let coreDumpsDisabled = syscalls.disableCoreDumps()
        let ptDenyAttachApplied = syscalls.denyAttach()
        let tracedRead = syscalls.processIsTraced()
        let status = syscalls.codeSignStatus()
        let identity = syscalls.readCodeIdentity()
        let sipResult = syscalls.csrCheck(PrivacyPostureFlags.csrAllowUnrestrictedFS)
        let envCodes = PrivacyRuntimeHardening.refusedEnvironmentCodes(syscalls.environment())

        var reasons: [String] = []
        if !coreDumpsDisabled { reasons.append(PrivacyHardeningCode.coreDumps) }
        if !ptDenyAttachApplied { reasons.append(PrivacyHardeningCode.ptDenyAttach) }

        let pTraced: Bool
        if let tracedRead {
            pTraced = tracedRead
            if tracedRead { reasons.append(PrivacyHardeningCode.pTraced) }
        } else {
            pTraced = true
            reasons.append(PrivacyHardeningCode.pTracedUnreadable)
        }

        var hardenedRuntime = false
        var csDebugged = true
        var csGetTaskAllowFlag = true
        if let status {
            hardenedRuntime = status & PrivacyPostureFlags.csRuntime != 0
            csDebugged = status & PrivacyPostureFlags.csDebugged != 0
            csGetTaskAllowFlag = status & PrivacyPostureFlags.csGetTaskAllow != 0
            if status & PrivacyPostureFlags.csValid == 0 { reasons.append(PrivacyHardeningCode.missingCSValid) }
            if status & PrivacyPostureFlags.csHard == 0 { reasons.append(PrivacyHardeningCode.missingCSHard) }
            if status & PrivacyPostureFlags.csKill == 0 { reasons.append(PrivacyHardeningCode.missingCSKill) }
            if !hardenedRuntime { reasons.append(PrivacyHardeningCode.missingCSRuntime) }
            if csDebugged { reasons.append(PrivacyHardeningCode.csDebugged) }
            if csGetTaskAllowFlag { reasons.append(PrivacyHardeningCode.csGetTaskAllow) }
        } else {
            reasons.append(PrivacyHardeningCode.csopsUnreadable)
        }

        if !identity.signatureValid { reasons.append(PrivacyHardeningCode.codeSignatureInvalid) }
        let entitlements = identity.grantedEntitlements
        if entitlements.contains(PrivacyEntitlement.getTaskAllow) {
            reasons.append(PrivacyHardeningCode.entitlementGetTaskAllow)
        }
        if entitlements.contains(PrivacyEntitlement.disableLibraryValidation) {
            reasons.append(PrivacyHardeningCode.entitlementDisableLibraryValidation)
        }
        if entitlements.contains(PrivacyEntitlement.allowDyldEnvironmentVariables) {
            reasons.append(PrivacyHardeningCode.entitlementAllowDyldEnvironmentVariables)
        }
        reasons.append(contentsOf: envCodes)

        let csopsUnreadable = status == nil
        return PrivacyPostureObservation(
            hardenedRuntime: hardenedRuntime,
            libraryValidation: identity.signatureValid && !entitlements.contains(PrivacyEntitlement.disableLibraryValidation),
            getTaskAllow: csGetTaskAllowFlag || entitlements.contains(PrivacyEntitlement.getTaskAllow) || csopsUnreadable,
            csDebugged: csDebugged,
            pTraced: pTraced,
            ptDenyAttachApplied: ptDenyAttachApplied,
            coreDumpsDisabled: coreDumpsDisabled,
            sipEnabled: PrivacySIP.unrestrictedFilesystemProtected(sipResult),
            diagnosticEnvClear: envCodes.isEmpty,
            kvDiskTierDisabled: true,
            runtimeSource: PrivacyClassConstants.runtimeSource,
            codeCDHash: identity.cdhashHex,
            teamID: identity.teamID,
            signingIdentifier: identity.signingIdentifier,
            binaryVersion: CoordinatorClient.binaryVersion,
            failureReasons: reasons
        )
    }

    func isTracedOrDebugged() -> Bool {
        guard let traced = syscalls.processIsTraced() else { return true }
        if traced { return true }
        guard let flags = syscalls.codeSignStatus() else { return true }
        return flags & PrivacyPostureFlags.csDebugged != 0
    }
}

/// Swift `Result` requires `Failure: Error`. `[String]` does not conform, so
/// this keeps the plan's success/failure shape with the reason codes as the
/// failure value.
enum PrivacyHardeningOutcome: Equatable {
    case success(PrivacyPostureObservation)
    case failure([String])
}

enum PrivacyRuntimeHardening {
    private static let decryptRecheckLock = NSLock()
    /// SPEC-049-R007. Set for the process lifetime when a privacy decrypt
    /// recheck fails. Separate from `recheckBeforeDecrypt`, which stays a pure
    /// probe read so a later clean probe is still observable.
    private static var decryptRecheckDidFail = false

    static var decryptRecheckFailed: Bool {
        decryptRecheckLock.lock()
        defer { decryptRecheckLock.unlock() }
        return decryptRecheckDidFail
    }

    static func noteDecryptRecheckFailed() {
        decryptRecheckLock.lock()
        decryptRecheckDidFail = true
        decryptRecheckLock.unlock()
    }

    static func resetDecryptRecheckForTest() {
        decryptRecheckLock.lock()
        decryptRecheckDidFail = false
        decryptRecheckLock.unlock()
    }

    static func apply(
        probe: some PrivacyPostureProbe,
        config: AppConfig
    ) -> PrivacyHardeningOutcome {
        var observation = probe.observe()
        let probeReasons = observation.failureReasons
        if let loopback = LoopbackServeSelection.select(config.model) {
            observation.runtimeSource = loopback.runtimeSource
        }
        if config.kvDiskCache.enabled {
            observation.kvDiskTierDisabled = false
        }
        let reasons = failureReasons(observation: observation, config: config, probeReasons: probeReasons)
        observation.failureReasons = reasons
        if reasons.isEmpty {
            return .success(observation)
        }
        return .failure(reasons)
    }

    /// True only when P_TRACED and CS_DEBUGGED are both clear and readable.
    /// An unreadable check fails closed. This does not call ptrace.
    static func recheckBeforeDecrypt(probe: some PrivacyPostureProbe) -> Bool {
        !probe.isTracedOrDebugged()
    }

    static func fatalLine(reasons: [String]) -> String {
        let codes = reasons.isEmpty ? "unspecified" : reasons.joined(separator: ",")
        return "FATAL privacy_class_hardening_failed reasons=\(codes)\n"
    }

    static func refusedEnvironmentCodes(_ environment: [String: String]) -> [String] {
        var codes: [String] = []
        if environment.keys.contains(where: { $0.hasPrefix("DYLD_") }) {
            codes.append(PrivacyHardeningCode.envDYLD)
        }
        let named: [(String, String)] = [
            ("MACPROVIDER_CB_TRACE", PrivacyHardeningCode.envCBTrace),
            ("MACPROVIDER_PERF_TRACE", PrivacyHardeningCode.envPerfTrace),
            ("MACPROVIDER_KEEPALIVE_DEBUG", PrivacyHardeningCode.envKeepaliveDebug),
            ("MACPROVIDER_ALLOW_TEST_FIXTURES", PrivacyHardeningCode.envAllowTestFixtures),
        ]
        for (name, code) in named where environment[name] != nil {
            codes.append(code)
        }
        return codes
    }

    private static func failureReasons(
        observation: PrivacyPostureObservation,
        config: AppConfig,
        probeReasons: [String]
    ) -> [String] {
        var reasons: [String] = []
        func add(_ code: String) {
            guard isBoundedCode(code), !reasons.contains(code) else { return }
            reasons.append(code)
        }
        if !observation.coreDumpsDisabled { add(PrivacyHardeningCode.coreDumps) }
        if !observation.ptDenyAttachApplied { add(PrivacyHardeningCode.ptDenyAttach) }
        if observation.pTraced { add(PrivacyHardeningCode.pTraced) }
        if !observation.hardenedRuntime { add(PrivacyHardeningCode.missingCSRuntime) }
        if !observation.libraryValidation { add(PrivacyHardeningCode.libraryValidation) }
        if observation.getTaskAllow { add(PrivacyHardeningCode.getTaskAllow) }
        if observation.csDebugged { add(PrivacyHardeningCode.csDebugged) }
        if !observation.sipEnabled { add(PrivacyHardeningCode.sipDisabled) }
        if !observation.diagnosticEnvClear { add(PrivacyHardeningCode.diagnosticEnv) }
        if !observation.kvDiskTierDisabled || config.kvDiskCache.enabled {
            add(PrivacyHardeningCode.kvDiskTierEnabled)
        }
        if observation.runtimeSource != PrivacyClassConstants.runtimeSource {
            add(PrivacyHardeningCode.runtimeSource)
        }
        if LoopbackServeSelection.select(config.model) != nil {
            add(PrivacyHardeningCode.loopbackRuntime)
        }
        if !isCodeCDHash(observation.codeCDHash) { add(PrivacyHardeningCode.cdhashInvalid) }
        if !isTeamID(observation.teamID) { add(PrivacyHardeningCode.teamIDMissing) }
        if !isSigningIdentifier(observation.signingIdentifier) {
            add(PrivacyHardeningCode.signingIdentifierMissing)
        }
        if observation.binaryVersion != CoordinatorClient.binaryVersion {
            add(PrivacyHardeningCode.binaryVersion)
        }
        if !config.relayBlindEnabled { add(PrivacyHardeningCode.relayBlindDisabled) }
        if !hasConfiguredStateDirectory(config) { add(PrivacyHardeningCode.stateDirectoryMissing) }
        for code in probeReasons {
            if isBoundedCode(code) {
                add(code)
            } else {
                add(PrivacyHardeningCode.probeRejected)
            }
        }
        return reasons
    }

    /// Absolute configured path. The relay-blind manager creates the directory
    /// after this check and before any coordinator connection.
    static func hasConfiguredStateDirectory(_ config: AppConfig) -> Bool {
        guard let raw = config.relayBlindStateDirectory else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 1 && trimmed.hasPrefix("/")
    }

    private static func isBoundedCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7a) || byte == 0x5f
        }
    }

    static func isCodeCDHash(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 40 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    static func isTeamID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a)
        }
    }

    static func isSigningIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...256).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in byte >= 0x21 && byte <= 0x7e }
    }
}

enum PrivacyCodeSignature {
    static func readSelf() -> PrivacyCodeIdentity {
        var dynamic: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamic) == errSecSuccess, let dynamic else {
            return .unavailable
        }
        let signatureValid = SecCodeCheckValidity(dynamic, SecCSFlags(), nil) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return PrivacyCodeIdentity(
                signatureValid: signatureValid,
                cdhashHex: "",
                teamID: "",
                signingIdentifier: "",
                grantedEntitlements: []
            )
        }
        // `<Security/SecCode.h>` kSecCSSigningInformation = 1 << 1.
        let signingInfo = SecCSFlags(rawValue: 1 << 1)
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, signingInfo, &information) == errSecSuccess,
              let information else {
            return PrivacyCodeIdentity(
                signatureValid: signatureValid,
                cdhashHex: "",
                teamID: "",
                signingIdentifier: "",
                grantedEntitlements: []
            )
        }
        let info = information as NSDictionary
        return PrivacyCodeIdentity(
            signatureValid: signatureValid,
            cdhashHex: cdhashHex(info),
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String ?? "",
            signingIdentifier: info[kSecCodeInfoIdentifier as String] as? String ?? "",
            grantedEntitlements: grantedEntitlements(info)
        )
    }

    private static func cdhashHex(_ info: NSDictionary) -> String {
        guard let data = info[kSecCodeInfoUnique as String] as? Data, data.count == 20 else { return "" }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func grantedEntitlements(_ info: NSDictionary) -> Set<String> {
        guard let raw = info[kSecCodeInfoEntitlementsDict as String] as? NSDictionary else { return [] }
        var granted: Set<String> = []
        for case let key as String in raw.allKeys where entitlementGranted(raw[key]) {
            granted.insert(key)
        }
        return granted
    }

    private static func entitlementGranted(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }
}

private typealias PtraceFunction = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
private typealias CSOpsFunction = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
private typealias CSRCheckFunction = @convention(c) (UInt32) -> Int32

private enum PrivacyDynamicSymbols {
    /// `<dlfcn.h>` RTLD_DEFAULT, the dlsym handle for already-loaded symbols.
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    static func ptrace() -> PtraceFunction? { load("ptrace", as: PtraceFunction.self) }
    static func csops() -> CSOpsFunction? { load("csops", as: CSOpsFunction.self) }
    static func csrCheck() -> CSRCheckFunction? { load("csr_check", as: CSRCheckFunction.self) }

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

enum PrivacyPostureLiveSyscalls {
    static func disableCoreDumps() -> Bool {
        var limit = rlimit()
        limit.rlim_cur = 0
        limit.rlim_max = 0
        guard setrlimit(RLIMIT_CORE, &limit) == 0 else { return false }
        var readback = rlimit()
        guard getrlimit(RLIMIT_CORE, &readback) == 0 else { return false }
        return readback.rlim_cur == 0 && readback.rlim_max == 0
    }

    /// `ptrace(PT_DENY_ATTACH, 0, 0, 0)`. Only the serve process calls this.
    static func ptraceDenyAttach() -> Bool {
        guard let fn = PrivacyDynamicSymbols.ptrace() else { return false }
        return fn(PrivacyPostureFlags.ptDenyAttach, 0, nil, 0) == 0
    }

    static func processIsTraced() -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return sysctl(base, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == getpid() else {
            return nil
        }
        let flag = UInt32(truncatingIfNeeded: info.kp_proc.p_flag)
        return flag & PrivacyPostureFlags.pTraced != 0
    }

    static func codeSignStatus() -> UInt32? {
        guard let fn = PrivacyDynamicSymbols.csops() else { return nil }
        var flags: UInt32 = 0
        let rc = withUnsafeMutablePointer(to: &flags) { pointer -> Int32 in
            fn(
                getpid(),
                PrivacyPostureFlags.csOpsStatus,
                UnsafeMutableRawPointer(pointer),
                MemoryLayout<UInt32>.size
            )
        }
        guard rc == 0 else { return nil }
        return flags
    }

    static func csrCheck(mask: UInt32) -> Int32? {
        guard let fn = PrivacyDynamicSymbols.csrCheck() else { return nil }
        return fn(mask)
    }
}
