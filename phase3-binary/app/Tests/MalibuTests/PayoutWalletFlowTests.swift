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

    // MARK: - FIX-2: safe untrusted JSON→UInt64 (no trap)

    func testJSONUInt64RejectsNegativeHugeAndNonNumeric() throws {
        // Drive values through JSONSerialization so they are the exact
        // NSNumber / NSString / CFBoolean types the callback decoder
        // sees in production.
        func fromJSON(_ raw: String) throws -> Any? {
            let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            return obj?["v"]
        }
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":-1}"#)))
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":-9999999}"#)))
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":1e30}"#)))          // overflow
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":"not-a-number"}"#)))
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":true}"#)))          // bool ≠ ts
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(nil))
        // NaN cannot be represented in JSON; assert the NSNumber path directly.
        XCTAssertNil(PayoutWalletFlow.jsonUInt64(NSNumber(value: Double.nan)))
        // Valid values still decode.
        XCTAssertEqual(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":0}"#)), 0)
        XCTAssertEqual(PayoutWalletFlow.jsonUInt64(try fromJSON(#"{"v":1719234896}"#)), 1_719_234_896)
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
}
