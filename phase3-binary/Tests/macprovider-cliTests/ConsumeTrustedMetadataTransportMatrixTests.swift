import Foundation
import CryptoKit
import Network
import Security
import XCTest
@testable import macprovider_cli

final class ConsumeTrustedMetadataTransportMatrixTests: XCTestCase {
    func testTrustedMetadataTransportMatrixUsesRealTLSAndFailsClosed() async throws {
        let workspace = try TemporaryTransportWorkspace()
        let trustedCA = try TransportCertificateAuthority(name: "trusted", workspace: workspace)
        let untrustedCA = try TransportCertificateAuthority(name: "untrusted", workspace: workspace)
        var records: [[String: String]] = []

        let validLeaf = try trustedCA.leaf(commonName: "api.example.test", dnsNames: ["api.example.test"])
        let validServer = try await LocalTLSTestServer(identity: validLeaf.identity, response: .ok(Data(#"{"ok":true}"#.utf8))).start()
        defer { validServer.stop() }
        let validBody = try await fetchFromPinnedLoopback(port: validServer.port, trustAnchors: [trustedCA.certificate])
        XCTAssertEqual(validBody, Data(#"{"ok":true}"#.utf8))
        let validRequests = await validServer.requests()
        XCTAssertEqual(validRequests.count, 1)
        let validRequest = try XCTUnwrap(validRequests.first)
        XCTAssertTrue(validRequest.hasPrefix("GET /v1/rate-card HTTP/1.1\r\n"))
        XCTAssertTrue(validRequest.contains("Host: api.example.test:\(validServer.port)\r\n"))
        records.append(pass("valid_pinned_peer_with_sni"))

        let untrustedLeaf = try untrustedCA.leaf(commonName: "api.example.test", dnsNames: ["api.example.test"])
        try await assertTLSFailure(
            leaf: untrustedLeaf,
            trustAnchors: [trustedCA.certificate],
            scenarioID: "untrusted_root_rejected",
            records: &records
        )

        let expiredLeaf = try trustedCA.leaf(
            commonName: "api.example.test",
            dnsNames: ["api.example.test"],
            startDate: "20200101000000Z",
            endDate: "20200102000000Z"
        )
        try await assertTLSFailure(
            leaf: expiredLeaf,
            trustAnchors: [trustedCA.certificate],
            scenarioID: "expired_certificate_rejected",
            records: &records
        )

        let intermediate = try trustedCA.intermediate(name: "missing-intermediate")
        let incompleteChainLeaf = try intermediate.leaf(commonName: "api.example.test", dnsNames: ["api.example.test"])
        try await assertTLSFailure(
            leaf: incompleteChainLeaf,
            trustAnchors: [trustedCA.certificate],
            scenarioID: "invalid_chain_rejected",
            records: &records
        )

        let mismatchedLeaf = try trustedCA.leaf(commonName: "wrong.example.test", dnsNames: ["wrong.example.test"])
        try await assertTLSFailure(
            leaf: mismatchedLeaf,
            trustAnchors: [trustedCA.certificate],
            scenarioID: "hostname_mismatch_rejected",
            records: &records
        )

        let matrixRateCard = try MatrixSignedRateCardFixture(generatedAt: "2026-09-02T12:00:00Z")
        let loaderServer = try await LocalTLSTestServer(
            identity: validLeaf.identity,
            response: .pathMapped([
                "/v1/rate-card": matrixRateCard.body,
                "/v1/rate-card.sig": matrixRateCard.sidecar,
            ])
        ).start()
        defer { loaderServer.stop() }
        let loaderRecorder = TransportLoaderRecorder(endpoint: "127.0.0.1")
        let validatedEndpoints: Set<String> = ["127.0.0.1"]
        let matrixLoader = ConsumeTrustedPricingLoader(
            resolveEndpoint: { host in
                await loaderRecorder.resolve(host)
            },
            fetch: { url, endpoint in
                await loaderRecorder.recordFetchEndpoint(endpoint)
                return try await self.fetchFromPinnedLoopback(
                    url: url,
                    endpoint: endpoint,
                    trustAnchors: [trustedCA.certificate],
                    timeouts: ConsumeUpstreamTimeouts(
                        connectNanoseconds: 1_000_000_000,
                        sendNanoseconds: 1_000_000_000,
                        readNanoseconds: 1_000_000_000
                    )
                )
            },
            trustedPublicKeys: matrixRateCard.trustedPublicKeys,
            expectedPolicyVersion: matrixRateCard.policyVersion,
            endpointValidator: { validatedEndpoints.contains($0) },
            now: { MatrixSignedRateCardFixture.date("2026-09-03T00:00:00Z") }
        )
        let matrixState = await matrixLoader.load(from: "https://api.example.test:\(loaderServer.port)")
        let resolvedHosts = await loaderRecorder.resolvedHosts()
        let fetchedEndpoints = await loaderRecorder.fetchedEndpoints()
        let loaderRequests = await loaderServer.requests()
        guard case .available(let loadedRateCard) = matrixState else {
            XCTFail("trusted pricing loader did not admit the signed real-socket matrix rate card: \(matrixState)")
            return
        }
        XCTAssertEqual(loadedRateCard.policyVersion, matrixRateCard.policyVersion)
        XCTAssertEqual(loadedRateCard.signerKeyID, matrixRateCard.keyID)
        XCTAssertEqual(resolvedHosts, ["api.example.test", "api.example.test"])
        XCTAssertEqual(fetchedEndpoints, ["127.0.0.1", "127.0.0.1"])
        XCTAssertEqual(loaderRequests.count, 2)
        XCTAssertTrue(fetchedEndpoints.allSatisfy { validatedEndpoints.contains($0) })
        records.append(pass("dns_reresolved_per_connection"))
        records.append(pass("connected_peer_in_validated_set"))

        let proxyProbe = try await PlainTCPProbe().start()
        defer { proxyProbe.stop() }
        let proxyEnv = "http://127.0.0.1:\(proxyProbe.port)"
        let restoreProxyEnv = setTemporaryProxyEnvironment(proxyEnv)
        defer { restoreProxyEnv() }
        let proxyIsolatedServer = try await LocalTLSTestServer(identity: validLeaf.identity, response: .ok(Data("{}".utf8))).start()
        defer { proxyIsolatedServer.stop() }
        _ = try await fetchFromPinnedLoopback(port: proxyIsolatedServer.port, trustAnchors: [trustedCA.certificate])
        try await Task.sleep(nanoseconds: 100_000_000)
        let proxyConnections = await proxyProbe.connectionCount()
        XCTAssertEqual(proxyConnections, 0)
        records.append(pass("environment_proxy_ignored"))

        let redirectServer = try await LocalTLSTestServer(
            identity: validLeaf.identity,
            response: .redirect("https://redirect-target.example.invalid/v1/rate-card")
        ).start()
        defer { redirectServer.stop() }
        do {
            _ = try await fetchFromPinnedLoopback(port: redirectServer.port, trustAnchors: [trustedCA.certificate])
            XCTFail("trusted metadata fetch followed or accepted a redirect")
        } catch let error as ConsumeTrustedPricingError {
            XCTAssertEqual(error.reason, .fetchFailed)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let redirectRequests = await redirectServer.requests()
        XCTAssertEqual(redirectRequests.count, 1)
        records.append(pass("redirect_not_followed"))

        let proxyIsolatedRequests = await proxyIsolatedServer.requests()
        for request in validRequests + proxyIsolatedRequests + redirectRequests {
            XCTAssertFalse(request.localizedCaseInsensitiveContains("Authorization:"))
            XCTAssertFalse(request.localizedCaseInsensitiveContains("Cookie:"))
            XCTAssertFalse(request.localizedCaseInsensitiveContains("Proxy-Authorization:"))
        }
        records.append(pass("zero_credential_bytes"))

        let slowServer = try await LocalTLSTestServer(
            identity: validLeaf.identity,
            response: .slowDrip(body: Data("0123456789abcdef".utf8), intervalNanoseconds: 80_000_000)
        ).start()
        defer { slowServer.stop() }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await fetchFromPinnedLoopback(
                port: slowServer.port,
                trustAnchors: [trustedCA.certificate],
                timeouts: ConsumeUpstreamTimeouts(
                    connectNanoseconds: 1_000_000_000,
                    sendNanoseconds: 1_000_000_000,
                    readNanoseconds: 300_000_000
                )
            )
            XCTFail("slow-drip response unexpectedly bypassed the absolute metadata read deadline")
        } catch let error as ConsumeTrustedPricingError {
            XCTAssertEqual(error.reason, .fetchFailed)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        XCTAssertLessThan(elapsed, 1_500_000_000)
        let slowRequests = await slowServer.requests()
        XCTAssertEqual(slowRequests.count, 1)
        records.append(pass("slow_drip_absolute_timeout"))

        try writeOptionalReport(records: records)
    }

    private func fetchFromPinnedLoopback(
        port: Int,
        trustAnchors: [SecCertificate],
        timeouts: ConsumeUpstreamTimeouts = .default
    ) async throws -> Data {
        try await fetchFromPinnedLoopback(
            url: URL(string: "https://api.example.test:\(port)/v1/rate-card")!,
            endpoint: "127.0.0.1",
            trustAnchors: trustAnchors,
            timeouts: timeouts
        )
    }

    private func fetchFromPinnedLoopback(
        url: URL,
        endpoint: String,
        trustAnchors: [SecCertificate],
        timeouts: ConsumeUpstreamTimeouts = .default
    ) async throws -> Data {
        try await ConsumePinnedUpstreamClient.fetchTestTrustedMetadata(
            url: url,
            endpoint: endpoint,
            timeouts: timeouts,
            parametersFactory: { serverName in
                ConsumePinnedUpstreamClient.trustedMetadataTLSParametersForTesting(
                    serverName: serverName,
                    trustAnchors: trustAnchors,
                    allowLoopback: true
                )
            }
        )
    }

    private func assertTLSFailure(
        leaf: TransportLeafIdentity,
        trustAnchors: [SecCertificate],
        scenarioID: String,
        records: inout [[String: String]]
    ) async throws {
        let server = try await LocalTLSTestServer(identity: leaf.identity, response: .ok(Data("{}".utf8))).start()
        defer { server.stop() }
        do {
            _ = try await fetchFromPinnedLoopback(
                port: server.port,
                trustAnchors: trustAnchors,
                timeouts: ConsumeUpstreamTimeouts(
                    connectNanoseconds: 1_000_000_000,
                    sendNanoseconds: 1_000_000_000,
                    readNanoseconds: 1_000_000_000
                )
            )
            XCTFail("\(scenarioID) unexpectedly completed trusted metadata TLS")
        } catch let error as ConsumeTrustedPricingError {
            XCTAssertEqual(error.reason, .fetchFailed)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 0)
        records.append(pass(scenarioID))
    }

    private func pass(_ scenarioID: String) -> [String: String] {
        ["id": scenarioID, "status": "pass"]
    }

    private func writeOptionalReport(records: [[String: String]]) throws {
        guard testRun?.failureCount == 0 else {
            return
        }
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_TRUSTED_METADATA_TRANSPORT_MATRIX_REPORT"],
              !path.isEmpty else {
            return
        }
        let report: [String: Any] = [
            "schema_version": "macprovider.trusted-metadata-transport-matrix.v1",
            "repository": [
                "name": "Augustas11/macprovider",
                "commit": sourceCommit() ?? NSNull(),
            ] as [String: Any],
            "transport": [
                "production_path": true,
                "real_sockets": true,
                "connection_api": "NWConnection",
                "source_files": [
                    "phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift",
                    "phase3-binary/Tests/macprovider-cliTests/ConsumeTrustedMetadataTransportMatrixTests.swift",
                ],
            ],
            "scenarios": records,
            "redaction": [
                "payload_bytes_omitted": true,
                "sensitive_material_omitted": true,
                "transcript_material_omitted": true,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private func sourceCommit() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    private func setTemporaryProxyEnvironment(_ proxy: String) -> () -> Void {
        let keys = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, getenv($0).map { String(cString: $0) }) })
        for key in keys {
            setenv(key, proxy, 1)
        }
        return {
            for key in keys {
                if let value = previous[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
    }
}

private struct TemporaryTransportWorkspace {
    let url: URL

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macprovider-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root
    }

    func path(_ components: String...) -> String {
        components.reduce(url) { $0.appendingPathComponent($1) }.path
    }
}

private struct MatrixSignedRateCardFixture {
    let keyID = "transport-matrix-key"
    let policyVersion = "transport-matrix-policy"
    let body: Data
    let sidecar: Data
    let trustedPublicKeys: [String: String]

    init(generatedAt: String) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        trustedPublicKeys = [keyID: privateKey.publicKey.rawRepresentation.base64EncodedString()]
        body = Self.rateCardBody(generatedAt: generatedAt, policyVersion: policyVersion)
        let signature = try privateKey.signature(for: body).base64EncodedString()
        sidecar = Data("""
        {"key_id":"\(keyID)","alg":"ed25519","signature":"\(signature)"}
        """.utf8)
    }

    static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.autotuneInternet.date(from: raw)!
    }

    private static func rateCardBody(generatedAt: String, policyVersion: String) -> Data {
        let rows = [
            "default": RateCardProjection.Row(
                promptRatePerMtok: 500_000,
                promptCacheHitRatePerMtok: 125_000,
                completionRatePerMtok: 1_000_000,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
            "llama-test": RateCardProjection.Row(
                promptRatePerMtok: 10,
                promptCacheHitRatePerMtok: 5,
                completionRatePerMtok: 20,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
        ]
        let projection = RateCardProjection(
            version: "",
            policyVersion: policyVersion,
            generatedAt: date(generatedAt),
            usdPerMillionCredits: 1.0,
            rows: rows
        )
        let rowsJSON = rows.keys.sorted().map { key -> String in
            let row = rows[key]!
            return """
            "\(key)":{"prompt_rate_per_mtok":\(row.promptRatePerMtok),"prompt_cache_hit_rate_per_mtok":\(row.promptCacheHitRatePerMtok),"completion_rate_per_mtok":\(row.completionRatePerMtok),"provider_share_bps":\(row.providerShareBPS),"global_multiplier_ppm":\(row.globalMultiplierPPM)}
            """
        }.joined(separator: ",")
        return Data("""
        {"version":"\(projection.projectionHash)","policy_version":"\(policyVersion)","generated_at":"\(generatedAt)","usd_per_million_credits":1.0,"rows":{\(rowsJSON)}}
        """.utf8)
    }
}

private struct TransportLeafIdentity {
    let certificatePath: String
    let keyPath: String
    let identity: SecIdentity
}

private final class TransportCertificateAuthority {
    let certificate: SecCertificate

    private let name: String
    private let workspace: TemporaryTransportWorkspace
    private let keyPath: String
    private let certificatePath: String
    private let serialPath: String
    private var serial = 1000

    init(name: String, workspace: TemporaryTransportWorkspace) throws {
        self.name = name
        self.workspace = workspace
        keyPath = workspace.path("\(name)-root.key")
        certificatePath = workspace.path("\(name)-root.pem")
        serialPath = workspace.path("\(name)-root.srl")
        try OpenSSL.run(["genrsa", "-out", keyPath, "2048"])
        try OpenSSL.run([
            "req", "-x509", "-new", "-nodes", "-key", keyPath, "-sha256", "-days", "30",
            "-subj", "/CN=MacProvider \(name) Test Root",
            "-out", certificatePath,
        ])
        let derPath = workspace.path("\(name)-root.der")
        try OpenSSL.run(["x509", "-in", certificatePath, "-outform", "der", "-out", derPath])
        let der = try Data(contentsOf: URL(fileURLWithPath: derPath))
        certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    func leaf(
        commonName: String,
        dnsNames: [String],
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> TransportLeafIdentity {
        try signedLeaf(
            signerCertificatePath: certificatePath,
            signerKeyPath: keyPath,
            commonName: commonName,
            dnsNames: dnsNames,
            startDate: startDate,
            endDate: endDate,
            includeSignerCertificateInPKCS12: true
        )
    }

    func intermediate(name intermediateName: String) throws -> TransportIntermediateAuthority {
        let intermediateKey = workspace.path("\(name)-\(intermediateName).key")
        let intermediateCSR = workspace.path("\(name)-\(intermediateName).csr")
        let intermediateCert = workspace.path("\(name)-\(intermediateName).pem")
        let config = workspace.path("\(name)-\(intermediateName).cnf")
        try Data("""
        [v3_ca]
        basicConstraints=critical,CA:TRUE,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid,issuer
        """.utf8).write(to: URL(fileURLWithPath: config))
        try OpenSSL.run(["genrsa", "-out", intermediateKey, "2048"])
        try OpenSSL.run(["req", "-new", "-key", intermediateKey, "-subj", "/CN=MacProvider \(intermediateName)", "-out", intermediateCSR])
        try OpenSSL.run([
            "x509", "-req", "-in", intermediateCSR, "-CA", certificatePath, "-CAkey", keyPath,
            "-CAserial", serialPath, "-CAcreateserial", "-out", intermediateCert, "-days", "10",
            "-sha256", "-extensions", "v3_ca", "-extfile", config,
        ])
        return TransportIntermediateAuthority(parent: self, name: intermediateName, keyPath: intermediateKey, certificatePath: intermediateCert)
    }

    fileprivate func signedLeaf(
        signerCertificatePath: String,
        signerKeyPath: String,
        commonName: String,
        dnsNames: [String],
        startDate: String?,
        endDate: String?,
        includeSignerCertificateInPKCS12: Bool
    ) throws -> TransportLeafIdentity {
        serial += 1
        let prefix = "\(name)-leaf-\(serial)"
        let leafKey = workspace.path("\(prefix).key")
        let csr = workspace.path("\(prefix).csr")
        let leafCert = workspace.path("\(prefix).pem")
        let config = workspace.path("\(prefix).cnf")
        try writeLeafConfig(path: config, commonName: commonName, dnsNames: dnsNames)
        try OpenSSL.run(["genrsa", "-out", leafKey, "2048"])
        try OpenSSL.run(["req", "-new", "-key", leafKey, "-out", csr, "-config", config])
        if let startDate, let endDate {
            let caConfig = try caConfigPath(certificatePath: signerCertificatePath, keyPath: signerKeyPath)
            try OpenSSL.run([
                "ca", "-batch", "-config", caConfig, "-startdate", startDate, "-enddate", endDate,
                "-extensions", "v3_req", "-extfile", config, "-in", csr, "-out", leafCert,
            ])
        } else {
            try OpenSSL.run([
                "x509", "-req", "-in", csr, "-CA", signerCertificatePath, "-CAkey", signerKeyPath,
                "-CAserial", serialPath, "-CAcreateserial", "-out", leafCert, "-days", "7",
                "-sha256", "-extensions", "v3_req", "-extfile", config,
            ])
        }
        return try TransportLeafIdentity(
            certificatePath: leafCert,
            keyPath: leafKey,
            identity: Self.identity(certificatePath: leafCert, keyPath: leafKey, signerCertificatePath: includeSignerCertificateInPKCS12 ? signerCertificatePath : nil, workspace: workspace, prefix: prefix)
        )
    }

    private func writeLeafConfig(path: String, commonName: String, dnsNames: [String]) throws {
        let altNames = dnsNames.enumerated().map { index, name in "DNS.\(index + 1)=\(name)" }.joined(separator: "\n")
        try Data("""
        [req]
        distinguished_name=req_distinguished_name
        prompt=no
        req_extensions=v3_req
        [req_distinguished_name]
        CN=\(commonName)
        [v3_req]
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=@alt_names
        [alt_names]
        \(altNames)
        """.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func caConfigPath(certificatePath: String, keyPath: String) throws -> String {
        let caDir = workspace.url.appendingPathComponent("ca-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: caDir, withIntermediateDirectories: true)
        try Data("1000\n".utf8).write(to: caDir.appendingPathComponent("serial"))
        try Data().write(to: caDir.appendingPathComponent("index.txt"))
        let config = caDir.appendingPathComponent("openssl.cnf")
        try Data("""
        [ca]
        default_ca=CA_default
        [CA_default]
        dir=\(caDir.path)
        database=$dir/index.txt
        serial=$dir/serial
        new_certs_dir=$dir
        certificate=\(certificatePath)
        private_key=\(keyPath)
        default_md=sha256
        policy=policy_any
        x509_extensions=v3_req
        copy_extensions=copy
        [policy_any]
        commonName=supplied
        """.utf8).write(to: config)
        return config.path
    }

    private static func identity(
        certificatePath: String,
        keyPath: String,
        signerCertificatePath: String?,
        workspace: TemporaryTransportWorkspace,
        prefix: String
    ) throws -> SecIdentity {
        let p12Path = workspace.path("\(prefix).p12")
        var arguments = ["pkcs12", "-export", "-inkey", keyPath, "-in", certificatePath, "-out", p12Path, "-passout", "pass:macprovider-test"]
        if let signerCertificatePath {
            arguments.insert(contentsOf: ["-certfile", signerCertificatePath], at: arguments.count - 2)
        }
        try OpenSSL.run(arguments)
        let p12 = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        var imported: CFArray?
        let status = SecPKCS12Import(
            p12 as CFData,
            [kSecImportExportPassphrase as String: "macprovider-test"] as CFDictionary,
            &imported
        )
        XCTAssertEqual(status, errSecSuccess)
        let items = try XCTUnwrap(imported as? [[String: Any]])
        let first = try XCTUnwrap(items.first)
        return try XCTUnwrap(first[kSecImportItemIdentity as String] as! SecIdentity?)
    }
}

private final class TransportIntermediateAuthority {
    private let parent: TransportCertificateAuthority
    private let name: String
    private let keyPath: String
    private let certificatePath: String

    init(parent: TransportCertificateAuthority, name: String, keyPath: String, certificatePath: String) {
        self.parent = parent
        self.name = name
        self.keyPath = keyPath
        self.certificatePath = certificatePath
    }

    func leaf(commonName: String, dnsNames: [String]) throws -> TransportLeafIdentity {
        try parent.signedLeaf(
            signerCertificatePath: certificatePath,
            signerKeyPath: keyPath,
            commonName: commonName,
            dnsNames: dnsNames,
            startDate: nil,
            endDate: nil,
            includeSignerCertificateInPKCS12: false
        )
    }
}

private enum OpenSSL {
    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "OpenSSL", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private final class LocalTLSTestServer: @unchecked Sendable {
    enum Response {
        case ok(Data)
        case pathMapped([String: Data])
        case redirect(String)
        case slowDrip(body: Data, intervalNanoseconds: UInt64)
    }

    private let identity: SecIdentity
    private let response: Response
    private let queue = DispatchQueue(label: "macprovider.transport-matrix.tls-server")
    private let recorder = RequestRecorder()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var port: Int = 0

    init(identity: SecIdentity, response: Response) {
        self.identity = identity
        self.response = response
    }

    func start() async throws -> LocalTLSTestServer {
        let options = NWProtocolTLS.Options()
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw NSError(domain: "LocalTLSTestServer", code: 1)
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, protocolIdentity)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotGate<Void>()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = Int(listener.port?.rawValue ?? 0)
                    gate.finish(.success(()), continuation: continuation)
                case .failed(let error):
                    gate.finish(.failure(error), continuation: continuation)
                case .cancelled:
                    gate.finish(.failure(NWError.posix(.ECANCELED)), continuation: continuation)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
        return self
    }

    func stop() {
        listener?.cancel()
        for connection in connections {
            connection.cancel()
        }
    }

    func requests() async -> [String] {
        await recorder.snapshot()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                return
            }
            var next = buffer
            if let data {
                next.append(data)
            }
            if next.range(of: Data([13, 10, 13, 10])) != nil {
                let request = String(decoding: next, as: UTF8.self)
                Task { await self.recorder.append(request) }
                self.sendResponse(for: request, on: connection)
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func sendResponse(for request: String, on connection: NWConnection) {
        switch response {
        case .ok(let body):
            sendAll(responseBytes(status: "200 OK", headers: ["Content-Type": "application/json"], body: body), on: connection)
        case .pathMapped(let bodies):
            let requestPath = Self.requestPath(from: request) ?? "/"
            let body = bodies[requestPath] ?? Data(#"{"missing":true}"#.utf8)
            let status = bodies[requestPath] == nil ? "404 Not Found" : "200 OK"
            sendAll(responseBytes(status: status, headers: ["Content-Type": "application/json"], body: body), on: connection)
        case .redirect(let location):
            sendAll(
                responseBytes(
                    status: "307 Temporary Redirect",
                    headers: ["Location": location, "Content-Type": "application/json"],
                    body: Data(#"{"redirect":true}"#.utf8)
                ),
                on: connection
            )
        case .slowDrip(let body, let intervalNanoseconds):
            let head = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: head, completion: .contentProcessed { [weak self] _ in
                self?.sendSlow(body: Array(body), index: 0, intervalNanoseconds: intervalNanoseconds, on: connection)
            })
        }
    }

    private func sendAll(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func requestPath(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private func sendSlow(body: [UInt8], index: Int, intervalNanoseconds: UInt64, on connection: NWConnection) {
        guard index < body.count else {
            connection.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(intervalNanoseconds))) { [weak self] in
            connection.send(content: Data([body[index]]), completion: .contentProcessed { _ in
                self?.sendSlow(body: body, index: index + 1, intervalNanoseconds: intervalNanoseconds, on: connection)
            })
        }
    }

    private func responseBytes(status: String, headers: [String: String], body: Data) -> Data {
        var lines = ["HTTP/1.1 \(status)"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }
}

private final class PlainTCPProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macprovider.transport-matrix.proxy-probe")
    private let counter = RequestCounter()
    private var listener: NWListener?
    private(set) var port: Int = 0

    func start() async throws -> PlainTCPProbe {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotGate<Void>()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = Int(listener.port?.rawValue ?? 0)
                    gate.finish(.success(()), continuation: continuation)
                case .failed(let error):
                    gate.finish(.failure(error), continuation: continuation)
                case .cancelled:
                    gate.finish(.failure(NWError.posix(.ECANCELED)), continuation: continuation)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [counter] connection in
                Task { await counter.increment() }
                connection.cancel()
            }
            listener.start(queue: queue)
        }
        return self
    }

    func stop() {
        listener?.cancel()
    }

    func connectionCount() async -> Int {
        await counter.snapshot()
    }
}

private actor TransportLoaderRecorder {
    private let endpoint: String
    private var hosts: [String] = []
    private var endpoints: [String] = []

    init(endpoint: String) {
        self.endpoint = endpoint
    }

    func resolve(_ host: String) -> String {
        hosts.append(host)
        return endpoint
    }

    func recordFetchEndpoint(_ endpoint: String) {
        endpoints.append(endpoint)
    }

    func resolvedHosts() -> [String] {
        hosts
    }

    func fetchedEndpoints() -> [String] {
        endpoints
    }
}

private actor RequestRecorder {
    private var requests: [String] = []

    func append(_ request: String) {
        requests.append(request)
    }

    func snapshot() -> [String] {
        requests
    }
}

private actor RequestCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

private final class OneShotGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func finish(_ result: Result<Value, Error>, continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
