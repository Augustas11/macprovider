import XCTest
@testable import Malibu

/// Pins the invariants for the shared onboarding-path timeout registry.
///
/// **Design decision**: these budgets are App-side authoritative ceilings
/// because the CLI does not signal progress or expose its own deadlines on
/// the fresh-install code path. Each budget must survive the empirical
/// worst-case cold-start of a 30B MoE model on Apple silicon.
///
/// The 2026-07-05 v1.8.4 smoke shows that a 10s `controlSocketConnect` and a
/// 30s `firstServingFrame` both fire on fresh-install onboarding while the
/// CLI is doing legitimate cold-boot work (MLX runtime init, model page-in,
/// prefill compile, coordinator handshake). Any value below the realistic
/// worst-case will reproduce that failure on some tier of hardware.
final class MalibuOnboardingTimeoutsTests: XCTestCase {
    /// Realistic cold-start ceiling for CLI serve subprocess to open the
    /// Unix control socket:
    ///   * process fork/exec: <1s
    ///   * MLX runtime static init: 1-5s
    ///   * config parse + validation: 1-5s
    ///   * AF_UNIX bind: <1s
    /// Empirical: 1-10s on this Mac. Slower disk / kernel page-in cost
    /// can push to 30-60s. 90s covers 3× that with margin.
    private static let coldStartControlSocketWorstCaseSec: TimeInterval = 90

    /// Realistic cold-start ceiling for reaching the first `.serving` frame:
    ///   * model file page-in (17 GB, cold): 30-90s on APFS
    ///   * prefill kernel compile: 10-30s
    ///   * coordinator TLS + auth handshake: 5-15s
    ///   * first status frame emit: <5s
    /// Empirical worst-case cold: 60-135s. 240s covers ~2× that with
    /// margin for slow-disk / thermal-throttle / spinning-rust worst case.
    private static let coldStartServingWorstCaseSec: TimeInterval = 240

    /// Above this, the user is trapped in a multi-hour spinner and has
    /// almost certainly quit the app. Beyond legitimate CLI-start runtime
    /// by any reasonable interpretation.
    private static let untenableSpinnerCeilingSec: TimeInterval = 2 * 60 * 60

    // MARK: - controlSocketConnect

    func testControlSocketConnectCoversColdStartWorstCase() {
        XCTAssertGreaterThanOrEqual(
            MalibuOnboardingTimeouts.controlSocketConnectSec,
            Self.coldStartControlSocketWorstCaseSec,
            """
            controlSocketConnectSec=\(MalibuOnboardingTimeouts.controlSocketConnectSec)s \
            is below the realistic cold-start worst case of \
            \(Self.coldStartControlSocketWorstCaseSec)s. \
            Fresh-install onboarding on slower hardware will hit \
            NSPOSIXErrorDomain Code=60 before the CLI can open the Unix \
            control socket.
            """
        )
    }

    func testControlSocketConnectIsNotUntenable() {
        XCTAssertLessThanOrEqual(
            MalibuOnboardingTimeouts.controlSocketConnectSec,
            Self.untenableSpinnerCeilingSec,
            "controlSocketConnectSec must not exceed 2h or wedged CLI traps the user in a multi-hour spinner."
        )
    }

    // MARK: - firstServingFrame

    func testFirstServingFrameCoversColdStartWorstCase() {
        XCTAssertGreaterThanOrEqual(
            MalibuOnboardingTimeouts.firstServingFrameSec,
            Self.coldStartServingWorstCaseSec,
            """
            firstServingFrameSec=\(MalibuOnboardingTimeouts.firstServingFrameSec)s \
            is below the realistic cold-start worst case of \
            \(Self.coldStartServingWorstCaseSec)s for a 30B MoE model. \
            Fresh-install onboarding will hit "Timed out waiting for the \
            first serving frame." while the CLI is still doing legitimate \
            model-load / prefill / coordinator-handshake work.
            """
        )
    }

    func testFirstServingFrameIsNotUntenable() {
        XCTAssertLessThanOrEqual(
            MalibuOnboardingTimeouts.firstServingFrameSec,
            Self.untenableSpinnerCeilingSec,
            "firstServingFrameSec must not exceed 2h or wedged CLI traps the user in a multi-hour spinner."
        )
    }

    // MARK: - poll interval

    func testFirstServingPollIntervalIsReasonable() {
        // Below 250ms burns CPU over the ~10 min worst case (2400 wake-ups
        // at 250ms vs 1200 at 500ms). Above 2s makes stage transitions
        // feel laggy in the healthy case.
        XCTAssertGreaterThanOrEqual(
            MalibuOnboardingTimeouts.firstServingPollIntervalSec,
            0.25,
            "poll interval below 250ms wastes CPU during the multi-minute waits."
        )
        XCTAssertLessThanOrEqual(
            MalibuOnboardingTimeouts.firstServingPollIntervalSec,
            2.0,
            "poll interval above 2s makes healthy-case transitions feel laggy."
        )
    }
}
