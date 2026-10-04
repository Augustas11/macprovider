import Darwin
import Foundation
import Security

enum SpikeSupport {
    /// SecStaticCodeRef is `const __SecCode *`. Dynamic status is only defined
    /// for a SecCode, and the C entry point accepts that pointer. The Swift
    /// overlay types the parameter as SecStaticCode, so bridge the reference.
    static func asStaticCode(_ code: SecCode) -> SecStaticCode {
        unsafeBitCast(code, to: SecStaticCode.self)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func osStatusName(_ status: OSStatus) -> String {
        let table: [(OSStatus, String)] = [
            (errSecSuccess, "errSecSuccess"),
            (errSecCSReqFailed, "errSecCSReqFailed"),
            (errSecCSReqInvalid, "errSecCSReqInvalid"),
            (errSecCSUnsigned, "errSecCSUnsigned"),
            (errSecCSNoSuchCode, "errSecCSNoSuchCode"),
            (errSecCSBadTeamIdentifier, "errSecCSBadTeamIdentifier"),
            (errSecCSSignatureUntrusted, "errSecCSSignatureUntrusted"),
        ]
        for (value, name) in table where value == status {
            return name
        }
        return "OSStatus(\(status))"
    }

    struct SigningFacts {
        var status: OSStatus = errSecSuccess
        var teamID = ""
        var identifier = ""
        var cdhash = ""
        var flags: UInt32 = 0
        var flagsPresent = false
        var entitlements: [String: String] = [:]
        var errorDescription = ""
    }

    static func readSigningFacts(_ code: SecCode, flags: UInt32) -> SigningFacts {
        var facts = SigningFacts()
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            asStaticCode(code),
            SecCSFlags(rawValue: flags),
            &info
        )
        facts.status = status
        guard status == errSecSuccess, let dict = info as NSDictionary? else {
            facts.errorDescription = "SecCodeCopySigningInformation \(osStatusName(status))"
            return facts
        }
        if let team = dict[kSecCodeInfoTeamIdentifier] as? String {
            facts.teamID = team
        }
        if let identifier = dict[kSecCodeInfoIdentifier] as? String {
            facts.identifier = identifier
        }
        if let unique = dict[kSecCodeInfoUnique] as? Data {
            facts.cdhash = hex(unique)
        } else if let unique = dict[kSecCodeInfoUnique] as? NSData {
            facts.cdhash = hex(unique as Data)
        }
        if let number = dict[kSecCodeInfoStatus] as? NSNumber {
            facts.flags = number.uint32Value
            facts.flagsPresent = true
        }
        if let entitlements = dict[kSecCodeInfoEntitlementsDict] as? NSDictionary {
            facts.entitlements = stringMap(entitlements)
        }
        return facts
    }

    /// SecCodeStatus bits named in CSCommon.h, plus the xnu cs_blobs.h CS_*
    /// bits that matter for this spike (hardened runtime, enforcement,
    /// signed). Remaining bits are reported as unnamed.
    static func statusFlagNames(_ flags: UInt32) -> (names: [String], unnamed: UInt32) {
        let named: [(UInt32, String)] = [
            (0x0000_0001, "kSecCodeStatusValid"),
            (0x0000_0100, "kSecCodeStatusHard"),
            (0x0000_0200, "kSecCodeStatusKill"),
            (0x0000_1000, "CS_ENFORCEMENT"),
            (0x0000_2000, "CS_REQUIRE_LV"),
            (0x0001_0000, "CS_RUNTIME"),
            (0x0002_0000, "CS_LINKER_SIGNED"),
            (0x0000_0002, "CS_ADHOC"),
            (0x2000_0000, "CS_SIGNED"),
            (0x1000_0000, "kSecCodeStatusDebugged"),
            (0x0400_0000, "kSecCodeStatusPlatform"),
        ]
        var names: [String] = []
        var known: UInt32 = 0
        for (mask, name) in named {
            known |= mask
            if flags & mask != 0 {
                names.append(name)
            }
        }
        return (names, flags & ~known)
    }

    static func guest(pid: pid_t?, auditToken: Data?) -> (code: SecCode?, status: OSStatus) {
        let attributes = NSMutableDictionary()
        if let pid {
            attributes[kSecGuestAttributePid as NSString] = NSNumber(value: pid)
        }
        if let auditToken {
            attributes[kSecGuestAttributeAudit as NSString] = auditToken as NSData
        }
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        if status != errSecSuccess {
            return (nil, status)
        }
        return (code, status)
    }

    /// The audit token is a process credential. Callers may hand the bytes to
    /// SecCode and must not put them in the result file or a log.
    static func copyAuditToken(pid: pid_t) -> (token: Data?, error: String) {
        var task: mach_port_t = 0
        let nameStatus = task_name_for_pid(mach_task_self_, pid, &task)
        if nameStatus != KERN_SUCCESS {
            return (nil, "task_name_for_pid kern_return \(nameStatus)")
        }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let infoStatus = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), rebound, &count)
            }
        }
        if infoStatus != KERN_SUCCESS {
            return (nil, "task_info TASK_AUDIT_TOKEN kern_return \(infoStatus)")
        }
        let data = withUnsafeBytes(of: token) { Data($0) }
        return (data, "")
    }

    static func checkValidity(_ code: SecCode, requirement: String) -> (pass: Bool, status: OSStatus, error: String) {
        var object: SecRequirement?
        let made = SecRequirementCreateWithString(requirement as CFString, [], &object)
        guard made == errSecSuccess, let object else {
            return (false, made, "SecRequirementCreateWithString \(osStatusName(made))")
        }
        let status = SecCodeCheckValidity(code, [], object)
        if status != errSecSuccess {
            return (false, status, osStatusName(status))
        }
        return (true, status, "")
    }

    /// Team characters are restricted so the value cannot change the requirement syntax.
    static func defaultChildRequirement(teamID: String) -> String? {
        guard teamID.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"live.malibu.provider.cli\""
    }

    static func probeError(_ error: Error) -> [String: Any] {
        let ns = error as NSError
        return [
            "domain": ns.domain,
            "code": ns.code,
            "description": ns.localizedDescription,
        ]
    }

    static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func stringMap(_ dict: NSDictionary) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in dict {
            guard let name = key as? String else { continue }
            if out.count >= 64 { break }
            out[name] = clip(stringify(value), limit: 512)
        }
        return out
    }

    private static func stringify(_ value: Any) -> String {
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let list = value as? [Any] {
            return list.map { stringify($0) }.joined(separator: ",")
        }
        if let data = value as? Data {
            let prefix = data.prefix(32)
            let suffix = data.count > 32 ? "…" : ""
            return "hex:" + hex(Data(prefix)) + suffix
        }
        return String(describing: type(of: value))
    }

    private static func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit)) + "…"
    }
}
