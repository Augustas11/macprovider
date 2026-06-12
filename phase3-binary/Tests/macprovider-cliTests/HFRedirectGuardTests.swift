import MacProviderCore
import XCTest

final class HFRedirectGuardTests: XCTestCase {

    // Helper: drive the delegate method with a real-ish URLSessionTask and
    // capture what URL it would forward to (or nil to refuse).
    private func decide(originalURL: URL, redirectTo newURL: URL) -> URL? {
        let session = URLSession.shared
        // Construct a task but never resume; we just need a URLSessionTask
        // with an originalRequest the delegate can read.
        let task = session.dataTask(with: originalURL)
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": newURL.absoluteString]
        )!
        let newRequest = URLRequest(url: newURL)

        let guardDelegate = HFRedirectGuard()
        var captured: URL? = nil
        let waiter = expectation(description: "completion fired")
        guardDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: newRequest,
            completionHandler: { req in
                captured = req?.url
                waiter.fulfill()
            }
        )
        wait(for: [waiter], timeout: 1)
        // Make sure the task doesn't linger.
        task.cancel()
        return captured
    }

    func testAllowsSameOriginRedirect() {
        let allowed = decide(
            originalURL: URL(string: "https://huggingface.co/api/models")!,
            redirectTo: URL(string: "https://huggingface.co/api/models/")!
        )
        XCTAssertEqual(allowed?.host, "huggingface.co")
    }

    func testRefusesDifferentHost() {
        let allowed = decide(
            originalURL: URL(string: "https://huggingface.co/api/models")!,
            redirectTo: URL(string: "https://evil.example.com/steal")!
        )
        XCTAssertNil(allowed)
    }

    func testRefusesSubdomainSwap() {
        // Wildcard-subdomain leak attempt — cdn.huggingface.co is a
        // different host than huggingface.co for our purposes.
        let allowed = decide(
            originalURL: URL(string: "https://huggingface.co/api/models")!,
            redirectTo: URL(string: "https://cdn.huggingface.co/api/models")!
        )
        XCTAssertNil(allowed)
    }

    func testRefusesHTTPSToHTTPDowngrade() {
        let allowed = decide(
            originalURL: URL(string: "https://huggingface.co/api/models")!,
            redirectTo: URL(string: "http://huggingface.co/api/models")!
        )
        XCTAssertNil(allowed)
    }

    func testRefusesSchemeChange() {
        // Other-scheme redirect (data:, file:) should also fail.
        let allowed = decide(
            originalURL: URL(string: "https://huggingface.co/api/models")!,
            redirectTo: URL(string: "file:///etc/passwd")!
        )
        XCTAssertNil(allowed)
    }
}
