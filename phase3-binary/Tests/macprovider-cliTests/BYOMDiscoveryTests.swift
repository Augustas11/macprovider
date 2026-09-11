import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMDiscoveryTests: XCTestCase {
    // #1381 F8 cause 2: the hermetic BYOM E2E harness supplies a RAM value so
    // the fixture model's advisory local-fit signal does not report
    // does_not_fit on CI/dev hardware. The override is honored only for a
    // positive integer; anything else falls back to real detection.
    func testBYOMFitEnvironmentHonorsScopedRAMOverride() {
        XCTAssertEqual(
            BYOMFitEnvironment.detectedRAMGB(environment: [BYOMFitEnvironment.overrideEnvVar: "64"]),
            64
        )
        XCTAssertEqual(
            BYOMFitEnvironment.detectedRAMGB(environment: [BYOMFitEnvironment.overrideEnvVar: " 48 "]),
            48
        )
        let real = BYOMFitEnvironment.detectedRAMGB(environment: [:])
        for invalid in ["0", "-4", "abc", ""] {
            XCTAssertEqual(
                BYOMFitEnvironment.detectedRAMGB(environment: [BYOMFitEnvironment.overrideEnvVar: invalid]),
                real,
                "invalid override \(invalid.debugDescription) should fall back to real detection"
            )
        }
        XCTAssertEqual(BYOMFitEnvironment.detectedRAMGB(environment: [:]), real)
    }

    // #1381 F2/F5: operator-facing guidance must name the action that actually
    // resolves the blocker, not a dead end.
    func testBYOMModelAdmissionGuidancePointsToRecoveryActions() {
        // Not-offerable guidance still names the advisory strengthening flag
        // (--evaluation-digest-sha256); the digest is optional per SPEC-047-R002,
        // not a hard requirement.
        XCTAssertTrue(
            BYOMModelAdmissionError.candidateNotOfferable.description.contains("--evaluation-digest-sha256"),
            "not-offerable guidance must name the advisory --evaluation-digest-sha256 flag"
        )
        // F5: unstable / not-found point at the served_model_ref recovery target.
        XCTAssertTrue(
            BYOMModelAdmissionError.candidateUnstable.description.contains("served_model_ref"),
            "unstable guidance must name served_model_ref"
        )
        XCTAssertTrue(
            BYOMModelAdmissionError.candidateNotFound.description.contains("served_model_ref"),
            "not-found guidance must name served_model_ref"
        )
    }

    func testDiscoverCommandEmitsClosedSchemaWithNullableAdvisoryFields() async throws {
        let root = try temporaryDirectory("byom-schema")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespaceDir = root.appendingPathComponent("nsdir", isDirectory: true)
        try FileManager.default.createDirectory(at: namespaceDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespaceDir.path)
        let namespace = namespaceDir.appendingPathComponent("ns")
        try Data(repeating: 0x37, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namespace.path)
        let namespaceBefore = try Data(contentsOf: namespace)
        try createMLXSnapshot(
            cacheRoot: cache,
            modelID: "mlx-community/Tiny-1B-4bit",
            configJSON: #"{"max_position_embeddings":4096}"#
        )

        let command = try ModelsDiscoverCommand.parse([
            "--json",
            "--local-discovery-namespace-path", namespace.path,
            "--mlx-cache-dir", cache.path,
            "--skip-ollama",
            "--skip-lmstudio",
            "--skip-llamacpp",
        ])
        let capture = await captureBYOMOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["schema"] as? String, "provider_byom_discovery.v1")
        XCTAssertEqual(object["projection_sequence"] as? Int, 1)
        XCTAssertEqual(object["cli_version"] as? String, CoordinatorClient.binaryVersion)
        let adapters = try XCTUnwrap(object["adapters"] as? [[String: Any]])
        XCTAssertEqual(adapters.first?["runtime_source"] as? String, "mlx_cache")
        let candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate["runtime_source"] as? String, "mlx_cache")
        XCTAssertEqual(candidate["served_model_ref"] as? String, "mlx-community/Tiny-1B-4bit")
        XCTAssertTrue((candidate["candidate_id"] as? String)?.hasPrefix("byom_") == true)
        XCTAssertEqual(candidate["locality"] as? String, "local_artifact")
        XCTAssertEqual(candidate["readiness_state"] as? String, "ready")
        XCTAssertEqual(candidate["evaluation_state"] as? String, "not_evaluated")
        XCTAssertEqual(candidate["admission_state_source"] as? String, "local_default")
        XCTAssertEqual(candidate["admission_state"] as? String, "offerable")
        XCTAssertEqual(candidate["context_window_tokens"] as? Int, 4096)
        XCTAssertTrue(candidate.keys.contains("catalog_model_key"))
        let capabilities = try XCTUnwrap(candidate["capabilities"] as? [String: Any])
        XCTAssertTrue(capabilities.keys.contains("tool_call_passthrough"))
        XCTAssertTrue(capabilities["tool_call_passthrough"] is NSNull)
        XCTAssertEqual(capabilities["max_context_tokens"] as? Int, 4096)
        let guidance = try XCTUnwrap(candidate["provider_guidance"] as? [String: Any])
        XCTAssertEqual(guidance["earning_path_class"] as? String, "local_inventory_only")
        // Discovery is read-only: a pre-existing salt is read, never rewritten.
        XCTAssertEqual(try Data(contentsOf: namespace), namespaceBefore)
    }

    func testDiscoverIsReadOnlyWhenNamespaceMissing() async throws {
        let root = try temporaryDirectory("byom-readonly")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("missing-ns")
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        // SPEC-046-R001: discovery MUST NOT provision the salt (no write).
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.path))
        let candidate = try XCTUnwrap(document.candidates.first)
        XCTAssertTrue(candidate.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertTrue(candidate.warningCodes.contains("candidate_id_unstable"))
    }

    func testMLXWeightSymlinkIntoBlobsIsResolvedAndCounted() async throws {
        let root = try temporaryDirectory("byom-symlink")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        // Mimic a real HF cache: weights live in blobs/ and the snapshot holds
        // relative symlinks into them (the shape H1 must handle).
        let repo = cache.appendingPathComponent("models--mlx-community--Tiny-1B-4bit", isDirectory: true)
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: blobs.appendingPathComponent("config-blob"))
        try Data(repeating: 0x7a, count: 4096).write(to: blobs.appendingPathComponent("weights-blob"))
        // Use the path/string API so the destination stays a genuine RELATIVE
        // symlink (the URL API would resolve it against the cwd).
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("config.json").path,
            withDestinationPath: "../../blobs/config-blob"
        )
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weights-blob"
        )
        // An escaping symlink must be ignored, never followed out of the cache.
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("escape.safetensors").path,
            withDestinationPath: "/etc/hosts"
        )

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: root.appendingPathComponent("ns"), mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        let candidate = try XCTUnwrap(document.candidates.first)
        // Symlinked config + weights are resolved, so the model reads as ready.
        XCTAssertEqual(candidate.readinessState, "ready")
    }

    func testRuntimeModelReferenceRejectsHostnameAndHostPortShapes() {
        for leak in [
            "coordinator.malibu.tech:443",
            "coordinator.malibu.tech",       // bare public hostname, no port
            "coordinator.malibu.tech.",      // trailing-dot hostname
            "example.com:8080",
            "host.io",
            "hf.co/library/x",
            "prod.internal:11434",
            "prod.internal",
            "macbook.local",
            "gateway.corp",
            "::ffff:127.0.0.1",
            "127.0.0.1",
            "0x7f.0.0.1",
            "0177.0.0.1",                    // octal dotted IPv4
            "0x7f000001",                    // one-piece hex IPv4
            "2130706433",                    // one-piece decimal IPv4
            "127.0.0.1:11434",               // encoded/plain IPv4 with :port
            "0x7f000001:11434",
            "2130706433:11434",
            "0177.0.0.1:11434",
            "model-127.0.0.1",               // IP literal embedded in a name
            "model-0x7f000001",
            "model-::1",
            "2001:db8:85a3:0:0:8a2e:370:7334",  // uncompressed IPv6
            "127.1",                         // legacy IPv4 shorthand (authority)
            "127.0.1:11434",
            "0177.1:11434",                  // octal shorthand + port
            "0x7f.1:11434",                  // hex shorthand + port
            "017700000001:11434",            // one-piece octal + port
        ] {
            XCTAssertFalse(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(leak), "must reject \(leak)")
        }
        for ok in [
            "llama3.2:3b", "mistral:latest", "qwen2.5:7b", "qwen2.5-coder:7b",
            "gemma2:9b", "deepseek-r1:14b", "phi-3.5-mini", "mistral-7b-instruct-v0.2",
        ] {
            XCTAssertTrue(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(ok), "must allow \(ok)")
        }
        // The slash-bearing HF cache id form is a valid model reference (the
        // runtime-ref gate additionally bans "/", but the shared sanitizer must
        // not reject a legitimate cache id on hostname/TLD grounds).
        XCTAssertTrue(BYOMDiscoveryPrivacy.isSafeModelReference("mlx-community/Llama-3.2-3B-Instruct-4bit"))
    }

    func testContextWindowParsingRejectsOutOfRangeNumberWithoutCrashing() {
        // A hostile config.json must degrade to nil, never trap the process.
        XCTAssertNil(BYOMDiscoveryJSON.contextWindowTokens(from: Data(#"{"max_position_embeddings":1e20}"#.utf8)))
        XCTAssertNil(BYOMDiscoveryJSON.contextWindowTokens(from: Data(#"{"max_position_embeddings":-1e20}"#.utf8)))
        XCTAssertNil(BYOMDiscoveryJSON.contextWindowTokens(from: Data(#"{"max_position_embeddings":1.5}"#.utf8)))
        XCTAssertEqual(BYOMDiscoveryJSON.contextWindowTokens(from: Data(#"{"max_position_embeddings":4096}"#.utf8)), 4096)
    }

    func testDiscoverCommandMirrorsWarningsToStderrInJSONMode() async throws {
        let root = try temporaryDirectory("byom-stderr")
        let command = try ModelsDiscoverCommand.parse([
            "--json",
            "--local-discovery-namespace-path", root.appendingPathComponent("ns").path,
            "--mlx-cache-dir", root.appendingPathComponent("missing-cache", isDirectory: true).path,
            "--skip-ollama",
            "--skip-lmstudio",
            "--skip-llamacpp",
        ])
        let capture = await captureBYOMOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        XCTAssertNoThrow(try jsonObject(capture.stdout))
        XCTAssertTrue(capture.stderr.contains("models discover warning: adapter_unavailable"))
        XCTAssertFalse(capture.stderr.contains(root.path))
    }

    func testDiscoverCommandRequiresJSONFlag() async throws {
        let command = try ModelsDiscoverCommand.parse(["--skip-ollama"])
        let capture = await captureBYOMOutput {
            try await command.run()
        }

        XCTAssertTrue(capture.stdout.isEmpty)
        XCTAssertTrue(capture.stderr.contains("JSON-only"))
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testCandidateIDIsStableWithinNamespaceAndScopedByRuntimeSource() {
        let namespace = Data(repeating: 0x42, count: 32)
        let first = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "mlx_cache",
            servedModelRef: "MLX-Community/Tiny-1B"
        )
        let second = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "mlx_cache",
            servedModelRef: "mlx-community/tiny-1b"
        )
        let otherRuntime = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "ollama_loopback",
            servedModelRef: "mlx-community/tiny-1b"
        )

        XCTAssertEqual(first.0, second.0)
        XCTAssertNotEqual(first.0, otherRuntime.0)
        XCTAssertEqual(first.1.map(\.rawValue), [])
        XCTAssertTrue(first.0.range(of: #"^byom_[a-z2-7]+$"#, options: .regularExpression) != nil)
    }

    func testInvalidNamespacePermissionsKeepCandidateLocalOnly() async throws {
        let root = try temporaryDirectory("byom-ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try Data(repeating: 0x11, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: namespace.path)
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        XCTAssertTrue(document.warnings.contains("namespace_permission_invalid"))
        let candidate = try XCTUnwrap(document.candidates.first)
        XCTAssertTrue(candidate.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertTrue(candidate.warningCodes.contains("candidate_id_unstable"))
        XCTAssertTrue(candidate.warningCodes.contains("namespace_permission_invalid"))
    }

    func testInsecureNamespaceDirectoryKeepsCandidateLocalOnly() async throws {
        let root = try temporaryDirectory("byom-ns-dir")
        let insecureDir = root.appendingPathComponent("insecure", isDirectory: true)
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = insecureDir.appendingPathComponent("ns")
        try FileManager.default.createDirectory(at: insecureDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: insecureDir.path)
        try Data(repeating: 0x11, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namespace.path)
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        let candidate = try XCTUnwrap(document.candidates.first)
        XCTAssertTrue(document.warnings.contains("namespace_permission_invalid"))
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertTrue(candidate.warningCodes.contains("namespace_permission_invalid"))
    }

    func testLoopbackOriginValidatorAcceptsOnlyLiteralLoopbackHTTPOrigins() {
        XCTAssertNotNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.0.0.1:11434"))
        XCTAssertNotNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.9.8.7:11434"))
        XCTAssertNotNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://[::1]:11434"))

        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("https://127.0.0.1:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://localhost:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://LOCALHOST:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.0.0.1.example.com:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://0.0.0.0:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://192.168.1.10:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.0.0.1"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://user:pass@127.0.0.1:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("unix:///tmp/ollama.sock"))
    }

    // #1246 / SPEC-046-R002: the closing rejection matrix for the shared adapter
    // safety layer. Every rejection class the BYOM epic gate names is asserted
    // against BOTH admission points so a new adapter cannot reintroduce its own
    // URL policy: `validatedHTTPOrigin` admits an operator-supplied origin, and
    // `isSafeLoopbackHTTPURL` re-admits every request URL inside the shared HTTP
    // client. The only accepted shapes are a literal dotted-quad in 127.0.0.0/8
    // and literal `::1`, each with an explicit port.
    func testLoopbackOriginRejectionMatrixCoversEveryNonLoopbackClass() {
        struct OriginCase {
            let raw: String
            let rejectionClass: String
            let acceptsOrigin: Bool
            let acceptsRequestURL: Bool

            init(
                _ raw: String,
                _ rejectionClass: String,
                acceptsOrigin: Bool = false,
                acceptsRequestURL: Bool? = nil
            ) {
                self.raw = raw
                self.rejectionClass = rejectionClass
                self.acceptsOrigin = acceptsOrigin
                self.acceptsRequestURL = acceptsRequestURL ?? acceptsOrigin
            }
        }

        let cases: [OriginCase] = [
            // Accepted: literal loopback only.
            OriginCase("http://127.0.0.1:11434", "loopback ipv4", acceptsOrigin: true),
            OriginCase("http://127.255.255.254:11434", "loopback ipv4 high", acceptsOrigin: true),
            OriginCase("http://[::1]:11434", "loopback ipv6", acceptsOrigin: true),

            // LAN / private non-loopback.
            OriginCase("http://192.168.1.10:11434", "lan rfc1918"),
            OriginCase("http://10.0.0.5:11434", "lan rfc1918"),
            OriginCase("http://172.16.0.1:11434", "lan rfc1918"),

            // Public.
            OriginCase("http://8.8.8.8:11434", "public ipv4"),
            OriginCase("http://[2606:4700::1111]:11434", "public ipv6"),

            // Wildcard / any-address bind targets.
            OriginCase("http://0.0.0.0:11434", "wildcard ipv4"),
            OriginCase("http://[::]:11434", "wildcard ipv6"),

            // Link-local (including a percent-encoded zone id).
            OriginCase("http://169.254.1.1:11434", "link-local ipv4"),
            OriginCase("http://[fe80::1]:11434", "link-local ipv6"),
            OriginCase("http://[fe80::1%25lo0]:11434", "link-local ipv6 zone id"),

            // Multicast.
            OriginCase("http://224.0.0.1:11434", "multicast ipv4"),
            OriginCase("http://[ff02::1]:11434", "multicast ipv6"),

            // IPv4-mapped / IPv4-compatible / uncompressed loopback spellings.
            // These name the loopback host but are NOT the two literal forms the
            // validator admits, so they stay rejected (fail-closed): admitting
            // them would mean parsing IPv6 address semantics in the CLI.
            OriginCase("http://[::ffff:127.0.0.1]:11434", "ipv4-mapped loopback"),
            OriginCase("http://[::ffff:7f00:1]:11434", "ipv4-mapped hex loopback"),
            OriginCase("http://[0:0:0:0:0:0:0:1]:11434", "uncompressed ipv6 loopback"),

            // Shorthand / alternate-encoded loopback.
            OriginCase("http://127.1:11434", "shorthand ipv4 loopback"),
            OriginCase("http://0177.0.0.1:11434", "octal-encoded loopback"),
            OriginCase("http://2130706433:11434", "decimal dword loopback"),
            OriginCase("http://0x7f000001:11434", "hex dword loopback"),
            OriginCase("http://127.0.0.1.:11434", "trailing-dot loopback"),

            // Hostname-expanded (DNS resolution is never trusted).
            OriginCase("http://localhost:11434", "hostname-expanded"),
            OriginCase("http://ip6-localhost:11434", "hostname-expanded ipv6 alias"),
            OriginCase("http://127.0.0.1.nip.io:11434", "hostname-expanded wildcard dns"),
            OriginCase("http://my-mac.local:11434", "mDNS .local name"),

            // Credentials / query / fragment / path.
            OriginCase("http://user:pass@127.0.0.1:11434", "embedded credentials"),
            OriginCase("http://127.0.0.1:11434?next=http://192.168.1.10", "query string"),
            OriginCase("http://127.0.0.1:11434#fragment", "fragment"),
            // A path is rejected as an ORIGIN (operators supply origins only) but
            // is admissible as a request URL, because the shared client appends
            // the adapter's fixed path to an already-validated origin.
            OriginCase("http://127.0.0.1:11434/api/tags", "path in origin", acceptsRequestURL: true),

            // Scheme.
            OriginCase("https://127.0.0.1:11434", "https scheme"),

            // Port bounds.
            OriginCase("http://127.0.0.1", "missing port"),
            OriginCase("http://127.0.0.1:0", "port 0"),
            OriginCase("http://127.0.0.1:65536", "port above 65535"),

            // Unix-domain sockets.
            OriginCase("unix:///tmp/ollama.sock", "unix socket"),
            OriginCase("http+unix://%2Ftmp%2Follama.sock/api/tags", "http+unix socket"),
        ]

        for originCase in cases {
            XCTAssertEqual(
                BYOMLoopbackOriginValidator.validatedHTTPOrigin(originCase.raw) != nil,
                originCase.acceptsOrigin,
                "origin admission (\(originCase.rejectionClass)): \(originCase.raw)"
            )
            let admitsRequestURL = URL(string: originCase.raw)
                .map(BYOMLoopbackOriginValidator.isSafeLoopbackHTTPURL) ?? false
            XCTAssertEqual(
                admitsRequestURL,
                originCase.acceptsRequestURL,
                "request-URL admission (\(originCase.rejectionClass)): \(originCase.raw)"
            )
        }
    }

    // #1246 / SPEC-046-R002: "The CLI MUST NOT scan ports or networks; an adapter
    // endpoint is either a well-known loopback default for that runtime or an
    // operator-supplied loopback origin." Proven on the recorded request log of
    // the hermetic client: exactly one request, to exactly the configured origin,
    // in the reachable, operator-overridden, and unreachable cases alike.
    func testDiscoveryContactsOnlyConfiguredLoopbackOriginAndNeverScans() async throws {
        // The shipped default is a single well-known loopback origin, not a range.
        XCTAssertEqual(try ModelsDiscoverCommand.parse(["--json"]).ollamaOrigin, "http://127.0.0.1:11434")

        let root = try temporaryDirectory("byom-no-scan")

        let defaultClient = RecordingBYOMHTTPClient()
        _ = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: defaultClient
        ).discover()
        XCTAssertEqual(defaultClient.requestLog, ["GET http://127.0.0.1:11434/api/tags"])

        // An operator-supplied loopback origin is honored verbatim — no probing
        // of the default port, no neighbouring ports, no other loopback address.
        let operatorClient = RecordingBYOMHTTPClient()
        _ = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.4.5.6:39999"
            ),
            httpClient: operatorClient
        ).discover()
        XCTAssertEqual(operatorClient.requestLog, ["GET http://127.4.5.6:39999/api/tags"])

        // An unreachable default fails closed with adapter_unavailable and does
        // NOT fall back to any other host or port.
        let unreachableClient = RecordingBYOMHTTPClient(error: URLError(.cannotConnectToHost))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: unreachableClient
        ).discover()
        XCTAssertEqual(unreachableClient.requestLog, ["GET http://127.0.0.1:11434/api/tags"])
        XCTAssertEqual(
            document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.warningCodes,
            ["adapter_unavailable"]
        )
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "unavailable")
        XCTAssertTrue(document.candidates.isEmpty)
    }

    // #1246 / SPEC-046-R002: discovery uses short timeouts. A loopback listener
    // that completes the TCP handshake and then never answers must surface
    // adapter_timeout on the discovery path (evaluation is covered by
    // testEvaluateRuntimeTimeoutFailsClosed), fabricate no candidate, and leak no
    // endpoint into stdout JSON or stderr diagnostics.
    func testDiscoveryTimeoutFailsClosedWithoutEndpointLeak() async throws {
        let root = try temporaryDirectory("byom-discovery-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try SilentLoopbackListener()
        let command = try ModelsDiscoverCommand.parse([
            "--json",
            "--local-discovery-namespace-path", root.appendingPathComponent("ns").path,
            "--mlx-cache-dir", root.appendingPathComponent("hf", isDirectory: true).path,
            "--ollama-origin", listener.origin,
        ])
        let capture = await captureBYOMOutput { try await command.run() }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        let warnings = try XCTUnwrap(object["warnings"] as? [String])
        XCTAssertTrue(warnings.contains("adapter_timeout"), "warnings: \(warnings)")
        XCTAssertTrue(capture.stderr.contains("models discover warning: adapter_timeout"))
        let adapters = try XCTUnwrap(object["adapters"] as? [[String: Any]])
        let ollama = try XCTUnwrap(adapters.first { $0["runtime_source"] as? String == "ollama_loopback" })
        XCTAssertEqual(ollama["status"] as? String, "timeout")
        XCTAssertEqual(ollama["warning_codes"] as? [String], ["adapter_timeout"])
        XCTAssertEqual((object["candidates"] as? [Any])?.count, 0)

        let emitted = capture.stdout + capture.stderr
        for leak in [listener.origin, String(listener.port), "/api/tags", root.path] {
            XCTAssertFalse(emitted.contains(leak), "timeout diagnostics leaked \(leak)")
        }
    }

    // #1246 / SPEC-046-R002: "bounded JSON nesting/parser work". A body well under
    // the 256KiB byte cap can still be pathologically nested. The shared parsing
    // layer (StrictJSONParser, depth cap 32, enforced BEFORE the next recursion)
    // must turn that into the closed adapter_malformed_response code rather than
    // a stack overflow. Asserted on the shared parser entry points used by
    // discovery, and end-to-end through the Ollama adapter.
    func testBoundedJSONNestingFailsClosedWithoutStackOverflow() async throws {
        let openBrackets = Data(String(repeating: "[", count: 50_000).utf8)
        let openBraces = Data(String(repeating: "{", count: 50_000).utf8)
        for hostile in [openBrackets, openBraces] {
            XCTAssertLessThan(hostile.count, BYOMDiscoveryHTTPBounds.maxBodyBytes)
            XCTAssertThrowsError(try BYOMDiscoveryJSON.parseOllamaTags(hostile)) { error in
                guard case BYOMDiscoveryAdapterError.malformed = error else {
                    return XCTFail("expected malformed, got \(error)")
                }
            }
            XCTAssertNil(BYOMDiscoveryJSON.contextWindowTokens(from: hostile))
        }

        // Well-formed JSON, under the byte cap, with a pathologically nested
        // `models` array.
        let depth = 20_000
        let nested = Data((
            #"{"models":["# + String(repeating: "[", count: depth)
                + String(repeating: "]", count: depth) + "]}"
        ).utf8)
        XCTAssertLessThan(nested.count, BYOMDiscoveryHTTPBounds.maxBodyBytes)
        XCTAssertThrowsError(try BYOMDiscoveryJSON.parseOllamaTags(nested)) { error in
            guard case BYOMDiscoveryAdapterError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }

        let root = try temporaryDirectory("byom-nesting")
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(
                statusCode: 200,
                headers: [("content-type", "application/json")],
                body: nested
            ))
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_malformed_response"))
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "malformed")
        XCTAssertTrue(document.candidates.isEmpty)
        let encoded = try ModelSwitchingWireCodec.encode(document)
        XCTAssertFalse(encoded.contains("[[["))
    }

    func testAdmissionClientAllowsInsecureHTTPOnlyForExplicitLoopbackTesting() {
        XCTAssertNil(BYOMModelAdmissionClient.httpBaseURL(
            from: "http://127.0.0.1:11434",
            allowInsecureLoopbackHTTP: false
        ))
        XCTAssertEqual(
            BYOMModelAdmissionClient.httpBaseURL(
                from: "http://127.0.0.1:11434",
                allowInsecureLoopbackHTTP: true
            )?.absoluteString,
            "http://127.0.0.1:11434"
        )

        XCTAssertNil(BYOMModelAdmissionClient.httpBaseURL(
            from: "http://localhost:11434",
            allowInsecureLoopbackHTTP: true
        ))
        XCTAssertNil(BYOMModelAdmissionClient.httpBaseURL(
            from: "http://192.168.1.10:11434",
            allowInsecureLoopbackHTTP: true
        ))
        XCTAssertNil(BYOMModelAdmissionClient.httpBaseURL(
            from: "http://user:pass@127.0.0.1:11434",
            allowInsecureLoopbackHTTP: true
        ))
        XCTAssertNil(BYOMModelAdmissionClient.httpBaseURL(
            from: "http://127.0.0.1:11434/ws/provider",
            allowInsecureLoopbackHTTP: true
        ))
    }

    func testAdmissionClientUsesDirectNoProxyConfigurationForInsecureLoopbackTesting() throws {
        let baseURL = try XCTUnwrap(BYOMModelAdmissionClient.httpBaseURL(
            from: "http://127.0.0.1:11434",
            allowInsecureLoopbackHTTP: true
        ))
        let configuration = BYOMModelAdmissionClient.urlSessionConfiguration(for: baseURL)

        XCTAssertEqual(configuration.connectionProxyDictionary?.isEmpty, true)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testOllamaDiscoveryUsesHermeticLoopbackResponseAndRedactsUnsafeFields() async throws {
        let root = try temporaryDirectory("byom-ollama")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let leakedEndpoint = "http://127.0.0.1:11434"
        let secret = "sk-local-secret"
        let body = """
        {"models":[
          {"name":"Tiny-Ollama-1B-Q4","details":{"family":"llama","quantization_level":"Q4_0"}},
          {"name":"/Users/augstar/\(secret)<script>","details":{"family":"bad"}},
          {"name":"http://127.0.0.1:11434/\(secret)?api_key=hidden","details":{"family":"bad"}},
          {"name":"127.0.0.1:11434","details":{"family":"bad"}},
          {"name":"127.0.0.1","details":{"family":"bad"}},
          {"name":"localhost","details":{"family":"bad"}},
          {"name":"[::1]","details":{"family":"bad"}},
          {"name":"sk-local-secret","details":{"family":"bad"}},
          {"name":"ghp_abcdefghijklmnopqrstuvwxyz0123456789","details":{"family":"bad"}},
          {"name":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.signature000","details":{"family":"bad"}},
          {"name":"safe-name","details":{"family":"http://127.0.0.1:11434/\(secret)","quantization_level":"api_key=hidden"}}
        ]}
        """
        let client = StubBYOMHTTPClient(response: BYOMHTTPResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(body.utf8)
        ))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: cache,
                ollamaOrigin: leakedEndpoint
            ),
            httpClient: client
        ).discover()
        let encoded = try ModelSwitchingWireCodec.encode(document)

        XCTAssertEqual(document.candidates.count, 2)
        let candidate = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "ollama:Tiny-Ollama-1B-Q4" })
        XCTAssertEqual(candidate.runtimeSource, "ollama_loopback")
        XCTAssertEqual(candidate.servedModelRef, "ollama:Tiny-Ollama-1B-Q4")
        XCTAssertEqual(candidate.capabilities.chatCompletions, true)
        XCTAssertEqual(candidate.capabilities.family, "llama")
        XCTAssertEqual(candidate.capabilities.quantization, "Q4_0")
        let safeNameCandidate = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "ollama:safe-name" })
        XCTAssertNil(safeNameCandidate.capabilities.family)
        XCTAssertNil(safeNameCandidate.capabilities.quantization)
        XCTAssertTrue(safeNameCandidate.warningCodes.contains("capability_family_redacted"))
        XCTAssertTrue(safeNameCandidate.warningCodes.contains("capability_quantization_redacted"))
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.warningCodes, ["model_reference_redacted"])
        for warning in ["capability_family_redacted", "capability_quantization_redacted", "model_reference_redacted"] {
            XCTAssertTrue(document.warnings.contains(warning))
        }
        XCTAssertFalse(encoded.contains(leakedEndpoint))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("/Users/augstar"))
        XCTAssertFalse(encoded.contains("api_key"))
        XCTAssertFalse(encoded.contains("ghp_"))
        XCTAssertFalse(encoded.contains("eyJhbGci"))
        XCTAssertFalse(encoded.lowercased().contains("<script>"))
    }

    func testOllamaOptionalLabelsDistinguishAbsentSafeRedactedAndMalformed() async throws {
        let fields = [("family", "capability_family_redacted"), ("quantization_level", "capability_quantization_redacted")]
        for (field, warning) in fields {
            for value in [nil, NSNull(), "llama", "", "   ", String(repeating: "x", count: 65), "api_key=hidden", 7, true, ["bad"], ["bad": "value"]] as [Any?] {
                var details: [String: Any] = [:]
                if let value { details[field] = value }
                let body = try JSONSerialization.data(withJSONObject: ["models": [["name": "Tiny-Ollama-1B-Q4", "details": details]]])
                let result = await redactionDiscovery(body: body)
                let malformed = value != nil && !(value is NSNull) && !(value is String)
                if malformed {
                    XCTAssertEqual(result.adapter.status, "malformed", field)
                    XCTAssertEqual(result.adapter.warningCodes, ["adapter_malformed_response"], field)
                    XCTAssertTrue(result.candidates.isEmpty, field)
                    continue
                }
                let candidate = try XCTUnwrap(result.candidates.first)
                let redacted = (value as? String).map { $0 != "llama" } ?? false
                let label = field == "family" ? candidate.capabilities.family : candidate.capabilities.quantization
                XCTAssertEqual(label, (value as? String) == "llama" ? "llama" : nil, field)
                XCTAssertEqual(candidate.warningCodes.contains(warning), redacted, field)
                XCTAssertFalse(candidate.warningCodes.contains("adapter_malformed_response"), field)
                XCTAssertFalse(candidate.warningCodes.contains("capability_runtime_version_redacted"), field)
                XCTAssertNil(candidate.capabilities.runtimeVersion)
                XCTAssertEqual(candidate.admissionState, "offerable", field)
                XCTAssertEqual(candidate.admissionStateSource, "local_default", field)
                XCTAssertEqual(candidate.providerGuidance.earningPathClass, "local_inventory_only", field)
            }
        }
    }

    func testOllamaWithheldInventoryIsDistinctFromEmptyAndMalformedInventory() async throws {
        for (body, status, warnings) in [
            (#"{"models":[]}"#, "ok", [String]()),
            (#"{"models":[{"name":"/Users/private/model"},{"name":"api_key=hidden"}]}"#, "ok", ["model_reference_redacted"]),
            (#"{"models":[{}]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[{"name":null}]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[{"name":7}]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[false]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[{"name":"safe-model","details":7}]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[{"name":"/Users/private/model","details":7}]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[{"name":"/Users/private/model","details":{"family":7}}]}"#, "malformed", ["adapter_malformed_response"]),
            (#"{"models":[{"name":"/Users/private/model","details":{"quantization_level":false}}]}"#, "malformed", ["adapter_malformed_response"]),
        ] {
            let result = await redactionDiscovery(body: Data(body.utf8))
            XCTAssertEqual(result.adapter.status, status)
            XCTAssertEqual(result.adapter.warningCodes, warnings)
            XCTAssertTrue(result.candidates.isEmpty)
        }
    }

    func testOllamaRedactionDoesNotInspectPastExistingRecordBound() async throws {
        for withheldFirst in [false, true] {
            let first = withheldFirst ? "/Users/private/model" : "Tiny-Ollama-1B-Q4"
            let last = withheldFirst ? "Tiny-Ollama-1B-Q4" : "/Users/private/model"
            let records = Array(repeating: ["name": first], count: 100) + [["name": last]]
            let body = try JSONSerialization.data(withJSONObject: ["models": records])
            let result = await redactionDiscovery(body: body)
            XCTAssertEqual(result.adapter.status, "ok")
            XCTAssertEqual(result.candidates.count, withheldFirst ? 0 : 100)
            XCTAssertEqual(result.adapter.warningCodes, withheldFirst ? ["model_reference_redacted"] : [])
        }
    }

    func testMLXWithheldReferenceIsReportedWithoutInventingCandidate() async throws {
        let root = try temporaryDirectory("byom-mlx-redaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = BYOMMLXCacheDiscovery(cacheRoot: root, namespace: Data(repeating: 0x37, count: 32), catalogMatcher: BYOMCatalogMatcher())
        XCTAssertEqual(discovery.discover().adapter.warningCodes, [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models--mlx--api_key=hidden"), withIntermediateDirectories: true)
        let withheld = discovery.discover()
        XCTAssertEqual(withheld.adapter.status, "ok")
        XCTAssertEqual(withheld.adapter.warningCodes, ["model_reference_redacted"])
        XCTAssertTrue(withheld.candidates.isEmpty)
        try createMLXSnapshot(cacheRoot: root, modelID: "mlx-community/Tiny-1B-4bit")
        let mixed = discovery.discover()
        XCTAssertEqual(mixed.adapter.warningCodes, ["model_reference_redacted"])
        XCTAssertEqual(mixed.candidates.count, 1)
        XCTAssertEqual(mixed.candidates.first?.admissionState, "offerable")
        XCTAssertFalse(try ModelSwitchingWireCodec.encode(mixed.candidates).contains("hidden"))
    }

    func testOllamaOptionalRedactionPreservesOfferNullsAndIndependentBlockers() async throws {
        let body = Data(#"{"models":[{"name":"Tiny-Ollama-1B-Q4","details":{"family":"/Users/private/hidden","quantization_level":"api_key=hidden"}},{"name":"/Users/private/omitted"}]}"#.utf8)
        let stable = await redactionDiscovery(body: body)
        let candidate = try XCTUnwrap(stable.candidates.first)
        XCTAssertEqual(stable.candidates.count, 1)
        XCTAssertEqual(candidate.admissionState, "offerable")
        XCTAssertFalse(candidate.warningCodes.contains("model_reference_redacted"))
        XCTAssertTrue(candidate.warningCodes.contains("evaluation_required"))
        let packageWithoutEvaluation = try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-test", candidate: candidate, admissionIdentity: Curve25519.Signing.PrivateKey(),
            evaluationDigestSHA256: nil, requestedDisclosureClass: "non_earning_provider_asserted"
        )
        let packageWithEvaluation = try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-test", candidate: candidate, admissionIdentity: Curve25519.Signing.PrivateKey(),
            evaluationDigestSHA256: String(repeating: "a", count: 64), requestedDisclosureClass: "non_earning_provider_asserted"
        )
        for package in [packageWithoutEvaluation, packageWithEvaluation] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: package.encodedRequest) as? [String: Any])
            let capabilities = try XCTUnwrap(object["advisory_capabilities"] as? [String: Any])
            XCTAssertTrue(capabilities["family"] is NSNull)
            XCTAssertTrue(capabilities["quantization"] is NSNull)
            XCTAssertTrue(capabilities["runtime_version"] is NSNull)
            XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("redacted"))
            XCTAssertFalse(String(decoding: package.encodedRequest, as: UTF8.self).contains("hidden"))
        }
        let unstable = await redactionDiscovery(body: body, namespace: nil)
        let blocked = try XCTUnwrap(unstable.candidates.first)
        XCTAssertEqual(blocked.admissionState, "local_only")
        XCTAssertTrue(blocked.warningCodes.contains("candidate_id_unstable"))
        XCTAssertTrue(blocked.warningCodes.contains("capability_family_redacted"))
        XCTAssertThrowsError(try BYOMOfferSubmissionBuilder.makePackage(
            providerID: "provider-test", candidate: blocked, admissionIdentity: Curve25519.Signing.PrivateKey(),
            evaluationDigestSHA256: String(repeating: "a", count: 64), requestedDisclosureClass: "non_earning_provider_asserted"
        )) { XCTAssertEqual($0 as? BYOMModelAdmissionError, .candidateUnstable) }
    }

    func testDiscoverRedactionWarningsMatchStderrWithoutRawContent() async throws {
        let root = try temporaryDirectory("byom-redaction-stderr")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(#"{"models":[{"name":"Tiny-Ollama-1B-Q4","details":{"family":"api_key=hidden","quantization_level":"/Users/private/hidden"}},{"name":"/Users/private/omitted"},{"name":"/Users/private/omitted-again"}]}"#.utf8)
        let runtime = try OneShotHTTPServer(body: body)
        let origin = "http://127.0.0.1:\(try XCTUnwrap(runtime.url.port))"
        let command = try ModelsDiscoverCommand.parse([
            "--json", "--local-discovery-namespace-path", root.appendingPathComponent("ns").path,
            "--mlx-cache-dir", root.appendingPathComponent("hf").path,
            "--ollama-origin", origin,
        ])
        let capture = await captureBYOMOutput { try await command.run() }
        XCTAssertNil(capture.error)
        XCTAssertEqual(runtime.requestCount, 1)
        let object = try jsonObject(capture.stdout)
        let warnings = try XCTUnwrap(object["warnings"] as? [String])
        let stderrCodes = capture.stderr.split(whereSeparator: \.isNewline).map { String($0).replacingOccurrences(of: "models discover warning: ", with: "") }
        XCTAssertEqual(stderrCodes, warnings.sorted())
        XCTAssertEqual(Set(warnings).count, warnings.count)
        for warning in ["capability_family_redacted", "capability_quantization_redacted", "model_reference_redacted"] {
            XCTAssertTrue(warnings.contains(warning))
        }
        for raw in ["api_key", "hidden", "/Users/private", "omitted", origin] {
            XCTAssertFalse((capture.stdout + capture.stderr).contains(raw))
        }
    }

    private func redactionDiscovery(
        body: Data,
        namespace: Data? = Data(repeating: 0x37, count: 32)
    ) async -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        await BYOMOllamaDiscovery(
            origin: "http://127.0.0.1:11434", namespace: namespace,
            catalogMatcher: BYOMCatalogMatcher(),
            httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: body))
        ).discover()
    }

    func testRejectedAdapterOriginIsReportedWithoutEndpointLeak() async throws {
        let root = try temporaryDirectory("byom-rejected-origin")
        let origin = "http://localhost:11434"
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: origin
            ),
            httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data()))
        ).discover()
        let encoded = try ModelSwitchingWireCodec.encode(document)

        XCTAssertTrue(document.warnings.contains("adapter_rejected_non_loopback"))
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "rejected")
        XCTAssertFalse(encoded.contains(origin))
    }

    func testOversizedOllamaResponseIsTruncatedNotParsed() async throws {
        let root = try temporaryDirectory("byom-oversized")
        let body = Data(repeating: UInt8(ascii: "{"), count: BYOMDiscoveryHTTPBounds.maxBodyBytes + 1)
        let client = StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: body))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_response_truncated"))
        XCTAssertTrue(document.candidates.isEmpty)
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "truncated")
    }

    func testURLSessionClientStopsReadingOversizedLoopbackBody() async throws {
        let bodySize = 16 * 1024
        let server = try OneShotHTTPServer(
            body: Data(repeating: UInt8(ascii: "x"), count: bodySize),
            chunkSize: 256,
            chunkDelayMicroseconds: 2_000
        )

        do {
            _ = try await BYOMURLSessionHTTPClient().get(
                server.url,
                maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
                maxBodyBytes: 1024
            )
            XCTFail("expected oversized streaming response to truncate")
        } catch BYOMDiscoveryAdapterError.truncated {
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(server.bytesAttempted >= 1024)
            XCTAssertLessThan(server.bytesAttempted, bodySize)
        }
    }

    func testURLSessionClientRejectsOversizedLoopbackHeaders() async throws {
        let server = try OneShotHTTPServer(
            headers: [("X-Too-Large", String(repeating: "a", count: BYOMDiscoveryHTTPBounds.maxHeaderBytes + 1))],
            body: Data(#"{"models":[]}"#.utf8)
        )

        do {
            _ = try await BYOMURLSessionHTTPClient().get(
                server.url,
                maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
                maxBodyBytes: BYOMDiscoveryHTTPBounds.maxBodyBytes
            )
            XCTFail("expected oversized response headers to truncate")
        } catch BYOMDiscoveryAdapterError.truncated {
            XCTAssertEqual(server.requestCount, 1)
        }
    }

    func testURLSessionClientRefusesRedirects() async throws {
        let server = try OneShotHTTPServer(
            statusCode: 302,
            headers: [("Location", "http://192.168.1.10:11434/api/tags")],
            body: Data()
        )

        let response = try await BYOMURLSessionHTTPClient().get(
            server.url,
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: BYOMDiscoveryHTTPBounds.maxBodyBytes
        )

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testURLSessionClientUsesDirectNoProxyConfiguration() {
        let configuration = BYOMURLSessionHTTPClient.directLoopbackConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.isEmpty, true)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testTransportFailureIsUnavailableNotMalformed() async throws {
        let root = try temporaryDirectory("byom-transport")
        let client = StubBYOMHTTPClient(error: URLError(.cannotConnectToHost))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_unavailable"))
        XCTAssertFalse(document.warnings.contains("adapter_malformed_response"))
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "unavailable")
    }

    func testMalformedOllamaResponseEmitsWarningNotCandidate() async throws {
        let root = try temporaryDirectory("byom-malformed")
        let client = StubBYOMHTTPClient(response: BYOMHTTPResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(#"{"models":[{"name":"unterminated"}"#.utf8)
        ))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_malformed_response"))
        XCTAssertTrue(document.candidates.isEmpty)
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "malformed")
    }

    func testDiscoveryDoesNotMutateModelCache() async throws {
        let root = try temporaryDirectory("byom-readonly")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        let before = try recursiveRelativePaths(cache)

        _ = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        let after = try recursiveRelativePaths(cache)
        XCTAssertEqual(before, after)
    }

    // MARK: - openai_compatible_loopback adapter (SPEC-046-R002/R003/R004)

    // SPEC-046-R003: an OpenAI-compatible endpoint reports only a model id, so
    // every candidate it yields is an opaque endpoint — no catalog key, no size,
    // no capability claim, and local inventory state only.
    func testOpenAICompatibleAdapterEmitsOpaqueEndpointCandidate() async throws {
        let root = try temporaryDirectory("byom-openai-opaque")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try seededNamespace(in: root)

        let client = RecordingBYOMHTTPClient(response: BYOMHTTPResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(#"{"object":"list","data":[{"id":"opaque-mini-1b","object":"model"}]}"#.utf8)
        ))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: nil,
                openAICompatibleOrigin: "http://127.0.0.1:39311"
            ),
            httpClient: client
        ).discover()

        XCTAssertEqual(client.requestLog, ["GET http://127.0.0.1:39311/v1/models"])
        let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "openai_compatible_loopback" })
        XCTAssertEqual(adapter.status, "ok")
        XCTAssertEqual(adapter.originClass, "loopback_http")
        XCTAssertEqual(adapter.warningCodes, [])

        let candidate = try XCTUnwrap(document.candidates.first { $0.runtimeSource == "openai_compatible_loopback" })
        XCTAssertTrue(candidate.candidateID.hasPrefix("byom_"))
        XCTAssertFalse(candidate.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertEqual(candidate.servedModelRef, "openai_compatible:opaque-mini-1b")
        XCTAssertEqual(candidate.displayName, "opaque-mini-1b")
        XCTAssertNil(candidate.catalogModelKey)
        XCTAssertEqual(candidate.identityState, "opaque_endpoint")
        XCTAssertEqual(candidate.locality, "opaque_local_endpoint")
        XCTAssertNil(candidate.estimatedGB)
        XCTAssertNil(candidate.contextWindowTokens)
        XCTAssertEqual(candidate.capabilities, .unknown)
        XCTAssertEqual(candidate.readinessState, "ready")
        XCTAssertEqual(candidate.fitState, "unknown")
        XCTAssertEqual(candidate.evaluationState, "not_evaluated")
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertEqual(candidate.admissionStateSource, "local_default")
        XCTAssertEqual(candidate.providerGuidance.earningPathClass, "local_inventory_only")
        XCTAssertEqual(candidate.providerGuidance.nextAction, "evaluate")
        XCTAssertEqual(candidate.warningCodes, ["capability_unevaluated", "evaluation_required"])

        // Every advisory capability stays null, never false (R004).
        let encoded = try ModelSwitchingWireCodec.encode(document)
        for field in ["chat_completions", "streaming", "tool_call_passthrough", "quantization", "family", "runtime_version"] {
            XCTAssertTrue(encoded.contains("\"\(field)\":null"), "\(field) must be null, not false")
        }
    }

    // #1246: both adapter parsers read the SAME shared inventory record bound,
    // so neither can drift. This mirrors
    // `testOllamaRedactionDoesNotInspectPastExistingRecordBound` exactly: a
    // record that would be withheld sits beyond the cap and is therefore never
    // inspected, so no `model_reference_redacted` warning is raised for it.
    func testOpenAICompatibleRedactionDoesNotInspectPastSharedRecordBound() async throws {
        let bound = BYOMDiscoveryHTTPBounds.maxInventoryRecords
        for withheldFirst in [false, true] {
            let root = try temporaryDirectory("byom-openai-bound")
            defer { try? FileManager.default.removeItem(at: root) }
            let namespace = try seededNamespace(in: root)

            let first = withheldFirst ? "/Users/private/model" : "opaque-mini-1b"
            let last = withheldFirst ? "opaque-mini-1b" : "/Users/private/model"
            let records = Array(repeating: ["id": first, "object": "model"], count: bound)
                + [["id": last, "object": "model"]]
            let body = try JSONSerialization.data(withJSONObject: ["object": "list", "data": records])

            let document = await BYOMDiscoveryRunner(
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: namespace,
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: nil,
                    openAICompatibleOrigin: "http://127.0.0.1:39311"
                ),
                httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(
                    statusCode: 200,
                    headers: [("content-type", "application/json")],
                    body: body
                ))
            ).discover()

            let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "openai_compatible_loopback" })
            let candidates = document.candidates.filter { $0.runtimeSource == "openai_compatible_loopback" }
            XCTAssertEqual(adapter.status, "ok")
            XCTAssertEqual(candidates.count, withheldFirst ? 0 : bound)
            XCTAssertEqual(adapter.warningCodes, withheldFirst ? ["model_reference_redacted"] : [])
            XCTAssertFalse(try ModelSwitchingWireCodec.encode(document).contains("private"))
        }
    }

    // SPEC-046-R002: this adapter has no well-known default. Without an
    // operator-supplied origin nothing is dispatched and the adapter
    // contributes no row at all, matching the Ollama adapter's skip behaviour.
    // An absent row already means "not attempted", so the no-flag projection is
    // unchanged for existing consumers and no new status value reaches the wire.
    func testOpenAICompatibleAdapterIsNotAttemptedWithoutOperatorOrigin() async throws {
        let root = try temporaryDirectory("byom-openai-absent")
        defer { try? FileManager.default.removeItem(at: root) }

        // No `--openai-compatible-origin` default is shipped.
        XCTAssertNil(try ModelsDiscoverCommand.parse(["--json"]).openaiCompatibleOrigin)
        // The legacy catalog commands stay outside this taxonomy (SPEC-046-R001).
        XCTAssertThrowsError(try ModelsListCommand.parse(["--json", "--openai-compatible-origin", "http://127.0.0.1:1"]))

        let client = RecordingBYOMHTTPClient()
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: nil
            ),
            httpClient: client
        ).discover()

        XCTAssertEqual(client.requestLog, [])
        XCTAssertNil(document.adapters.first { $0.runtimeSource == "openai_compatible_loopback" })
        XCTAssertTrue(document.candidates.allSatisfy { $0.runtimeSource != "openai_compatible_loopback" })
        // Same shape the Ollama adapter already had when it is not attempted.
        XCTAssertNil(document.adapters.first { $0.runtimeSource == "ollama_loopback" })
        // Every emitted adapter status stays inside the existing vocabulary.
        for adapter in document.adapters {
            XCTAssertTrue(
                ["ok", "unavailable", "timeout", "malformed", "truncated", "rejected"].contains(adapter.status),
                "unexpected adapter status \(adapter.status)"
            )
        }
    }

    // SPEC-046-R002/R007: a non-loopback origin is rejected by the shared
    // validator before any request is dispatched, and the rejected endpoint is
    // never echoed into stdout JSON or stderr diagnostics.
    func testOpenAICompatibleAdapterRejectsNonLoopbackOriginBeforeDispatch() async throws {
        let root = try temporaryDirectory("byom-openai-reject")
        defer { try? FileManager.default.removeItem(at: root) }

        for origin in ["http://0.0.0.0:39311", "http://192.168.1.10:39311", "http://localhost:39311", "https://127.0.0.1:39311"] {
            let client = RecordingBYOMHTTPClient()
            let document = await BYOMDiscoveryRunner(
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: root.appendingPathComponent("ns"),
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: nil,
                    openAICompatibleOrigin: origin
                ),
                httpClient: client
            ).discover()

            XCTAssertEqual(client.requestLog, [], "dispatched a request for \(origin)")
            let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "openai_compatible_loopback" })
            XCTAssertEqual(adapter.status, "rejected")
            XCTAssertEqual(adapter.originClass, "rejected")
            XCTAssertEqual(adapter.warningCodes, ["adapter_rejected_non_loopback"])
            XCTAssertTrue(document.candidates.isEmpty)
            let encoded = try ModelSwitchingWireCodec.encode(document)
            XCTAssertFalse(encoded.contains(origin), "rejection leaked \(origin)")
        }
    }

    // SPEC-046-R002: every adapter failure class maps to a closed warning code
    // and produces no candidate and no partial trust claim.
    func testOpenAICompatibleAdapterFailureClassesMapToClosedWarningCodes() async throws {
        let root = try temporaryDirectory("byom-openai-failures")
        defer { try? FileManager.default.removeItem(at: root) }

        let oversized = Data(repeating: 0x20, count: BYOMDiscoveryHTTPBounds.maxBodyBytes + 1)
        let cases: [(client: StubBYOMHTTPClient, status: String, warning: String)] = [
            (StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 503, headers: [], body: Data())), "unavailable", "adapter_unavailable"),
            (StubBYOMHTTPClient(error: URLError(.timedOut)), "timeout", "adapter_timeout"),
            (StubBYOMHTTPClient(response: BYOMHTTPResponse(
                statusCode: 200,
                headers: [("content-type", "application/json")],
                body: Data(#"{"data":"not-an-array"}"#.utf8)
            )), "malformed", "adapter_malformed_response"),
            (StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: oversized)), "truncated", "adapter_response_truncated"),
        ]

        for testCase in cases {
            let document = await BYOMDiscoveryRunner(
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: root.appendingPathComponent("ns"),
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: nil,
                    openAICompatibleOrigin: "http://127.0.0.1:39311"
                ),
                httpClient: testCase.client
            ).discover()

            let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "openai_compatible_loopback" })
            XCTAssertEqual(adapter.status, testCase.status)
            XCTAssertEqual(adapter.warningCodes, [testCase.warning])
            XCTAssertTrue(document.candidates.isEmpty, "\(testCase.warning) fabricated a candidate")
            XCTAssertTrue(document.warnings.contains(testCase.warning))
        }
    }

    // SPEC-046-R007: an unsafe model id is withheld entirely — no placeholder
    // candidate, no synthesized identity — and only the fixed provenance code is
    // retained. A safe sibling in the same inventory stays visible.
    func testOpenAICompatibleUnsafeModelIDsAreWithheldWithoutPlaceholder() async throws {
        let root = try temporaryDirectory("byom-openai-redaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try seededNamespace(in: root)

        let unsafeIDs = [
            "coordinator.malibu.tech:443",
            "hf.co/library/x",
            "sk-live-abcdefghijklmnopqrstuvwxyz",
            "http://127.0.0.1:9/models",
            "127.0.0.1:11434",
        ]
        let body = #"{"data":["# + (unsafeIDs + ["safe-mini-1b"])
            .map { #"{"id":"\#($0)"}"# }
            .joined(separator: ",") + "]}"

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: nil,
                openAICompatibleOrigin: "http://127.0.0.1:39311"
            ),
            httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(
                statusCode: 200,
                headers: [("content-type", "application/json")],
                body: Data(body.utf8)
            ))
        ).discover()

        let adapter = try XCTUnwrap(document.adapters.first { $0.runtimeSource == "openai_compatible_loopback" })
        XCTAssertEqual(adapter.status, "ok")
        XCTAssertEqual(adapter.warningCodes, ["model_reference_redacted"])
        XCTAssertTrue(document.warnings.contains("model_reference_redacted"))
        let candidates = document.candidates.filter { $0.runtimeSource == "openai_compatible_loopback" }
        XCTAssertEqual(candidates.map(\.servedModelRef), ["openai_compatible:safe-mini-1b"])
        let encoded = try ModelSwitchingWireCodec.encode(document)
        for unsafeID in unsafeIDs {
            XCTAssertFalse(encoded.contains(unsafeID), "withheld id leaked: \(unsafeID)")
        }
    }

    // SPEC-046-R002 "bounded JSON nesting/parser work": the shared strict parser
    // turns a pathologically nested but under-cap body into the closed
    // malformed code rather than a stack overflow.
    func testOpenAICompatibleParserBoundsRejectPathologicalNesting() throws {
        let depth = 20_000
        let nested = Data((
            #"{"data":["# + String(repeating: "[", count: depth)
                + String(repeating: "]", count: depth) + "]}"
        ).utf8)
        XCTAssertLessThan(nested.count, BYOMDiscoveryHTTPBounds.maxBodyBytes)
        for hostile in [nested, Data(String(repeating: "{", count: 50_000).utf8)] {
            XCTAssertThrowsError(try BYOMDiscoveryJSON.parseOpenAIModels(hostile)) { error in
                guard case BYOMDiscoveryAdapterError.malformed = error else {
                    return XCTFail("expected malformed, got \(error)")
                }
            }
        }
        // A wrong-typed id is a malformed response, not a privacy redaction.
        XCTAssertThrowsError(try BYOMDiscoveryJSON.parseOpenAIModels(Data(#"{"data":[{"id":7}]}"#.utf8)))
    }

    // SPEC-046-R003: the candidate id is the namespace-scoped HMAC over
    // `runtime_source || 0x00 || normalized served_model_ref`, so it is stable
    // across runs and never collides with another adapter's id for the same
    // model name.
    func testOpenAICompatibleCandidateIDIsStableAndScopedByRuntimeSource() throws {
        let namespace = Data(repeating: 0x5b, count: 32)
        let (first, firstWarnings) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "openai_compatible_loopback",
            servedModelRef: "openai_compatible:opaque-mini-1b"
        )
        let (second, _) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "openai_compatible_loopback",
            servedModelRef: "openai_compatible:Opaque-Mini-1B"
        )
        let (ollama, _) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "ollama_loopback",
            servedModelRef: "openai_compatible:opaque-mini-1b"
        )
        XCTAssertEqual(firstWarnings, [])
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, ollama)
        XCTAssertNotNil(first.range(of: #"^byom_[a-z2-7]{52}$"#, options: .regularExpression))
    }

    // SPEC-046-R003 / SPEC-047: an opaque endpoint has no artifact hash and no
    // catalog key, so the dry-run must not claim a catalog earning path and must
    // not predict a submittable offer.
    func testOpenAICompatibleOfferDryRunClaimsNoCatalogPath() async throws {
        let root = try temporaryDirectory("byom-openai-dryrun")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try seededNamespace(in: root)

        let document = await BYOMOfferDryRunRunner(
            target: "openai_compatible:opaque-mini-1b",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: nil,
                openAICompatibleOrigin: "http://127.0.0.1:39311"
            ),
            httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(
                statusCode: 200,
                headers: [("content-type", "application/json")],
                body: Data(#"{"data":[{"id":"opaque-mini-1b"}]}"#.utf8)
            ))
        ).dryRun()

        XCTAssertEqual(document.servedModelRef, "openai_compatible:opaque-mini-1b")
        XCTAssertNil(document.catalogModelKey)
        XCTAssertFalse(document.wouldSubmit)
        XCTAssertEqual(document.likelyAdmissionState, "local_only")
        XCTAssertEqual(document.likelyAdmissionStateSource, "local_default")
        XCTAssertEqual(document.reasonCode, "no_trusted_catalog_match")
        XCTAssertEqual(document.providerGuidance.earningPathClass, "local_inventory_only")
        XCTAssertNotEqual(
            document.providerGuidance.stateMeaningKey,
            "byom.offer_dry_run.catalog_path_missing_trusted_binding"
        )
    }

    /// 0700 directory holding an 0600 32-byte salt, so discovery reports stable
    /// `byom_` ids instead of `byom_unstable_` ones.
    private func seededNamespace(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("nsdir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let namespace = directory.appendingPathComponent("ns")
        try Data(repeating: 0x5b, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namespace.path)
        return namespace
    }

    private func createMLXSnapshot(
        cacheRoot: URL,
        modelID: String,
        configJSON: String = #"{"max_position_embeddings":2048}"#
    ) throws {
        let repo = cacheRoot
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(configJSON.utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0x7a, count: 128).write(to: repo.appendingPathComponent("model.safetensors"))
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonObject(_ stdout: String) throws -> [String: Any] {
        let line = try XCTUnwrap(stdout.split(whereSeparator: \.isNewline).first { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func recursiveRelativePaths(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            result.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return result.sorted()
    }
}

private final class StubBYOMHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    let response: BYOMHTTPResponse?
    let error: Error?

    init(response: BYOMHTTPResponse) {
        self.response = response
        self.error = nil
    }

    init(error: Error) {
        self.response = nil
        self.error = error
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        if let error {
            throw error
        }
        return try XCTUnwrap(response)
    }
}

/// Hermetic client that records every request URL the shared safety layer
/// dispatches, so a test can prove the closed endpoint allowlist (no port or
/// network scanning) from the request log rather than from adapter internals.
private final class RecordingBYOMHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let response: BYOMHTTPResponse?
    private let error: Error?

    var requestLog: [String] {
        lock.withLock { log }
    }

    init(response: BYOMHTTPResponse? = nil, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock { log.append("GET \(url.absoluteString)") }
        if let error { throw error }
        return response ?? BYOMHTTPResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(#"{"models":[]}"#.utf8)
        )
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock { log.append("POST \(url.absoluteString)") }
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }
}

/// Loopback listener that completes the TCP handshake (kernel backlog) and then
/// never answers, so a request against it hits the shared client's short request
/// timeout instead of failing to connect.
private final class SilentLoopbackListener {
    let port: UInt16
    private let socketFD: Int32

    var origin: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard Darwin.listen(fd, 8) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        port = UInt16(bigEndian: bound.sin_port)
    }

    deinit {
        Darwin.close(socketFD)
    }
}

private final class OneShotHTTPServer {
    let url: URL
    private let socketFD: Int32
    private let lock = NSLock()
    private var attempted = 0

    var bytesAttempted: Int {
        lock.withLock { attempted }
    }

    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    init(
        statusCode: Int = 200,
        headers: [(String, String)] = [],
        body: Data,
        chunkSize: Int = 512,
        chunkDelayMicroseconds: useconds_t = 0
    ) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard Darwin.listen(fd, 1) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: bound.sin_port))/api/tags"))

        DispatchQueue.global(qos: .userInitiated).async { [fd, weak self] in
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }

            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = Darwin.read(client, &buffer, buffer.count)

            self?.recordRequest()

            var responseHeaders = [
                "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))",
                "Content-Type: application/json",
                "Content-Length: \(body.count)",
                "Connection: close",
            ]
            responseHeaders.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
            let header = responseHeaders.joined(separator: "\r\n") + "\r\n\r\n"
            guard Self.writeAll(data: Data(header.utf8), to: client) else { return }
            var offset = 0
            while offset < body.count {
                let next = min(offset + chunkSize, body.count)
                let chunk = body[offset..<next]
                self?.recordAttempt(chunk.count)
                guard Self.writeAll(data: Data(chunk), to: client) else { return }
                offset = next
                if chunkDelayMicroseconds > 0 {
                    usleep(chunkDelayMicroseconds)
                }
            }
        }
    }

    deinit {
        Darwin.close(socketFD)
    }

    private func recordAttempt(_ count: Int) {
        lock.withLock {
            attempted += count
        }
    }

    private func recordRequest() {
        lock.withLock {
            requests += 1
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 302:
            return "Found"
        default:
            return "Status"
        }
    }

    private static func writeAll(data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent)
                if result <= 0 {
                    return false
                }
                sent += result
            }
            return true
        }
    }
}

private struct BYOMCapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureBYOMOutput(_ body: () async throws -> Void) async -> BYOMCapturedOutput {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let savedStdout = dup(STDOUT_FILENO)
    let savedStderr = dup(STDERR_FILENO)
    dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let error: Error?
    do {
        try await body()
        error = nil
    } catch let caught {
        error = caught
    }

    fflush(stdout)
    fflush(stderr)
    dup2(savedStdout, STDOUT_FILENO)
    dup2(savedStderr, STDERR_FILENO)
    close(savedStdout)
    close(savedStderr)
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return BYOMCapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
