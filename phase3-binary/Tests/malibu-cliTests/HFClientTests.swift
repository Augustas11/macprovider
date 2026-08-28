import MacProviderCore
import XCTest

final class HFClientTests: XCTestCase {

    func testBuildsExpectedURL() async throws {
        let fetcher = RecordingFetcher(body: Data("[]".utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        _ = try await client.searchMLXCommunity(query: nil, limit: 25)

        let url = try XCTUnwrap(fetcher.lastURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.path, "/api/models")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Set(components.queryItems ?? [])
        XCTAssertTrue(items.contains(URLQueryItem(name: "author", value: "mlx-community")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "limit", value: "25")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "sort", value: "downloads")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "direction", value: "-1")))
        // No search param when query is nil.
        XCTAssertFalse(items.contains(where: { $0.name == "search" }))
    }

    func testAddsSearchParamWhenQueryProvided() async throws {
        let fetcher = RecordingFetcher(body: Data("[]".utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        _ = try await client.searchMLXCommunity(query: "qwen", limit: 5)

        let components = try XCTUnwrap(URLComponents(url: fetcher.lastURL!, resolvingAgainstBaseURL: false))
        let items = Set(components.queryItems ?? [])
        XCTAssertTrue(items.contains(URLQueryItem(name: "search", value: "qwen")))
    }

    func testSetsBearerHeaderWhenTokenSet() async throws {
        let fetcher = RecordingFetcher(body: Data("[]".utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!, token: "hf_secret")

        _ = try await client.searchMLXCommunity()

        XCTAssertEqual(fetcher.lastHeaders["Authorization"], "Bearer hf_secret")
        XCTAssertEqual(fetcher.lastHeaders["Accept"], "application/json")
    }

    func testOmitsBearerHeaderWhenTokenAbsent() async throws {
        let fetcher = RecordingFetcher(body: Data("[]".utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!, token: nil)

        _ = try await client.searchMLXCommunity()

        XCTAssertNil(fetcher.lastHeaders["Authorization"])
    }

    func testOmitsBearerHeaderWhenTokenIsEmpty() async throws {
        let fetcher = RecordingFetcher(body: Data("[]".utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!, token: "")

        _ = try await client.searchMLXCommunity()

        XCTAssertNil(fetcher.lastHeaders["Authorization"])
    }

    func testParsesSummaryList() async throws {
        let json = """
        [
          {"id":"mlx-community/Qwen2.5-7B-Instruct-4bit","tags":["mlx","safetensors"],"downloads":1234},
          {"id":"mlx-community/Llama-3.2-3B-Instruct-4bit","tags":["mlx"],"downloads":5678,"lastModified":"2026-01-01T00:00:00.000Z"}
        ]
        """
        let fetcher = RecordingFetcher(body: Data(json.utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        let summaries = try await client.searchMLXCommunity()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].id, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(summaries[0].downloads, 1234)
        XCTAssertEqual(summaries[1].tags, ["mlx"])
        XCTAssertEqual(summaries[1].lastModified, "2026-01-01T00:00:00.000Z")
    }

    func testTolerantToMissingOptionalFields() async throws {
        let json = #"[{"id":"mlx-community/Bare"}]"#
        let fetcher = RecordingFetcher(body: Data(json.utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        let summaries = try await client.searchMLXCommunity()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, "mlx-community/Bare")
        XCTAssertNil(summaries[0].tags)
        XCTAssertNil(summaries[0].downloads)
    }

    func testUnauthorizedMapsToNamedError() async {
        let fetcher = RecordingFetcher(body: Data(), status: 401)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        do {
            _ = try await client.searchMLXCommunity()
            XCTFail("expected unauthorized")
        } catch HFClientError.unauthorized {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRateLimitedMapsToNamedError() async {
        let fetcher = RecordingFetcher(body: Data(), status: 429)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        do {
            _ = try await client.searchMLXCommunity()
            XCTFail("expected rate limited")
        } catch HFClientError.rateLimited {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnexpectedStatusSurfacesCode() async {
        let fetcher = RecordingFetcher(body: Data(), status: 503)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        do {
            _ = try await client.searchMLXCommunity()
            XCTFail("expected status error")
        } catch HFClientError.httpStatus(let code) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDecodeFailureMapsToDecodeError() async {
        let fetcher = RecordingFetcher(body: Data("not json".utf8), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        do {
            _ = try await client.searchMLXCommunity()
            XCTFail("expected decode failure")
        } catch HFClientError.decode {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testZeroLimitReturnsEmptyWithoutFetch() async throws {
        let fetcher = RecordingFetcher(body: Data(), status: 200)
        let client = HFClient(fetcher: fetcher, baseURL: URL(string: "https://example.com")!)

        let summaries = try await client.searchMLXCommunity(limit: 0)
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertNil(fetcher.lastURL, "should not call fetcher with limit=0")
    }
}

// MARK: - Test helpers

private final class RecordingFetcher: HTTPFetcher, @unchecked Sendable {
    var body: Data
    var status: Int
    private(set) var lastURL: URL?
    private(set) var lastHeaders: [String: String] = [:]

    init(body: Data, status: Int) {
        self.body = body
        self.status = status
    }

    func fetch(url: URL, headers: [String: String]) async throws -> (Data, Int) {
        self.lastURL = url
        self.lastHeaders = headers
        return (body, status)
    }
}
