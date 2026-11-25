import Foundation
@testable import macprovider_cli
import XCTest

/// Malibu's prepare-catalog progress counts a file while it downloads, not
/// only once it lands in staging (the bar sat at 35 KB of a 16.87 GB model
/// while its first multi-GB shard transferred).
final class HFDownloadInFlightBytesTests: XCTestCase {
    func testDelegateReportsWrittenBytesUntilItIsReleased() {
        let tracker = HFDownloadInFlightBytes()
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/model.safetensors")!)
        var delegate: BoundedHFAssetDownloadDelegate? = BoundedHFAssetDownloadDelegate(maximumBytes: 10_000, inFlight: tracker)
        delegate?.urlSession(URLSession.shared, downloadTask: task, didWriteData: 1_000, totalBytesWritten: 1_000, totalBytesExpectedToWrite: 10_000)
        delegate?.urlSession(URLSession.shared, downloadTask: task, didWriteData: 2_500, totalBytesWritten: 3_500, totalBytesExpectedToWrite: 10_000)
        XCTAssertEqual(tracker.total, 3_500)

        let other = BoundedHFAssetDownloadDelegate(maximumBytes: 10_000, inFlight: tracker)
        other.urlSession(URLSession.shared, downloadTask: task, didWriteData: 700, totalBytesWritten: 700, totalBytesExpectedToWrite: 10_000)
        XCTAssertEqual(tracker.total, 4_200)

        delegate = nil
        XCTAssertEqual(tracker.total, 700)
        withExtendedLifetime(other) {}
    }

    func testRecordedBytesNeverExceedTheSignedMaximum() {
        let tracker = HFDownloadInFlightBytes()
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/model.safetensors")!)
        let delegate = BoundedHFAssetDownloadDelegate(maximumBytes: 1_000, inFlight: tracker)
        delegate.urlSession(URLSession.shared, downloadTask: task, didWriteData: 5_000, totalBytesWritten: 5_000, totalBytesExpectedToWrite: -1)
        XCTAssertEqual(tracker.total, 1_000)
        XCTAssertTrue(delegate.exceededLimit)
    }
}
