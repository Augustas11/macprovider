import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-023 §3.8 (SPEC-023-R028): the signed release manifest. Every key here
/// is a throwaway test key generated per test.
final class CatalogReleaseManifestTests: XCTestCase {
    private let keyID = "streamvc-autotune-static-test"
    private let baseURL = URL(string: "https://example.invalid")!
    private let demand = Data(#"{"demand":"bytes"}"#.utf8)
    private let candidates = Data(#"{"candidate":"bytes"}"#.utf8)

    func testVerifiedManifestAuthenticatesBoundBodiesByDigest() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try signedManifest(signer: signer)
        let verified = try XCTUnwrap(CatalogReleaseManifest.verified(
            manifestData: manifest, signatureData: signature, trustedPublicKeys: keyring(signer)
        ))
        XCTAssertEqual(verified.releaseID, "release-a")
        XCTAssertEqual(verified.authenticate(routeName: "demand-rank", body: demand), .authenticated(signerKeyID: keyID))
        XCTAssertEqual(verified.authenticate(routeName: "demand-rank", body: Data("other".utf8)), .mismatch)
        XCTAssertEqual(verified.authenticate(routeName: "catalog-artifacts", body: demand), .unbound)
        XCTAssertEqual(verified.authenticate(routeName: "unknown-route", body: demand), .unbound)
    }

    func testManifestRejectsBadSignatureUntrustedKeyAndForeignSigners() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try signedManifest(signer: signer)
        var tampered = manifest
        tampered.append(UInt8(ascii: " "))
        XCTAssertNil(CatalogReleaseManifest.verified(manifestData: tampered, signatureData: signature, trustedPublicKeys: keyring(signer)))
        XCTAssertNil(CatalogReleaseManifest.verified(
            manifestData: manifest, signatureData: signature,
            trustedPublicKeys: keyring(Curve25519.Signing.PrivateKey())
        ))
        // A static feed bound to another signer cannot ride on this signature.
        let (foreign, foreignSignature) = try signedManifest(signer: signer, demandSigner: "other-key")
        XCTAssertNil(CatalogReleaseManifest.verified(manifestData: foreign, signatureData: foreignSignature, trustedPublicKeys: keyring(signer)))
        // Closed document: an unknown top-level field is refused.
        let (extra, extraSignature) = try signedManifest(signer: signer, extraField: true)
        XCTAssertNil(CatalogReleaseManifest.verified(manifestData: extra, signatureData: extraSignature, trustedPublicKeys: keyring(signer)))
    }

    func testBoundFeedSkipsItsSidecar() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try signedManifest(signer: signer)
        let recorder = FetchRecorder(routes: [
            "/v1/catalog-release": manifest,
            "/v1/catalog-release.sig": signature,
        ])
        let inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
        let first = await inputs.authenticatedSigner(name: "demand-rank", body: demand, baseURL: baseURL)
        let second = await inputs.authenticatedSigner(name: "autotune-candidates", body: candidates, baseURL: baseURL)
        XCTAssertEqual(first, keyID)
        XCTAssertEqual(second, keyID)
        XCTAssertFalse(recorder.paths.contains { $0.hasSuffix(".json.sig") || $0 == "/v1/demand-rank.sig" })
        XCTAssertFalse(recorder.paths.contains("/v1/autotune-candidates.sig"), "a manifest-bound feed skips its sidecar")
        XCTAssertEqual(recorder.paths.filter { $0 == "/v1/catalog-release" }.count, 1, "one manifest fetch per load")
    }

    func testBoundDigestMismatchIsAnIntegrityFailureEvenWithAValidSidecar() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try signedManifest(signer: signer)
        let other = Data(#"{"demand":"other"}"#.utf8)
        let recorder = FetchRecorder(routes: [
            "/v1/catalog-release": manifest,
            "/v1/catalog-release.sig": signature,
            "/v1/demand-rank.sig": sidecar(for: other, signer: signer),
        ])
        let inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
        let signerKeyID = await inputs.authenticatedSigner(name: "demand-rank", body: other, baseURL: baseURL)
        XCTAssertNil(signerKeyID)
        XCTAssertFalse(recorder.paths.contains("/v1/demand-rank.sig"))
    }

    func testAbsentOrUnverifiedManifestFallsBackToPerFeedSidecar() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, _) = try signedManifest(signer: signer)
        let forged = sidecar(for: Data("not the manifest".utf8), signer: signer)
        for routes in [
            ["/v1/demand-rank.sig": sidecar(for: demand, signer: signer)],
            ["/v1/catalog-release": manifest, "/v1/catalog-release.sig": forged, "/v1/demand-rank.sig": sidecar(for: demand, signer: signer)],
        ] {
            let recorder = FetchRecorder(routes: routes)
            let inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
            let signerKeyID = await inputs.authenticatedSigner(name: "demand-rank", body: demand, baseURL: baseURL)
            XCTAssertEqual(signerKeyID, keyID)
            XCTAssertTrue(recorder.paths.contains("/v1/demand-rank.sig"))
        }
        // Without the manifest, a bad per-feed signature still fails.
        let recorder = FetchRecorder(routes: ["/v1/demand-rank.sig": forged])
        let inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
        let signerKeyID = await inputs.authenticatedSigner(name: "demand-rank", body: demand, baseURL: baseURL)
        XCTAssertNil(signerKeyID)
    }

    func testNativeMTPAdmissionFeedIsNotManifestBound() throws {
        XCTAssertNil(CatalogReleaseManifest.boundFeedNames["native-mtp-admission"])
        XCTAssertFalse(CatalogReleaseManifest.boundFeedNames.values.contains("native-mtp-admission.json"))
    }

    func testOversizedManifestIsRejectedAndFallsBackToSidecar() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try signedManifest(signer: signer, trailingPadding: CatalogReleaseManifest.maxManifestBytes)
        XCTAssertGreaterThan(manifest.count, CatalogReleaseManifest.maxManifestBytes)
        // Well signed, so the size cap alone refuses it.
        let recorder = FetchRecorder(routes: [
            "/v1/catalog-release": manifest,
            "/v1/catalog-release.sig": signature,
            "/v1/demand-rank.sig": sidecar(for: demand, signer: signer),
        ])
        let inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
        let signerKeyID = await inputs.authenticatedSigner(name: "demand-rank", body: demand, baseURL: baseURL)
        XCTAssertEqual(signerKeyID, keyID)
        XCTAssertTrue(recorder.paths.contains("/v1/demand-rank.sig"), "an oversized manifest leaves feeds on their sidecars")
    }

    func testStreamingManifestFetchIsCappedAndOversizedBodyIsRejected() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try signedManifest(signer: signer)
        let (oversized, oversizedSignature) = try signedManifest(signer: signer, trailingPadding: CatalogReleaseManifest.maxManifestBytes)
        let caps = CapRecorder()
        for (body, sig, expected) in [(manifest, signature, keyID as String?), (oversized, oversizedSignature, nil)] {
            let recorder = FetchRecorder(routes: [:])
            var inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
            inputs.releaseManifestFetch = { url, maxBytes in
                caps.record(url.path, maxBytes)
                let payload = url.path.hasSuffix(".sig") ? sig : body
                return NativeMTPAdmissionFeed.FetchResponse(statusCode: 200, body: payload, redirected: false)
            }
            let signerKeyID = await inputs.authenticatedSigner(name: "demand-rank", body: demand, baseURL: baseURL)
            XCTAssertEqual(signerKeyID, expected)
            XCTAssertFalse(recorder.paths.contains("/v1/catalog-release"), "the streaming fetch carries the manifest")
        }
        XCTAssertEqual(caps.caps["/v1/catalog-release"], CatalogReleaseManifest.maxManifestBytes)
        XCTAssertEqual(caps.caps["/v1/catalog-release.sig"], CatalogReleaseManifest.maxSignatureBytes)
    }

    func testDefaultInputsStreamTheManifestUntilFetchIsReplaced() {
        var inputs = AutotuneStaticInputs()
        XCTAssertNotNil(inputs.releaseManifestFetch)
        inputs.fetch = { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertNil(inputs.releaseManifestFetch)
        XCTAssertNil(AutotuneStaticInputs(fetch: { _ in Data() }).releaseManifestFetch)
    }

    func testCachedManifestIsRefetchedOnceAfterARelease() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let (oldManifest, oldSignature) = try signedManifest(signer: signer)
        let newDemand = Data(#"{"demand":"release-b"}"#.utf8)
        let (newManifest, newSignature) = try signedManifest(signer: signer, demandBody: newDemand)
        let recorder = FetchRecorder(routes: [
            "/v1/catalog-release": oldManifest,
            "/v1/catalog-release.sig": oldSignature,
        ])
        let inputs = AutotuneStaticInputs(fetch: recorder.fetch, trustedPublicKeys: keyring(signer))
        let cachedFirst = await inputs.authenticatedSigner(name: "demand-rank", body: demand, baseURL: baseURL)
        XCTAssertEqual(cachedFirst, keyID)
        recorder.set(["/v1/catalog-release": newManifest, "/v1/catalog-release.sig": newSignature])
        let afterRollover = await inputs.authenticatedSigner(name: "demand-rank", body: newDemand, baseURL: baseURL)
        XCTAssertEqual(afterRollover, keyID)
        XCTAssertEqual(recorder.paths.filter { $0 == "/v1/catalog-release" }.count, 2)
    }

    // MARK: - Helpers

    private func keyring(_ signer: Curve25519.Signing.PrivateKey) -> [String: String] {
        [keyID: signer.publicKey.rawRepresentation.base64EncodedString()]
    }

    private func sidecar(for payload: Data, signer: Curve25519.Signing.PrivateKey) -> Data {
        let signature = try! signer.signature(for: payload).base64EncodedString()
        return Data(#"{"alg":"ed25519","key_id":"\#(keyID)","signature":"\#(signature)"}"#.utf8)
    }

    private func entry(_ body: Data, signer: String) -> [String: Any] {
        ["bytes": body.count, "sha256": CatalogReleaseManifest.sha256Hex(body), "signer_key_id": signer, "version": "release-a"]
    }

    private func signedManifest(
        signer: Curve25519.Signing.PrivateKey,
        demandBody: Data? = nil,
        demandSigner: String? = nil,
        extraField: Bool = false,
        trailingPadding: Int = 0
    ) throws -> (Data, Data) {
        var root: [String: Any] = [
            "feeds": [
                "autotune-candidates.json": entry(candidates, signer: keyID),
                "demand-rank.json": entry(demandBody ?? demand, signer: demandSigner ?? keyID),
                "tier2-catalog.json": [
                    "bytes": 10, "sha256": String(repeating: "a", count: 64),
                    "signer_key_id": "tier2-coordinator-key:test", "version": "tier2",
                ] as [String: Any],
            ],
            "generated_at": "2026-11-12T00:00:00Z",
            "policy_version": "autotune-policy-v1",
            "release_id": "release-a",
            "schema_version": CatalogReleaseManifest.schemaVersion,
        ]
        if extraField {
            root["extra"] = true
        }
        var manifest = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        manifest.append(Data(repeating: UInt8(ascii: " "), count: trailingPadding))
        return (manifest, sidecar(for: manifest, signer: signer))
    }
}

/// Records the byte cap the streaming manifest fetch was given per path.
private final class CapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String: Int] = [:]

    var caps: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ path: String, _ maxBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        recorded[path] = maxBytes
    }
}

/// A fetch stub that serves fixed routes and records every requested path.
private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: Data]
    private var requested: [String] = []

    init(routes: [String: Data]) {
        self.routes = routes
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func set(_ routes: [String: Data]) {
        lock.lock()
        defer { lock.unlock() }
        self.routes = routes
    }

    var fetch: (URL) async throws -> Data {
        { [self] url in
            self.lock.lock()
            defer { self.lock.unlock() }
            self.requested.append(url.path)
            guard let data = self.routes[url.path] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }
}
