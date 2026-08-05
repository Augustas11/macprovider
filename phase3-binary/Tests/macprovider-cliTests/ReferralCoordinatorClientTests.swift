import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ReferralCoordinatorClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        ReferralMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testEndpointsReplaceCoordinatorWebSocketPathAndRequireHTTPS() {
        let endpoints = ReferralCoordinatorClient.endpoints(from: "wss://coordinator.example/v2/provider?ignored=1")
        XCTAssertEqual(endpoints?.status.absoluteString, "https://coordinator.example/v1/provider/referrals")
        XCTAssertEqual(endpoints?.challenge.absoluteString, "https://coordinator.example/v1/provider/referrals/x/challenge")
        XCTAssertEqual(endpoints?.verify.absoluteString, "https://coordinator.example/v1/provider/referrals/x/verify")
        XCTAssertNil(ReferralCoordinatorClient.endpoints(from: "http://coordinator.example"))
        XCTAssertNil(ReferralCoordinatorClient.endpoints(from: "https://user:pass@coordinator.example"))
    }

    func testStatusUsesCLIOwnedBearerAndStrictlyDecodesSanitizedProjection() async throws {
        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-secret")
            return self.response(request, status: 200, body: self.statusJSON)
        }
        let client = try makeClient(session: session)
        let status = try await client.fetchStatus()
        XCTAssertEqual(status.socialState, "eligible")
        XCTAssertEqual(status.remaining, 1)
        XCTAssertEqual(status.inviteCode, "invite-1")
        XCTAssertTrue(status.joinLinksEnabled)
        XCTAssertEqual(status.socialBonusGrantsRemaining, 5)
        XCTAssertEqual(status.observedAt, "2027-01-15T08:00:00.000Z")
        XCTAssertNil(status.pendingChallenge)
    }

    func testStatusPreservesAuthoritativeBalanceWhenJoinLinksAreRolledBack() async throws {
        let body = statusJSON
            .replacingOccurrences(of: #""join_links_enabled":true"#, with: #""join_links_enabled":false"#)
            .replacingOccurrences(
                of: #","invite_url":"https://malibu.tech/j#/invite-1""#,
                with: ""
            )
        let client = try makeClient(session: mockSession { request in
            self.response(request, status: 200, body: body)
        })

        let status = try await client.fetchStatus()

        XCTAssertFalse(status.joinLinksEnabled)
        XCTAssertEqual(status.remaining, 1)
        XCTAssertEqual(status.inviteCode, "invite-1")
        XCTAssertNil(status.inviteURL)
    }

    func testStatusRejectsFractionalNegativeAndInconsistentCounts() async throws {
        for body in [
            statusJSON.replacingOccurrences(of: #""remaining":1"#, with: #""remaining":1.5"#),
            statusJSON.replacingOccurrences(of: #""remaining":1"#, with: #""remaining":-1"#),
            statusJSON.replacingOccurrences(of: #""remaining":1"#, with: #""remaining":0"#),
            statusJSON.replacingOccurrences(of: #""remaining":1"#, with: #""remaining":99"#),
        ] {
            let client = try makeClient(session: mockSession { request in
                self.response(request, status: 200, body: body)
            })
            do {
                _ = try await client.fetchStatus()
                XCTFail("invalid count accepted")
            } catch let error as ReferralCoordinatorClientError {
                XCTAssertEqual(error, .control(code: .invalidResponse, retryAfterSeconds: nil, terminalVerify: false))
            }
        }
    }

    func testStatusRejectsInviteOutsideCoordinatorDeclaredJoinBase() async throws {
        let body = statusJSON.replacingOccurrences(
            of: "https://malibu.tech/j#/invite-1",
            with: "https://phishing.example/j/invite-1"
        )
        let client = try makeClient(session: mockSession { request in
            self.response(request, status: 200, body: body)
        })
        do {
            _ = try await client.fetchStatus()
            XCTFail("cross-origin invite accepted")
        } catch let error as ReferralCoordinatorClientError {
            XCTAssertEqual(error, .control(code: .invalidResponse, retryAfterSeconds: nil, terminalVerify: false))
        }
    }

    func testChallengePersistsAndOpensRawSecretInsideCLIWhileSocketProjectionOmitsIt() async throws {
        let challenge = String(repeating: "a", count: 64)
        let share = "https://malibu.tech/j#/invite-1?c=\(challenge)"
        let intent = "https://twitter.com/intent/tweet?text=" + share.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let expires = now.addingTimeInterval(600)
        let challengeBody = """
        {"intent_url":"\(intent)","share_url":"\(share)","expires_at":"2027-01-15T08:10:00Z"}
        """
        let client = try makeClient(session: mockSession { request in
            self.response(
                request,
                status: 200,
                body: request.httpMethod == "GET" ? self.statusJSON : challengeBody
            )
        })
        let storeURL = temporaryStoreURL()
        let openedURL = LockedBox<String?>(nil)
        let service = ReferralCoordinatorService(
            client: client,
            store: ReferralChallengeStore(url: storeURL),
            now: { self.now },
            openIntent: { url in openedURL.set(url.absoluteString); return true }
        )
        let pending = try await service.challenge()
        XCTAssertEqual(openedURL.get(), intent)
        XCTAssertEqual(pending.expiresAt, "2027-01-15T08:10:00.000Z")

        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(String(decoding: try Data(contentsOf: storeURL), as: UTF8.self).contains(challenge))

        let frame = try ControlSocketCodec.encode(.referralChallengeResponse(expiresAt: pending.expiresAt))
        let wire = String(decoding: frame, as: UTF8.self)
        XCTAssertFalse(wire.contains(#""challenge""#))
        XCTAssertFalse(wire.contains(#""share_url""#))
        XCTAssertFalse(wire.contains(challenge))
        XCTAssertGreaterThan(expires, now)
    }

    func testMaturedStatusCanCreateFreshXChallenge() async throws {
        let challenge = String(repeating: "9", count: 64)
        let share = "https://malibu.tech/j#/invite-1?c=\(challenge)"
        let intent = "https://twitter.com/intent/tweet?text=" + share.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let challengeBody = """
        {"intent_url":"\(intent)","share_url":"\(share)","expires_at":"2027-01-15T08:10:00Z"}
        """
        let maturedStatus = statusJSON
            .replacingOccurrences(of: #""social_state":"eligible""#, with: #""social_state":"matured""#)
            .replacingOccurrences(of: #""bonus_capacity":0"#, with: #""bonus_capacity":2"#)
            .replacingOccurrences(of: #""remaining":1"#, with: #""remaining":3"#)
        let client = try makeClient(session: mockSession { request in
            self.response(
                request,
                status: 200,
                body: request.httpMethod == "GET" ? maturedStatus : challengeBody
            )
        })
        let openedURL = LockedBox<String?>(nil)
        let service = ReferralCoordinatorService(
            client: client,
            store: ReferralChallengeStore(url: temporaryStoreURL()),
            now: { self.now },
            openIntent: { url in openedURL.set(url.absoluteString); return true }
        )

        let pending = try await service.challenge()

        XCTAssertEqual(openedURL.get(), intent)
        XCTAssertEqual(pending.expiresAt, "2027-01-15T08:10:00.000Z")
    }

    func testStatusRestoresOnlySafePendingProjectionAcrossServiceRestart() async throws {
        let challenge = String(repeating: "b", count: 64)
        let intent = safeIntent(challenge: challenge)
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-1", payload: ReferralChallengePayload(
            challenge: challenge,
            inviteURL: "https://malibu.tech/j#/invite-1",
            intentURL: intent,
            expiresAt: now.addingTimeInterval(600),
            expiresAtWire: "2027-01-15T08:10:00.000Z"
        ))
        let client = try makeClient(session: mockSession { request in
            self.response(request, status: 200, body: self.statusJSON)
        })
        let restarted = ReferralCoordinatorService(
            client: client,
            store: store,
            now: { self.now },
            openIntent: { _ in true }
        )
        let status = try await restarted.status()
        XCTAssertEqual(status.pendingChallenge, ReferralPendingAdvocacy(
            expiresAt: "2027-01-15T08:10:00.000Z"
        ))

        let wire = String(decoding: try ControlSocketCodec.encode(.referralStatusResponse(status)), as: UTF8.self)
        XCTAssertFalse(wire.contains(challenge))
        XCTAssertFalse(wire.contains("share_url"))
    }

    func testCancelFailsClosedWhenDurableChallengeCannotBeRemoved() async throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try Data("retain".utf8).write(to: storeURL.appendingPathComponent("child"))
        let client = try makeClient(session: mockSession { request in
            self.response(request, status: 200, body: self.statusJSON)
        })
        let service = ReferralCoordinatorService(
            client: client,
            store: ReferralChallengeStore(url: storeURL),
            now: { self.now },
            openIntent: { _ in true }
        )

        do {
            _ = try await service.cancel()
            XCTFail("cancel acknowledged despite retained durable challenge state")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        }
    }

    func testStatusRestoresPendingProjectionAcrossRetryableStates() async throws {
        for state in ["eligible", "failed", "matured"] {
            let store = ReferralChallengeStore(url: temporaryStoreURL())
            try store.save(
                providerID: "provider-1",
                payload: payload(challenge: String(repeating: state == "failed" ? "4" : state == "matured" ? "5" : "6", count: 64))
            )
            let client = try makeClient(session: mockSession { request in
                self.response(
                    request,
                    status: 200,
                    body: self.statusJSON.replacingOccurrences(of: "eligible", with: state)
                )
            })
            let service = ReferralCoordinatorService(
                client: client,
                store: store,
                now: { self.now },
                openIntent: { _ in true }
            )

            let status = try await service.status()
            XCTAssertEqual(status.pendingChallenge, ReferralPendingAdvocacy(
                expiresAt: "2027-01-15T08:10:00.000Z"
            ), "state=\(state)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path), "state=\(state)")
        }
    }

    func testStatusClearsChallengeOutsideRetryableStates() async throws {
        for state in ["locked_until_first_serving", "pending", "revoked"] {
            let store = ReferralChallengeStore(url: temporaryStoreURL())
            try store.save(
                providerID: "provider-1",
                payload: payload(challenge: String(repeating: state == "pending" ? "7" : state == "revoked" ? "8" : "9", count: 64))
            )
            let client = try makeClient(session: mockSession { request in
                self.response(
                    request,
                    status: 200,
                    body: self.statusJSON.replacingOccurrences(of: "eligible", with: state)
                )
            })
            let service = ReferralCoordinatorService(
                client: client,
                store: store,
                now: { self.now },
                openIntent: { _ in true }
            )

            let status = try await service.status()
            XCTAssertNil(status.pendingChallenge, "state=\(state)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "state=\(state)")
        }
    }

    func testStatusClearsMaturedChallengeWhenRepeatGrantCapReached() async throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(
            providerID: "provider-1",
            payload: payload(challenge: String(repeating: "0", count: 64))
        )
        let cappedMatured = statusJSON
            .replacingOccurrences(of: #""social_state":"eligible""#, with: #""social_state":"matured""#)
            .replacingOccurrences(of: #""bonus_capacity":0"#, with: #""bonus_capacity":2"#)
            .replacingOccurrences(of: #""remaining":1"#, with: #""remaining":3"#)
            .replacingOccurrences(of: #""social_bonus_grants_remaining":5"#, with: #""social_bonus_grants_remaining":0"#)
        let client = try makeClient(session: mockSession { request in
            self.response(request, status: 200, body: cappedMatured)
        })
        let service = ReferralCoordinatorService(
            client: client,
            store: store,
            now: { self.now },
            openIntent: { _ in true }
        )

        let status = try await service.status()

        XCTAssertEqual(status.socialState, "matured")
        XCTAssertNil(status.pendingChallenge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testVerifyReadsChallengeInsideCLIAndClearsItAfterSuccess() async throws {
        let challenge = String(repeating: "c", count: 64)
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-1", payload: payload(challenge: challenge))
        let client = try makeClient(session: mockSession { request in
            XCTAssertEqual(request.url?.path, "/v1/provider/referrals/x/verify")
            let object = try JSONSerialization.jsonObject(with: try self.requestBody(request)) as! [String: String]
            XCTAssertEqual(object["challenge"], challenge)
            XCTAssertEqual(object["post_url"], "https://x.com/malibu/status/123")
            return self.response(request, status: 200, body: self.statusJSON.replacingOccurrences(of: "eligible", with: "pending"))
        })
        let service = ReferralCoordinatorService(client: client, store: store, now: { self.now }, openIntent: { _ in true })
        let result = try await service.verify(postURL: "https://x.com/malibu/status/123")
        XCTAssertEqual(result.socialState, "pending")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testPendingCoordinatorStatusClearsChallengeAfterVerifyResponseLoss() async throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-1", payload: payload(challenge: String(repeating: "c", count: 64)))
        let client = try makeClient(session: mockSession { request in
            self.response(
                request,
                status: 200,
                body: self.statusJSON.replacingOccurrences(of: "eligible", with: "pending")
            )
        })
        let service = ReferralCoordinatorService(client: client, store: store, now: { self.now }, openIntent: { _ in true })
        let status = try await service.status()
        XCTAssertEqual(status.socialState, "pending")
        XCTAssertNil(status.pendingChallenge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testTransientVerifyKeepsChallengeAndTerminalVerifyClearsIt() async throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-1", payload: payload(challenge: String(repeating: "d", count: 64)))
        let transientClient = try makeClient(session: mockSession { request in
            self.response(request, status: 503, body: #"{"error":"verification_unavailable"}"#)
        })
        let transientService = ReferralCoordinatorService(client: transientClient, store: store, now: { self.now }, openIntent: { _ in true })
        do { _ = try await transientService.verify(postURL: "https://x.com/a/status/1") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))

        let terminalClient = try makeClient(session: mockSession { request in
            self.response(request, status: 422, body: #"{"error":{"code":"post_not_verified","message":"raw detail"}}"#)
        })
        let terminalService = ReferralCoordinatorService(client: terminalClient, store: store, now: { self.now }, openIntent: { _ in true })
        do { _ = try await terminalService.verify(postURL: "https://x.com/a/status/1") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testProviderMismatchAndExpiryClearDurableChallenge() throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-a", payload: payload(challenge: String(repeating: "e", count: 64)))
        XCTAssertNil(try store.load(providerID: "provider-b", now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))

        try store.save(providerID: "provider-a", payload: ReferralChallengePayload(
            challenge: String(repeating: "f", count: 64),
            inviteURL: "https://malibu.tech/j#/invite-1",
            intentURL: "https://x.com/intent/tweet?text=x",
            expiresAt: now.addingTimeInterval(-1),
            expiresAtWire: "2027-01-15T07:59:59.000Z"
        ))
        XCTAssertNil(try store.load(providerID: "provider-a", now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testProviderMismatchFailsClosedWhenDurableChallengeCannotBeRemoved() throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-a", payload: payload(challenge: String(repeating: "e", count: 64)))
        let parent = store.url.deletingLastPathComponent()
        XCTAssertEqual(chmod(parent.path, S_IRUSR | S_IXUSR), 0)
        defer {
            _ = chmod(parent.path, S_IRWXU)
            try? FileManager.default.removeItem(at: parent)
        }

        XCTAssertThrowsError(try store.load(providerID: "provider-b", now: now))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testHTTPStatusesMapToSanitizedTypedErrors() async throws {
        let cases: [(Int, String?, ReferralCoordinatorClientError)] = [
            (401, nil, .control(code: .authenticationRequired, retryAfterSeconds: nil, terminalVerify: false)),
            (404, nil, .control(code: .featureUnavailable, retryAfterSeconds: nil, terminalVerify: false)),
            (429, "17", .control(code: .rateLimited, retryAfterSeconds: 17, terminalVerify: false)),
            (503, nil, .control(code: .temporarilyUnavailable, retryAfterSeconds: nil, terminalVerify: false)),
        ]
        for (status, retryAfter, expected) in cases {
            let client = try makeClient(session: mockSession { request in
                self.response(request, status: status, body: #"{"error":"server detail not forwarded"}"#, retryAfter: retryAfter)
            })
            do {
                _ = try await client.fetchStatus()
                XCTFail("status \(status) accepted")
            } catch let error as ReferralCoordinatorClientError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testRejectsRedirectedNonJSONAndOversizedResponses() async throws {
        let invalidHandlers: [(URLRequest) throws -> (HTTPURLResponse, Data)] = [
            { request in
                let redirected = HTTPURLResponse(
                    url: URL(string: "https://other.example/v1/provider/referrals")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (redirected, Data(self.statusJSON.utf8))
            },
            { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (response, Data(self.statusJSON.utf8))
            },
            { request in
                self.response(request, status: 200, body: String(repeating: "x", count: 32 * 1024 + 1))
            },
        ]
        for handler in invalidHandlers {
            let session = mockSession(handler)
            let client = try makeClient(session: session)
            do {
                _ = try await client.fetchStatus()
                XCTFail("unsafe response accepted")
            } catch let error as ReferralCoordinatorClientError {
                XCTAssertEqual(error, .control(code: .invalidResponse, retryAfterSeconds: nil, terminalVerify: false))
            }
        }
    }

    func testXPostURLValidationMatchesCoordinatorBoundary() {
        XCTAssertTrue(ReferralCoordinatorClient.isValidXPostURL("https://x.com/malibu/status/123"))
        XCTAssertFalse(ReferralCoordinatorClient.isValidXPostURL("https://www.x.com/malibu/status/123"))
        XCTAssertFalse(ReferralCoordinatorClient.isValidXPostURL("https://x.com:443/malibu/status/123"))
        XCTAssertFalse(ReferralCoordinatorClient.isValidXPostURL("https://x.com/malibu/status/not-a-number"))
        XCTAssertFalse(ReferralCoordinatorClient.isValidXPostURL("https://x.com/malibu/status/123?secret=x"))
    }

    func testChallengeRejectsShareForDifferentInviteCode() async throws {
        let challenge = String(repeating: "6", count: 64)
        let share = "https://malibu.tech/j#/other-code?c=\(challenge)"
        let intent = "https://twitter.com/intent/tweet?text="
            + share.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let challengeBody = """
        {"intent_url":"\(intent)","share_url":"\(share)","expires_at":"2027-01-15T08:10:00Z"}
        """
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        let opened = LockedBox(false)
        let client = try makeClient(session: mockSession { request in
            self.response(
                request,
                status: 200,
                body: request.httpMethod == "GET" ? self.statusJSON : challengeBody
            )
        })
        let service = ReferralCoordinatorService(
            client: client,
            store: store,
            now: { self.now },
            openIntent: { _ in opened.set(true); return true }
        )

        do {
            _ = try await service.challenge()
            XCTFail("mismatched invite accepted")
        } catch let error as ReferralCoordinatorClientError {
            XCTAssertEqual(error, .control(code: .invalidResponse, retryAfterSeconds: nil, terminalVerify: false))
        }
        XCTAssertFalse(opened.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testSocialRollbackClearsChallengeBeforeReopen() async throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-1", payload: payload(challenge: String(repeating: "7", count: 64)))
        let client = try makeClient(session: mockSession { request in
            self.response(
                request,
                status: 200,
                body: self.statusJSON.replacingOccurrences(
                    of: #""social_bonus_enabled":true"#,
                    with: #""social_bonus_enabled":false"#
                )
            )
        })
        let opened = LockedBox(false)
        let service = ReferralCoordinatorService(
            client: client,
            store: store,
            now: { self.now },
            openIntent: { _ in opened.set(true); return true }
        )

        do {
            _ = try await service.reopenChallenge()
            XCTFail("disabled challenge reopened")
        } catch let error as ReferralCoordinatorClientError {
            XCTAssertEqual(error, .control(code: .featureUnavailable, retryAfterSeconds: nil, terminalVerify: false))
        }
        XCTAssertFalse(opened.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testJoinOriginRotationClearsChallengeBeforeReopen() async throws {
        let store = ReferralChallengeStore(url: temporaryStoreURL())
        try store.save(providerID: "provider-1", payload: payload(challenge: String(repeating: "8", count: 64)))
        let rotatedStatus = statusJSON
            .replacingOccurrences(of: "https://malibu.tech/j", with: "https://join.example/j")
        let client = try makeClient(session: mockSession { request in
            self.response(request, status: 200, body: rotatedStatus)
        })
        let opened = LockedBox(false)
        let service = ReferralCoordinatorService(
            client: client,
            store: store,
            now: { self.now },
            openIntent: { _ in opened.set(true); return true }
        )

        do {
            _ = try await service.reopenChallenge()
            XCTFail("stale invite reopened")
        } catch let error as ReferralCoordinatorClientError {
            XCTAssertEqual(error, .control(code: .challengeUnavailable, retryAfterSeconds: nil, terminalVerify: false))
        }
        XCTAssertFalse(opened.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    private var statusJSON: String {
        #"{"campaign":"prebeta","join_base_url":"https://malibu.tech/j","social_state":"eligible","base_capacity":1,"configured_bonus_capacity":2,"bonus_capacity":0,"redemptions":0,"remaining":1,"first_serving_seen":true,"join_links_enabled":true,"social_bonus_enabled":true,"social_bonus_grants_remaining":5,"invite_code":"invite-1","invite_url":"https://malibu.tech/j#/invite-1"}"#
    }

    private func makeClient(session: URLSession) throws -> ReferralCoordinatorClient {
        try ReferralCoordinatorClient(
            coordinatorURL: "wss://coordinator.example/provider",
            providerID: "provider-1",
            bearerToken: "cli-secret",
            session: session,
            now: { self.now }
        )
    }

    private func mockSession(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        ReferralMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReferralMockURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    private func response(
        _ request: URLRequest,
        status: Int,
        body: String,
        retryAfter: String? = nil
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
            Data(body.utf8)
        )
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("referral-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pending.json")
    }

    private func payload(challenge: String) -> ReferralChallengePayload {
        ReferralChallengePayload(
            challenge: challenge,
            inviteURL: "https://malibu.tech/j#/invite-1",
            intentURL: safeIntent(challenge: challenge),
            expiresAt: now.addingTimeInterval(600),
            expiresAtWire: "2027-01-15T08:10:00.000Z"
        )
    }

    private func safeIntent(challenge: String) -> String {
        let share = "https://malibu.tech/j#/invite-1?c=\(challenge)"
        var components = URLComponents(string: "https://x.com/intent/tweet")!
        components.queryItems = [URLQueryItem(name: "text", value: "Join: \(share)")]
        return components.url!.absoluteString
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}

private final class ReferralMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
