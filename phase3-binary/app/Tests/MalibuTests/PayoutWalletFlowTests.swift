import Network
import XCTest
@testable import Malibu

final class PayoutWalletFlowTests: XCTestCase {
    func testNonceIs0xPrefixed32Bytes() throws {
        let nonce = try PayoutWalletFlow.randomNonceHex()
        XCTAssertTrue(nonce.hasPrefix("0x"))
        XCTAssertEqual(nonce.count, 2 + 64)
        let hex = nonce.dropFirst(2)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
    }

    func testStateIs16BytesHex() throws {
        let state = try PayoutWalletFlow.randomState()
        XCTAssertEqual(state.count, 32)
        XCTAssertTrue(state.allSatisfy { $0.isHexDigit })
    }

    func testValidateCallbackAcceptsWellFormedPayload() {
        let address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        let nonce = "0x" + String(repeating: "ab", count: 32)
        let sig = "0x" + String(repeating: "cd", count: 65)
        let payload = PayoutSignedPayload(
            address: address,
            nonce: nonce,
            tsUtc: 1_719_234_896,
            signature: sig,
            state: "deadbeef"
        )
        XCTAssertTrue(
            PayoutWalletFlow.validateCallback(
                payload: payload,
                expectedState: "deadbeef",
                expectedNonce: nonce,
                expectedTsUtc: 1_719_234_896
            )
        )
    }

    func testValidateCallbackRejectsStateMismatchAndBadLengths() {
        let nonce = "0x" + String(repeating: "11", count: 32)
        let good = PayoutSignedPayload(
            address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            nonce: nonce,
            tsUtc: 10,
            signature: "0x" + String(repeating: "22", count: 65),
            state: "aaa"
        )
        XCTAssertFalse(
            PayoutWalletFlow.validateCallback(
                payload: good,
                expectedState: "bbb",
                expectedNonce: nonce,
                expectedTsUtc: 10
            )
        )
        let shortSig = PayoutSignedPayload(
            address: good.address,
            nonce: nonce,
            tsUtc: 10,
            signature: "0xdead",
            state: "aaa"
        )
        XCTAssertFalse(
            PayoutWalletFlow.validateCallback(
                payload: shortSig,
                expectedState: "aaa",
                expectedNonce: nonce,
                expectedTsUtc: 10
            )
        )
    }

    func testTsUtcPrefersServerWithinSkew() {
        let server: Int64 = 1_700_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(server + 30))
        XCTAssertEqual(PayoutWalletFlow.tsUtc(serverTsUTC: server, now: now), UInt64(server))
        let far = Date(timeIntervalSince1970: TimeInterval(server + 600))
        XCTAssertEqual(
            PayoutWalletFlow.tsUtc(serverTsUTC: server, now: far),
            UInt64(far.timeIntervalSince1970.rounded())
        )
    }

    func testTruncateAddress() {
        let full = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        XCTAssertEqual(PayoutWalletFlow.truncateAddress(full), "0x7099…79C8")
    }

    func testRegistrationStoreRoundTrip() {
        PayoutRegistrationStore.clear()
        defer { PayoutRegistrationStore.clear() }
        PayoutRegistrationStore.save(
            address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            pendingUntilUTC: "2026-01-09T00:00:00Z"
        )
        let loaded = PayoutRegistrationStore.load()
        XCTAssertEqual(loaded?.address, "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
        XCTAssertEqual(loaded?.pendingUntilUTC, "2026-01-09T00:00:00Z")
    }

    // MARK: - M1: exact structural ts_utc decoding (JSONDecoder)

    func testCallbackBodyDecodesTimestampExactly() {
        func decode(_ tsToken: String) -> PayoutCallbackBody? {
            let json = #"{"address":"0xabc","nonce":"0x01","ts_utc":\#(tsToken),"signature":"0x02","state":"s"}"#
            return try? JSONDecoder().decode(PayoutCallbackBody.self, from: Data(json.utf8))
        }
        // Rejected: negative, fractional (L1), 2^64 overflow (M1),
        // huge-exponent, non-numeric, boolean.
        XCTAssertNil(decode("-1"))
        XCTAssertNil(decode("1719234896.9"))
        XCTAssertNil(decode("18446744073709551616")) // 2^64 — can no longer wrap to 0
        XCTAssertNil(decode("1e30"))
        XCTAssertNil(decode("\"not-a-number\""))
        XCTAssertNil(decode("true"))
        // Accepted: UInt64.max, an integral-valued double, and a plain int.
        XCTAssertEqual(decode("18446744073709551615")?.tsUtc, UInt64.max)
        XCTAssertEqual(decode("42.0")?.tsUtc, 42)
        XCTAssertEqual(decode("1719234896")?.tsUtc, 1_719_234_896)
    }

    // MARK: - FIX-1: loopback-only bind

    func testLoopbackParametersPinToLoopback() {
        let params = LoopbackCaptureServer.loopbackParameters()
        XCTAssertEqual(params.requiredInterfaceType, .loopback)
        guard case let .hostPort(host, _)? = params.requiredLocalEndpoint else {
            return XCTFail("requiredLocalEndpoint is not a hostPort")
        }
        XCTAssertEqual("\(host)", "127.0.0.1")
    }

    // MARK: - FIX-9 loopback capture integration

    private func makeSignerDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("payout-signer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<html>signer</html>".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("signer.html"))
        try "/* ethers */".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("ethers.min.js"))
        return dir
    }

    private struct CB {
        static let state = "deadbeefcafe0001"
        static let nonce = "0x" + String(repeating: "ab", count: 32)
        static let ts: UInt64 = 1_719_234_896
        static let address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        static let sig = "0x" + String(repeating: "cd", count: 65)
    }

    private func validBody() -> [String: Any] {
        [
            "address": CB.address, "nonce": CB.nonce,
            "ts_utc": CB.ts, "signature": CB.sig, "state": CB.state,
        ]
    }

    /// POST a raw JSON body to 127.0.0.1:port/path; returns HTTP status.
    @discardableResult
    private func post(port: UInt16, path: String, jsonObject: Any) async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (_, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// POST a RAW body string (lets us send number tokens like 2^64 that a
    /// Swift dictionary cannot represent).
    @discardableResult
    private func postRaw(port: UInt16, path: String, body: String) async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (_, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func makeStartedServer() async throws -> (LoopbackCaptureServer, UInt16) {
        let server = LoopbackCaptureServer(resourceDirectory: try makeSignerDir())
        server.expect(state: CB.state, nonce: CB.nonce, tsUtc: CB.ts)
        try await server.start()
        XCTAssertNotEqual(server.port, 0, "listener must publish a loopback port")
        return (server, server.port)
    }

    func testValidCallbackResolvesOneShot() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        async let captured = server.awaitCallback(timeout: 5)
        let code = try await post(port: port, path: "/cb", jsonObject: validBody())
        XCTAssertEqual(code, 200)
        let payload = try await captured
        XCTAssertEqual(payload.address, CB.address)
        XCTAssertEqual(payload.state, CB.state)
    }

    func testWrongStateRejectedThenValidResolves() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        async let captured = server.awaitCallback(timeout: 5)
        var bad = validBody()
        bad["state"] = "0000000000000000"
        let badCode = try await post(port: port, path: "/cb", jsonObject: bad)
        XCTAssertEqual(badCode, 400, "wrong-state callback must be rejected")
        // Server kept listening → a later valid callback resolves.
        let okCode = try await post(port: port, path: "/cb", jsonObject: validBody())
        XCTAssertEqual(okCode, 200)
        let payload = try await captured
        XCTAssertEqual(payload.state, CB.state)
    }

    func testNegativeTsCallbackRejectedNoCrashThenValidResolves() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        async let captured = server.awaitCallback(timeout: 5)
        // FIX-2: ts_utc:-1 must NOT crash the process; it is rejected.
        var neg = validBody()
        neg["ts_utc"] = -1
        let negCode = try await post(port: port, path: "/cb", jsonObject: neg)
        XCTAssertEqual(negCode, 400)
        var huge = validBody()
        huge["ts_utc"] = 1e30
        let hugeCode = try await post(port: port, path: "/cb", jsonObject: huge)
        XCTAssertEqual(hugeCode, 400)
        var str = validBody()
        str["ts_utc"] = "not-a-number"
        let strCode = try await post(port: port, path: "/cb", jsonObject: str)
        XCTAssertEqual(strCode, 400)
        // M1: 2^64 (a token a Swift dict can't hold) must be rejected, not
        // wrapped to 0. Sent as a raw JSON body.
        let overflowBody = #"{"address":"\#(CB.address)","nonce":"\#(CB.nonce)","ts_utc":18446744073709551616,"signature":"\#(CB.sig)","state":"\#(CB.state)"}"#
        let overflowCode = try await postRaw(port: port, path: "/cb", body: overflowBody)
        XCTAssertEqual(overflowCode, 400)
        // Still listening.
        let okCode = try await post(port: port, path: "/cb", jsonObject: validBody())
        XCTAssertEqual(okCode, 200)
        let payload = try await captured
        XCTAssertEqual(payload.tsUtc, CB.ts)
    }

    func testWrongPathAndMethodRejected() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        async let captured = server.awaitCallback(timeout: 5)
        // Wrong path.
        let wrongPathCode = try await post(port: port, path: "/not-cb", jsonObject: validBody())
        XCTAssertEqual(wrongPathCode, 404)
        // Wrong method (GET /cb serves nothing → 404).
        let getURL = URL(string: "http://127.0.0.1:\(port)/cb")!
        let (_, getResp) = try await URLSession(configuration: .ephemeral).data(from: getURL)
        XCTAssertEqual((getResp as? HTTPURLResponse)?.statusCode, 404)
        // Valid still resolves.
        let okCode = try await post(port: port, path: "/cb", jsonObject: validBody())
        XCTAssertEqual(okCode, 200)
        _ = try await captured
    }

    func testTimeoutTearsDownCleanly() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        XCTAssertNotEqual(port, 0)
        do {
            _ = try await server.awaitCallback(timeout: 0.3)
            XCTFail("expected timeout")
        } catch let e as PayoutWalletFlowError {
            XCTAssertEqual(e, .timedOut)
        }
        // Idempotent stop after a resolved one-shot must not crash.
        server.stop()
    }

    func testOversizedBodyRejected() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        var big = validBody()
        big["padding"] = String(repeating: "A", count: 40 * 1024) // > maxContentLength
        let code = try await post(port: port, path: "/cb", jsonObject: big)
        XCTAssertEqual(code, 413, "oversized body must be rejected")
    }

    // M1: two concurrently-valid callbacks must claim the one-shot exactly
    // once. Pre-fix, both flushed a 200 (double-accept race); post-fix only
    // the first-in-queue is accepted and the flow resolves to that wallet.
    func testConcurrentValidCallbacksClaimExactlyOnce() async throws {
        let (server, port) = try await makeStartedServer()
        defer { server.stop() }
        async let captured = server.awaitCallback(timeout: 5)

        let addrA = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        let addrB = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        func body(_ a: String) -> [String: Any] {
            ["address": a, "nonce": CB.nonce, "ts_utc": CB.ts, "signature": CB.sig, "state": CB.state]
        }
        // Failure-tolerant: the loser is EITHER refused 409 (it reached the
        // claimed gate) OR its connection is dropped when the server tears
        // down after the winner (URLSession throws → sentinel -1). Both
        // outcomes prove there was no second acceptance.
        func tolerantPost(_ a: String) async -> Int {
            (try? await post(port: port, path: "/cb", jsonObject: body(a))) ?? -1
        }
        async let ra = tolerantPost(addrA)
        async let rb = tolerantPost(addrB)
        let codeA = await ra
        let codeB = await rb

        // Exactly one gets 200; the other must NOT be a second 200.
        XCTAssertTrue((codeA == 200) != (codeB == 200),
                      "exactly one callback may be accepted; got \(codeA)/\(codeB)")
        XCTAssertNotEqual(codeA == 200 ? codeB : codeA, 200, "one-shot double-accepted")

        // The resolved wallet is whichever POST won the claim.
        let payload = try await captured
        let winner = codeA == 200 ? addrA : addrB
        XCTAssertEqual(payload.address, winner)
    }

    // M3: a listener that fails to bind must leave nothing open. We occupy a
    // loopback port with a healthy server, then force a second server onto
    // the same port without reuse so its bind fails (EADDRINUSE).
    func testStartFailureLeavesNothingOpen() async throws {
        let holder = LoopbackCaptureServer(resourceDirectory: try makeSignerDir())
        try await holder.start()
        defer { holder.stop() }
        let busyPort = holder.port
        XCTAssertNotEqual(busyPort, 0)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: busyPort)!)
        params.requiredInterfaceType = .loopback

        let server = LoopbackCaptureServer(resourceDirectory: try makeSignerDir())
        do {
            try await server.start(parametersOverride: params)
            XCTFail("expected start to fail on an in-use port")
        } catch let error as PayoutWalletFlowError {
            guard case .loopbackFailed = error else {
                return XCTFail("expected loopbackFailed, got \(error)")
            }
        }
        XCTAssertEqual(server.port, 0)
        XCTAssertFalse(server.isListenerActiveForTest,
                       "a failed listener must be torn down, not retained")
        server.stop() // idempotent after a failed start
    }

    // H1: a listener that fails AFTER readiness (while awaitCallback is
    // waiting) must resume the caller with an error promptly — not hang
    // until (or past) the timeout — and tear everything down.
    func testPostReadyListenerFailureResumesAwaitNoHang() async throws {
        let (server, _) = try await makeStartedServer()
        defer { server.stop() }
        // Long timeout: the flow must be resolved by the failure routing,
        // NOT by the timeout (which teardown cancels).
        async let captured = server.awaitCallback(timeout: 120)
        // Let awaitCallback register its continuation, then inject the
        // post-ready failure through the same routing NWListener uses.
        try await Task.sleep(nanoseconds: 100_000_000)
        server.injectPostReadyListenerFailureForTest()
        do {
            _ = try await captured
            XCTFail("expected a failure, not a value")
        } catch let error as PayoutWalletFlowError {
            guard case .loopbackFailed = error else {
                return XCTFail("expected loopbackFailed, got \(error)")
            }
        }
        XCTAssertFalse(server.isListenerActiveForTest,
                       "post-ready failure must tear the listener down")
    }
}
