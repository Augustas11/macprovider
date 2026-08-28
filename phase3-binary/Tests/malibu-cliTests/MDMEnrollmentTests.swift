import Foundation
import MacProviderCore
import XCTest
@testable import malibu_cli

final class MDMEnrollmentTests: XCTestCase {

    // MARK: - parseMDMEnrollmentStatus

    func testParse_NotEnrolled() {
        let output = """
        Enrolled via DEP: No
        MDM enrollment: No
        """
        XCTAssertEqual(parseMDMEnrollmentStatus(output), .notEnrolled)
    }

    func testParse_EnrolledMacprovider_KnownHost() {
        let output = """
        Enrolled via DEP: No
        MDM enrollment: Yes (User Approved)
        MDM server: https://coordinator.malibu.tech/mdm/connect
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output),
            .enrolledMacprovider(serverURL: "https://coordinator.malibu.tech/mdm/connect")
        )
    }

    func testParse_EnrolledMacprovider_KnownSuffix() {
        let output = """
        MDM enrollment: Yes
        MDM server: https://custom.malibu.tech/mdm
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output),
            .enrolledMacprovider(serverURL: "https://custom.malibu.tech/mdm")
        )
    }

    func testParse_EnrolledForeignMDM() {
        let output = """
        Enrolled via DEP: No
        MDM enrollment: Yes (User Approved)
        MDM server: https://mdm.corporate.example.com/enroll
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output),
            .enrolledOtherMDM(serverURL: "https://mdm.corporate.example.com/enroll")
        )
    }

    func testParse_EnrolledMacprovider_ViaExpectedHost() {
        let output = """
        MDM enrollment: Yes
        MDM server: https://my-self-hosted.example.com/mdm/connect
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output, expectedHosts: ["my-self-hosted.example.com"]),
            .enrolledMacprovider(serverURL: "https://my-self-hosted.example.com/mdm/connect")
        )
    }

    func testParse_EnrolledForeignMDM_ExpectedHostDoesNotMatch() {
        let output = """
        MDM enrollment: Yes
        MDM server: https://other.example.com/mdm
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output, expectedHosts: ["mine.example.com"]),
            .enrolledOtherMDM(serverURL: "https://other.example.com/mdm")
        )
    }

    func testParse_DEPLineDoesNotTriggerEnrolled() {
        // "Enrolled via DEP: Yes" must NOT cause enrolled=true.
        let output = """
        Enrolled via DEP: Yes
        MDM enrollment: No
        """
        XCTAssertEqual(parseMDMEnrollmentStatus(output), .notEnrolled)
    }

    func testParse_EmptyOutput() {
        XCTAssertEqual(parseMDMEnrollmentStatus(""), .notEnrolled)
    }

    func testParse_MissingServerURLWhileEnrolled() {
        // Enrolled but no server line → report as foreign (unknown server).
        let output = "MDM enrollment: Yes"
        guard case .enrolledOtherMDM = parseMDMEnrollmentStatus(output) else {
            XCTFail("Expected enrolledOtherMDM when server URL is absent")
            return
        }
    }

    func testParse_CaseInsensitiveMDMLine() {
        let output = """
        MDM Enrollment: YES
        MDM Server: https://coordinator.malibu.tech/mdm
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output),
            .enrolledMacprovider(serverURL: "https://coordinator.malibu.tech/mdm")
        )
    }

    func testParse_UserApprovedSuffix() {
        // "Yes (User Approved)" must still be treated as enrolled.
        let output = """
        MDM enrollment: Yes (User Approved)
        MDM server: https://coordinator.malibu.tech/mdm
        """
        XCTAssertEqual(
            parseMDMEnrollmentStatus(output),
            .enrolledMacprovider(serverURL: "https://coordinator.malibu.tech/mdm")
        )
    }

    // MARK: - coordinatorHTTPBase (URL derivation)

    func testCoordinatorHTTPBase_WSS_DropsPath() {
        XCTAssertEqual(
            coordinatorHTTPBase("wss://coordinator.malibu.tech/ws"),
            "https://coordinator.malibu.tech"
        )
    }

    func testCoordinatorHTTPBase_HTTPS_DropsPath() {
        XCTAssertEqual(
            coordinatorHTTPBase("https://coordinator.malibu.tech/api"),
            "https://coordinator.malibu.tech"
        )
    }

    func testCoordinatorHTTPBase_WS_ToHTTP() {
        XCTAssertEqual(
            coordinatorHTTPBase("ws://localhost:8080/ws"),
            "http://localhost:8080"
        )
    }

    func testCoordinatorHTTPBase_WithQueryAndFragment() {
        XCTAssertEqual(
            coordinatorHTTPBase("wss://host.example.com/path?foo=bar#section"),
            "https://host.example.com"
        )
    }

    func testCoordinatorHTTPBase_PreservesPort() {
        XCTAssertEqual(
            coordinatorHTTPBase("wss://host.example.com:9443/ws"),
            "https://host.example.com:9443"
        )
    }

    func testEnrollEndpoint_Derived() {
        let base = coordinatorHTTPBase("wss://coordinator.malibu.tech/ws")
        let endpoint = URL(string: "\(base)/v1/enroll")
        XCTAssertEqual(endpoint?.absoluteString, "https://coordinator.malibu.tech/v1/enroll")
    }

    func testEnrollEndpoint_SelfHosted() {
        let base = coordinatorHTTPBase("wss://my-node.example.com:9443/coordinator")
        let endpoint = URL(string: "\(base)/v1/enroll")
        XCTAssertEqual(endpoint?.absoluteString, "https://my-node.example.com:9443/v1/enroll")
    }

    // MARK: - EnrollCommandRunner (unit, no network)

    private func makeConfig(coordinatorURL: String) throws -> AppConfig {
        try ConfigLoader.load(
            cli: CLIOverrides(coordinatorURL: coordinatorURL),
            environment: [:]
        )
    }

    func testEnrollRunner_AlreadyEnrolledMacprovider_PrintsStatusAndExits() async throws {
        let config = try makeConfig(coordinatorURL: "wss://coordinator.malibu.tech/ws")
        let runner = EnrollCommandRunner(
            config: config,
            openSystemSettings: false,
            checker: { _ in .enrolledMacprovider(serverURL: "https://coordinator.malibu.tech/mdm") },
            serialReader: { "C02TESTSERIAL" }
        )
        // Should not throw — already enrolled is an exit-0 idempotent case.
        try await runner.run()
    }

    func testEnrollRunner_ForeignMDM_Throws() async throws {
        let config = try makeConfig(coordinatorURL: "wss://coordinator.malibu.tech/ws")
        let runner = EnrollCommandRunner(
            config: config,
            openSystemSettings: false,
            checker: { _ in .enrolledOtherMDM(serverURL: "https://corporate.example.com") },
            serialReader: { "C02TESTSERIAL" }
        )
        do {
            try await runner.run()
            XCTFail("Expected throw for foreign MDM")
        } catch {
            // ExitCode thrown — expected.
        }
    }

    func testEnrollRunner_MissingSerial_Throws() async throws {
        let config = try makeConfig(coordinatorURL: "wss://coordinator.malibu.tech/ws")
        let runner = EnrollCommandRunner(
            config: config,
            openSystemSettings: false,
            checker: { _ in .notEnrolled },
            serialReader: { nil }
        )
        do {
            try await runner.run()
            XCTFail("Expected throw for missing serial")
        } catch {
            // ExitCode thrown — expected.
        }
    }
}
