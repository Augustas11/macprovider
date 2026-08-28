import Foundation

/// Central registry of onboarding-path timeouts that Malibu.app applies while
/// waiting on the `malibu-cli` subprocess. Every timeout on the "clicked
/// Launch Provider → reached .live" path must live here so the values can be
/// audited as a set, not one file at a time.
///
/// **Design frame**: these budgets are App-side authoritative ceilings. The
/// CLI does not signal progress or expose its own deadlines on the fresh-
/// install code path (see PR #396 for the parallel argument on autotune).
/// So we size each budget to the empirical worst case × ~3-5× safety margin
/// on the largest realistic model at cold boot on a slow disk, capped below
/// spinner-fatigue thresholds.
///
/// **Why so long**: fresh-install onboarding runs against a cold MLX runtime
/// and a cold model file. Realistic timings from `mlx-community/Qwen3-Coder-
/// 30B-A3B-Instruct-4bit` (the current default recommendation):
///   * MLX runtime init: 1-5s
///   * Model file page-in (17 GB, cold): 30-90s on APFS, 5-15s cached
///   * Prefill compile: 10-30s
///   * Coordinator handshake: 5-15s
///   * First status frame emit: <5s
/// Compounded worst-case cold: **60-135s** for the full "started → serving"
/// path. Warm restart: **10-30s**. Prior values (10s / 30s) fired inside
/// the legitimate cold-start window on every fresh install and produced the
/// 2026-07-05 v1.8.4 smoke failure.
///
/// Bumping these DOES NOT change median UX because a healthy CLI returns
/// long before the ceiling. It only affects the "wedged CLI, no way to
/// signal" edge case, where a bit more spinner is preferable to killing a
/// healthy run mid-way through cold boot.
enum MalibuOnboardingTimeouts {
    /// Time budget for the CLI serve subprocess to open its Unix control
    /// socket after Malibu.app spawns it (`malibu-cli serve --ctl-
    /// socket-path ...`). The CLI must:
    ///   1. `Process.run()` returns synchronously; the fork/exec completes
    ///   2. MLX runtime static init
    ///   3. Config parse + validation
    ///   4. `bind()` the AF_UNIX socket at the specified path
    ///
    /// Empirical: 1-10s on this Mac. Cold boot on slower hardware or after
    /// system suspend can push to 30-60s (kernel page-in cost). Budget
    /// 5 min to be robust against TCC dialog races, Spotlight indexing
    /// contention, and slow-disk cold boot.
    ///
    /// Prior value: 10s (via `MalibuAgent.connectControl` call site) —
    /// too short; produced `NSPOSIXErrorDomain Code=60 "Operation timed
    /// out"` on 2026-07-05 v1.8.4 fresh-install smoke.
    static let controlSocketConnectSec: TimeInterval = 300

    /// Time budget for the CLI to reach `.serving` state after the control
    /// socket connects. From socket-accept to first `statusResponse(state:
    /// "serving")` frame the CLI must:
    ///   1. Load the model into unified memory (30-60s cold for a 30B MoE,
    ///      5-15s warm from cache)
    ///   2. Compile the prefill kernel (10-30s cold, cached after first
    ///      run)
    ///   3. Complete coordinator authentication handshake (5-15s including
    ///      WebSocket TLS)
    ///   4. Emit first status frame with `state == "serving"`
    ///
    /// Empirical worst-case cold: **135s** on this Mac. Warm restart:
    /// **10-30s**. Budget 10 min for cold on slower hardware, MLX Metal
    /// compile misses, or coordinator round-trip spikes.
    ///
    /// Prior value: 30s (60-iteration polling loop × 500ms in
    /// `LaunchProviderController.dependencies.waitForFirstServing`) —
    /// too short; produced "Timed out waiting for the first serving
    /// frame." on 2026-07-05 v1.8.4 fresh-install smoke retry.
    static let firstServingFrameSec: TimeInterval = 600

    /// Fresh CLI-track installs mint and persist `provider_token` after the
    /// coordinator handshake, which can land just after `install.sh` exits.
    /// Malibu retries the Keychain import briefly after the launchd provider is
    /// healthy so this race does not bounce the user back to Retry. Total
    /// post-health retry budget is roughly 30s: 15 attempts with 14 sleeps.
    static let providerTokenImportRetryAttempts: Int = 15
    static let providerTokenImportRetryIntervalSec: TimeInterval = 2

    /// Poll interval for `waitForFirstServing`. The controller polls
    /// `snapshot.state` because the state machine transitions there are
    /// event-driven inside MalibuAgent but the controller wants a
    /// deadline-based wait rather than a Combine subscription.
    ///
    /// 500ms is a decent compromise between CPU wake-ups and perceived
    /// stage-transition latency. Do not shrink below 250ms or the loop
    /// starts costing CPU over 10 minutes of wall-clock.
    static let firstServingPollIntervalSec: TimeInterval = 0.5
}
