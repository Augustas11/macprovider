import Foundation

/// Tagged diagnostics for the SPEC-039 paged-KV runtime attach probe.
///
/// The attach decision fails closed at any of ~10 gates (metallib absent, kernel
/// unregistered, hardware unresolved, parity probe not established, MoE isolation
/// probe not proven, capacity sizing unmeasured, …). Historically every one of
/// those collapsed to a single catch-all fallback reason (`paged_fallback_metallib`)
/// and both on-device probes swallowed thrown errors with a bare
/// `catch { return .failClosed }` — so an operator enabling paged-KV on a real
/// model had no way to see WHICH gate refused. This emits one tagged stderr line
/// per refusal so a single on-box load names the exact failing gate.
///
/// These lines are self-limiting: the probes and gate chain only run when paged-KV
/// is `effectiveEnabled` (operator opt-in, disabled by default), so this is silent
/// on every provider that has not turned the feature on.
enum PagedKVRuntimeDiagnostics {
    static let tag = "[paged-kv]"

    static func log(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("\(tag) \(message())\n".utf8))
    }
}
