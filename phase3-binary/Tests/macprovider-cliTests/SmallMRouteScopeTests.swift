import Foundation
import MLX
@testable import macprovider_cli
import XCTest

/// SPEC-038 FR-CB9 (v0.3.61/v0.3.62, Related: #2462): the task-local request
/// route reaches the MLX thread scope only inside a build, a `mixed` build
/// without one fails closed, the startup assert and the NAX port. CPU only:
/// the route scope is a thread-local in the MLX core and needs no device.
final class SmallMRouteScopeTests: XCTestCase {
    override func invokeTest() {
        Device.withDefaultDevice(Device(.cpu)) {
            super.invokeTest()
        }
    }

    override class func setUp() {
        super.setUp()
        MLXTestDevice.pinProcessCPUDefaultWithoutMetallib()
    }

    func testBuildSetsTheMLXThreadRouteFromTheTaskRouteAndRestoresIt() async throws {
        let outside = currentSmallMRoute()
        XCTAssertEqual(outside, processSmallMRoute())
        for route in [macprovider_cli.SmallMRoute.rowInvariant, .stockOrder] {
            let seen = try await SmallMRouteScope.run(route) {
                await Task.yield()
                let inBuild = try SmallMRouteScope.build { currentSmallMRoute() }
                // The task route never leaks into the thread outside a build.
                XCTAssertEqual(currentSmallMRoute(), outside)
                return inBuild
            }
            XCTAssertEqual(seen, route.mlxRoute)
            XCTAssertEqual(currentSmallMRoute(), outside)
        }
        // Nested request routes: the inner one applies inside, the outer after.
        let nested = try await SmallMRouteScope.run(.stockOrder) {
            let inner = try await SmallMRouteScope.run(.rowInvariant) {
                try SmallMRouteScope.build { currentSmallMRoute() }
            }
            let outer = try SmallMRouteScope.build { currentSmallMRoute() }
            return (inner, outer)
        }
        XCTAssertEqual(nested.0, .rowInvariant)
        XCTAssertEqual(nested.1, .stockOrder)
        // A throwing build restores the thread route.
        struct Failure: Error {}
        try await SmallMRouteScope.run(.stockOrder) {
            XCTAssertThrowsError(try SmallMRouteScope.build { throw Failure() })
        }
        XCTAssertEqual(currentSmallMRoute(), outside)
    }

    func testMixedBuildWithoutARequestRouteFailsClosed() async throws {
        XCTAssertThrowsError(try SmallMRouteScope.build(mixed: true) { 1 }) { error in
            XCTAssertEqual(
                error as? ContinuousBatchSchedulerError,
                .unsupported(SmallMRouteScope.missingRouteCode)
            )
        }
        XCTAssertEqual(try SmallMRouteScope.build(mixed: false) { 1 }, 1)
        let scoped = try await SmallMRouteScope.run(.stockOrder) {
            try SmallMRouteScope.build(mixed: true) { currentSmallMRoute() }
        }
        XCTAssertEqual(scoped, .stockOrder)
    }

    func testProcessRouteMismatchIsTheStartupAssert() {
        // The test process runs the row-invariant route (env unset).
        XCTAssertEqual(processSmallMRoute(), .rowInvariant)
        XCTAssertNil(SmallMRouteScope.processRouteMismatch(applied: .rowInvariant))
        XCTAssertEqual(
            SmallMRouteScope.processRouteMismatch(applied: .stockOrder),
            "event=small_m_route action=mlx_process_route_mismatch applied=stock_order mlx=row_invariant"
        )
        XCTAssertEqual(
            SmallMRouteScope.processRouteMismatch(applied: .serialOnly),
            "event=small_m_route action=mlx_process_route_mismatch applied=serial_only mlx=row_invariant"
        )
    }

    func testNAXPortMatchesTheCoreRule() {
        let cases: [(String, Bool, Bool)] = [
            ("applegpu_g17s", true, true),
            ("applegpu_g17g", true, true),
            ("applegpu_g18d", true, true),
            ("applegpu_g17p", true, false),
            ("applegpu_g18p", true, true),
            ("applegpu_g16s", true, false),
            ("applegpu_g15d", true, false),
            ("applegpu_g13s", true, false),
            ("applegpu_g17s", false, false),
            ("Unknown", true, false),
            ("", true, false),
        ]
        for (architecture, os, expected) in cases {
            XCTAssertEqual(
                macprovider_cli.SmallMRoute.naxAvailable(architecture: architecture, osSupportsNAX: os),
                expected, "\(architecture) os=\(os)"
            )
        }
    }
}
