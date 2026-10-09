import ArgumentParser
import Foundation
import MacProviderCore

/// `macprovider-cli restart`: restarts the installed provider LaunchAgent
/// (`live.malibu.provider`) so `serve` re-reads config.yaml, e.g. after a
/// creator's `pool_model_id` is set or a `models offer` is submitted. It is
/// the same `launchctl kickstart -k` the credential repair path uses; launchd
/// sends SIGTERM, serve drains, and launchd starts it again.
struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the installed provider service so serve re-reads its config."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Selects the launchd domain (protected-file installs run in the system domain).")
    var config: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        try await RestartCommandRunner(
            domain: CredentialRestartProver.launchdDomain(for: resolved),
            currentPID: { _ in CredentialRestartProver.currentLaunchdPID(config: resolved) }
        ).run()
    }
}

struct RestartCommandRunner {
    let domain: String
    var currentPID: @Sendable (String) -> Int?
    var kickstart: @Sendable (String) throws -> Void = { try CredentialRestartProver.restartLaunchdProvider(domain: $0) }
    var sleep: @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    var attempts = 30
    var stdout: @Sendable (String) -> Void = { print($0) }

    func run() async throws {
        let target = "\(domain)/\(CredentialRestartProver.launchdLabel)"
        let before = currentPID(domain)
        guard before != nil else {
            throw ValidationError("provider service \(target) is not running; start it with the installer, or run `macprovider-cli serve` in the foreground")
        }
        do {
            try kickstart(domain)
        } catch {
            throw ValidationError("could not restart \(target): \(error)")
        }
        for _ in 0..<attempts {
            if let pid = currentPID(domain), pid != before {
                stdout("restarted \(target) (pid \(before.map(String.init) ?? "-") -> \(pid))")
                return
            }
            await sleep(500_000_000)
        }
        throw ValidationError("restart of \(target) was requested but no new serve process appeared; check `macprovider-cli status`")
    }
}
