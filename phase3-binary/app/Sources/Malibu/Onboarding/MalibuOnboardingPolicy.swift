import Foundation

/// App-wide onboarding policy toggles (nonisolated so routing code can read them).
enum MalibuOnboardingPolicy {
    /// When true (default), fresh onboarding runs `install.sh` instead of the
    /// in-app SPEC-026 register/autotune path.
    static var prefersCLIInstallTrack = true
}
