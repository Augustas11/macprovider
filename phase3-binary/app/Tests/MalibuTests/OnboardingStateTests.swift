import XCTest
@testable import Malibu

final class OnboardingStateTests: XCTestCase {
    func testOnboardingStateUsesSnakeCaseAndFirstServingAt() throws {
        let state = OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: "p_abc",
            createdAt: Date(timeIntervalSince1970: 1_783_082_460),
            lastStage: "live",
            firstServingAt: Date(timeIntervalSince1970: 1_783_082_500),
            modelDownload: .init(
                modelID: "mlx/test",
                targetURL: URL(fileURLWithPath: "/tmp/model"),
                targetSHA256: "abc123",
                partialBytes: 42
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains(#""onboarding_schema_version""#))
        XCTAssertTrue(text.contains(#""provider_id""#))
        XCTAssertTrue(text.contains(#""created_at""#))
        XCTAssertTrue(text.contains(#""last_stage""#))
        XCTAssertTrue(text.contains(#""first_serving_at""#))
        XCTAssertTrue(text.contains(#""model_download""#))
        XCTAssertTrue(text.contains(#""partial_bytes""#))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(OnboardingState.self, from: data).providerID, "p_abc")
    }
}
