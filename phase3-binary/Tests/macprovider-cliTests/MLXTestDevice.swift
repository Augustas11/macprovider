import Foundation
import MacProviderCore
import MLX

/// Default MLX device for the test suites that run on the CPU.
///
/// mlx-swift realizes its global default stream once, on first use, from the
/// C default device, so `Device.setDefault` picks the device for the rest of
/// the process. CPU suites therefore scope the CPU per test
/// (`Device.withDefaultDevice` in `invokeTest`; async test methods inherit
/// it) and call `pinProcessCPUDefaultWithoutMetallib()` from `class setUp`.
enum MLXTestDevice {
    static let metallibAvailable: Bool = {
        let bundle = Bundle(for: BundleToken.self)
        return PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(
                bundleURL: bundle.resourceURL, executableURL: bundle.executableURL)
    }()

    /// With a metallib, a process-wide CPU default would make every later
    /// Metal-kernel test in the process abort ("Only supports the GPU"), so
    /// leave the GPU default alone. Without one (CI runners), realizing the
    /// global GPU stream aborts loading the metallib, even under
    /// `withDefaultDevice(.cpu)`. So pin the CPU there; every GPU path skips
    /// on such a host.
    static func pinProcessCPUDefaultWithoutMetallib() {
        guard !metallibAvailable else { return }
        Device.setDefault(device: Device(.cpu))
    }
}

private final class BundleToken {}
