@testable import MacProviderCore
import MLX
import XCTest

/// Suites that run on the CPU must scope it per test. A process-wide CPU
/// default outlives the suite: MLX realizes its global default stream once, so
/// every later Metal-kernel test in the same process aborts with
/// "[metal_kernel] Only supports the GPU". The class name sorts after the CPU
/// suites, so a single-process run (`swift test` without `--parallel`) checks
/// what they left behind.
final class MLXTestDeviceIsolationTests: XCTestCase {
    func testProcessDefaultDeviceIsStillTheGPUWhenAMetallibExists() throws {
        guard MLXTestDevice.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        XCTAssertEqual(Device.defaultDevice().deviceType, .gpu)
    }
}

/// The CPU suites scope the device in `invokeTest`. Their async test methods
/// must see that scope too, or they would run on the process default.
final class MLXTestDeviceAsyncScopeTests: XCTestCase {
    override func invokeTest() {
        guard MLXTestDevice.metallibAvailable else { return super.invokeTest() }
        Device.withDefaultDevice(Device(.cpu)) {
            super.invokeTest()
        }
    }

    func testAsyncTestMethodRunsOnTheInvokeTestScopedDevice() async throws {
        guard MLXTestDevice.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        XCTAssertEqual(Device.defaultDevice().deviceType, .cpu)
    }
}
