// This source is intentionally compiled only by the isolated Studio runner.
#if MALIBU_HANDOFF_STUDIO_FIXTURE
import AppKit
import Darwin
import Foundation
import Security

/// Test-only process used by test-malibu-handoff-studio.py. It compiles the
/// shipping handoff state machine into real AppKit bundles without allowing an
/// unsigned or arbitrary process to stand in for a production Malibu peer.
@main
struct MalibuHandoffFixtureMain {
    static func main() {
        _ = Darwin.nice(10)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = FixtureDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var handoff: AppInstanceHandoff?

    private var mode: String { ProcessInfo.processInfo.environment["MALIBU_HANDOFF_MODE"] ?? "successor" }
    private var fixtureRoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MALIBU_HANDOFF_ROOT"] ?? "/nonexistent")
            .standardizedFileURL
    }
    private var registryDirectory: URL { fixtureRoot.appendingPathComponent("registry", isDirectory: true) }

    private func log(_ message: String) {
        print("malibu-handoff-fixture pid=\(ProcessInfo.processInfo.processIdentifier) \(message)")
        fflush(stdout)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.title = "Malibu fixture"
        log("status-item-created mode=\(mode)")

        // The isolated allowlist below is fixture-only. This proves an
        // ad-hoc fixture cannot satisfy the shipping Team-ID requirement.
        if mode == "verify-production-gate" {
            guard !AppInstanceHandoff.Registry.isSignedMalibu(ProcessInfo.processInfo.processIdentifier) else {
                log("production-team-gate-incorrectly-accepted-adhoc")
                abort()
            }
            log("production-team-gate-rejected-adhoc")
            NSApp.terminate(nil)
            return
        }

        // The legacy fixture deliberately has neither a registry record nor a
        // successor acknowledgement and models NSTerminateLater that never
        // replies. It must be retired only by the successor's normal deadline.
        guard mode != "legacy" && mode != "passive" else { return }
        beginHandoff()
    }

    private func beginHandoff() {
        guard let launchedAt = NSRunningApplication.current.launchDate,
              let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = ProviderCLIVersion.strictNormalize(rawVersion) else {
            log("fixture-startup-invalid launchDate=\(String(describing: NSRunningApplication.current.launchDate)) version=\(String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")))")
            NSApp.terminate(nil)
            return
        }

        let own = AppInstanceHandoff.Identity(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: launchedAt,
            version: version
        )
        let registry = AppInstanceHandoff.Registry(
            directory: registryDirectory,
            validatesSignature: { [fixtureRoot] pid in
                FixtureSignatureValidator.matchesTrustedFixture(pid: pid, root: fixtureRoot)
            }
        )
        do {
            try registry.publish(own)
        } catch {
            log("registry-publish-failed \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        let handoff = AppInstanceHandoff(
            own: own,
            peers: { registry.peers(own: own) },
            terminate: { identity, force in
                guard let application = registry.application(matching: identity) else {
                    return true
                }
                self.log("signal pid=\(identity.pid) force=\(force)")
                return force ? application.forceTerminate() : application.terminate()
            },
            quitSelf: { NSApp.terminate(nil) },
            clock: { ProcessInfo.processInfo.systemUptime },
            log: { self.log($0) },
            publishReady: { try registry.publish(own, ready: true) }
        )
        self.handoff = handoff
        Task { @MainActor in
            if await handoff.claim() {
                self.log("claim-ready version=\(version)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mode == "legacy" {
            log("legacy-terminate-later-forever")
            return .terminateLater
        }
        item = nil
        log("status-item-removed")
        return .terminateNow
    }
}

private enum FixtureSignatureValidator {
    /// The runner provides an explicit allowlist of CDHashes calculated after
    /// ad-hoc signing its fixture bundles. This permits only the fixture's
    /// exact running code under its isolated root; it never treats arbitrary
    /// ad-hoc code as a Malibu peer.
    static func matchesTrustedFixture(pid: Int32, root: URL) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid),
              let bundleURL = application.bundleURL?.standardizedFileURL,
              bundleURL.path.hasPrefix(root.path + "/"),
              let rawExpected = ProcessInfo.processInfo.environment["MALIBU_HANDOFF_TRUSTED_CDHASHES"] else { return false }
        let expected = rawExpected.split(separator: ",").map(String.init)
        guard !expected.isEmpty else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code
        ) == errSecSuccess, let code else { return false }
        // Ask Security to compare the running guest against each exact hash;
        // its former executable URL can now name the replacement bundle.
        return expected.contains { hash in
            guard hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) else { return false }
            var requirement: SecRequirement?
            let text = "cdhash H\"\(hash)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
    }
}
#endif
