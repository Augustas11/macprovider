import ArgumentParser
import CryptoKit
import Foundation

// `macprovider-cli creator`: SPEC-043 0.3.0 self-serve private Trusted Pools
// (#1880). An outside creator signs everything on its own Mac and talks only
// to the public gateway's /v1/creator/* surface with its account API key. The
// root issuer, manifest authority, and policy signer keys are generated here,
// stored owner-only under the creator home, and never sent anywhere.

struct CreatorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "creator",
        abstract: "Run a private Trusted Pool as its creator (accept, sign, admit, authorize, promote, earn).",
        discussion: """
        Typical flow:
          creator login --api-key-stdin
          creator agree --display-name ... --legal-contact ... --billing-contact ... --emergency-endpoint ... --yes
          creator keygen                     (prints the new pool id)
          creator pool create --pool <id>
          creator register-root --pool <id> --display-name "My Pool"
          creator manifest sign --pool <id> --models-file models.json
          creator manifest submit --pool <id>
          creator admit <provider-id> --pool <id>
          creator authorize-buyer <account-id> --pool <id>
          creator promote --pool <id>
          (restart macprovider-cli on each member Mac, then run
           `macprovider-cli models offer --yes` there for each pool model)
          creator status --pool <id>
          creator earnings --pool <id>
        A member serving an uncatalogued pool model is admitted to the pool's
        routes by its first hello after promotion, so restart it once the pool
        is active.
        Keys live under ~/.config/macprovider/creator (MACPROVIDER_CREATOR_HOME overrides) and never leave this Mac.
        """,
        subcommands: [
            CreatorLoginCommand.self, CreatorAgreeCommand.self, CreatorKeygenCommand.self, CreatorRegisterRootCommand.self,
            CreatorPoolCommand.self, CreatorManifestCommand.self, CreatorAdmitCommand.self, CreatorAuthorizeBuyerCommand.self,
            CreatorPromoteCommand.self, CreatorStatusCommand.self, CreatorProvidersCommand.self, CreatorEarningsCommand.self,
            CreatorRevokeCommand.self, CreatorLifecycleCommand.self,
        ]
    )
}

// MARK: - Local state

enum CreatorCLIError: Error, CustomStringConvertible {
    case notLoggedIn
    case invalidInput(String)
    case missingPool(String)
    case http(status: Int, body: String)
    case transport(String)

    var description: String {
        switch self {
        case .notLoggedIn: return "not logged in; run `macprovider-cli creator login` first"
        case let .invalidInput(message): return message
        case let .missingPool(poolID): return "no local keys for pool \(poolID); run `creator keygen` on the Mac that owns them"
        case let .http(status, body): return "gateway answered HTTP \(status): \(body)"
        case let .transport(message): return "gateway request failed: \(message)"
        }
    }
}

struct CreatorLogin: Codable, Equatable {
    var gatewayURL: String
    var apiKey: String

    enum CodingKeys: String, CodingKey {
        case gatewayURL = "gateway_url"
        case apiKey = "api_key"
    }
}

/// Public half written by keygen: no private key material.
struct CreatorPoolIdentity: Codable, Equatable {
    var schemaVersion = "macprovider.creator-pool-identity.v1"
    var poolID: String
    var genesisNonce: Data
    var rootIssuerKeyID: String
    var manifestAuthorityKeyID: String
    var manifestAuthorityPublicKey: Data
    var policySignerKeyID: String
    var policySignerPublicKey: Data
    var rootIssuerPublicKeyDER: Data
    var rootIssuerPublicKeyFingerprint: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case poolID = "pool_id"
        case genesisNonce = "genesis_nonce"
        case rootIssuerKeyID = "root_issuer_key_id"
        case manifestAuthorityKeyID = "manifest_authority_key_id"
        case manifestAuthorityPublicKey = "manifest_authority_public_key"
        case policySignerKeyID = "policy_signer_key_id"
        case policySignerPublicKey = "policy_signer_public_key"
        case rootIssuerPublicKeyDER = "root_issuer_public_key_der"
        case rootIssuerPublicKeyFingerprint = "root_issuer_public_key_fingerprint"
    }

    var identityCore: PoolIdentityCore {
        PoolIdentityCore(rootIssuerKeyID: manifestAuthorityKeyID, genesisNonce: genesisNonce)
    }
}

/// Owner-only private keys (raw representations).
struct CreatorPoolKeys: Codable {
    var rootIssuerP256: Data
    var manifestAuthorityEd25519: Data
    var policySignerEd25519: Data

    enum CodingKeys: String, CodingKey {
        case rootIssuerP256 = "root_issuer_p256"
        case manifestAuthorityEd25519 = "manifest_authority_ed25519"
        case policySignerEd25519 = "policy_signer_ed25519"
    }
}

/// The last manifest the coordinator accepted, kept structured so the next
/// version re-encodes without a snapshot decoder.
struct CreatorManifestState: Codable, Equatable {
    var snapshot: PoolManifestSnapshot
    var manifestVersion: UInt64
    var manifestCoreDigest: String

    enum CodingKeys: String, CodingKey {
        case snapshot
        case manifestVersion = "manifest_version"
        case manifestCoreDigest = "manifest_core_digest"
    }
}

struct CreatorPendingManifest: Codable, Equatable {
    var state: CreatorManifestState
    var event: [String: CreatorJSON]
}

/// A minimal JSON value for event bodies that must round-trip exactly.
enum CreatorJSON: Codable, Equatable {
    case string(String)
    case number(UInt64)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(UInt64.self) {
            self = .number(n)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        }
    }

    var anyValue: Any {
        switch self {
        case let .string(s): return s
        case let .number(n): return n
        }
    }
}

/// The exact signed root registration awaiting a definitive answer.
struct CreatorPendingRootRegistration: Codable {
    let operationID: String
    let event: Data

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case event
    }
}

struct CreatorHome {
    let root: URL

    static let defaultGatewayURL = "https://api.malibu.tech"

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> CreatorHome {
        if let override = environment["MACPROVIDER_CREATOR_HOME"], !override.isEmpty {
            return CreatorHome(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CreatorHome(root: home.appendingPathComponent(".config/macprovider/creator", isDirectory: true))
    }

    var loginURL: URL { root.appendingPathComponent("login.json") }

    func poolDir(_ poolID: String) -> URL { root.appendingPathComponent("pools", isDirectory: true).appendingPathComponent(poolID, isDirectory: true) }

    func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func write<T: Encodable>(_ value: T, to url: URL, mode: Int) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: mode])
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func login() throws -> CreatorLogin {
        guard FileManager.default.fileExists(atPath: loginURL.path) else { throw CreatorCLIError.notLoggedIn }
        return try read(CreatorLogin.self, from: loginURL)
    }

    func identity(_ poolID: String) throws -> CreatorPoolIdentity {
        let url = poolDir(poolID).appendingPathComponent("identity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CreatorCLIError.missingPool(poolID) }
        return try read(CreatorPoolIdentity.self, from: url)
    }

    func keys(_ poolID: String) throws -> CreatorPoolKeys {
        let url = poolDir(poolID).appendingPathComponent("keys.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CreatorCLIError.missingPool(poolID) }
        return try read(CreatorPoolKeys.self, from: url)
    }

    /// Operation ids awaiting a definitive answer, per pool. A retry after a
    /// transport failure or a 5xx reuses the id, so the coordinator replays
    /// the first write instead of appending a second one.
    func pendingOperationsURL(_ poolID: String) -> URL { poolDir(poolID).appendingPathComponent("pending-operations.json") }

    func stickyOperationID(poolID: String, key: String, label: String) throws -> String {
        let url = pendingOperationsURL(poolID)
        var pending = FileManager.default.fileExists(atPath: url.path) ? try read([String: String].self, from: url) : [:]
        if let existing = pending[key] { return existing }
        let id = CreatorOutput.operationID(label)
        pending[key] = id
        try write(pending, to: url, mode: 0o600)
        return id
    }

    func clearOperationID(poolID: String, key: String) throws {
        let url = pendingOperationsURL(poolID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var pending = try read([String: String].self, from: url)
        guard pending.removeValue(forKey: key) != nil else { return }
        try write(pending, to: url, mode: 0o600)
    }

    func manifestState(_ poolID: String) throws -> CreatorManifestState? {
        let url = poolDir(poolID).appendingPathComponent("manifest-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(CreatorManifestState.self, from: url)
    }
}

// MARK: - Gateway client

struct CreatorResponse {
    let status: Int
    let body: Data

    func json() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

protocol CreatorTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CreatorResponse
}

struct URLSessionCreatorTransport: CreatorTransport {
    func send(_ request: URLRequest) async throws -> CreatorResponse {
        let session = URLSession(configuration: .ephemeral, delegate: ClaimRefreshRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CreatorCLIError.transport("non-HTTP response") }
            return CreatorResponse(status: http.statusCode, body: data)
        } catch let error as CreatorCLIError {
            throw error
        } catch {
            throw CreatorCLIError.transport(String(describing: error))
        }
    }
}

struct CreatorClient {
    let login: CreatorLogin
    let transport: CreatorTransport

    static func validatedGatewayURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw CreatorCLIError.invalidInput("--gateway-url must be an absolute URL")
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw CreatorCLIError.invalidInput("--gateway-url must be https (http only for loopback)")
        }
        return url
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, operationID: String? = nil) async throws -> CreatorResponse {
        let base = try Self.validatedGatewayURL(login.gatewayURL)
        guard var components = URLComponents(url: base.appendingPathComponent("v1/creator/" + path), resolvingAgainstBaseURL: false) else {
            throw CreatorCLIError.invalidInput("invalid gateway URL")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CreatorCLIError.invalidInput("invalid request path") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(login.apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        if let operationID { request.setValue(operationID, forHTTPHeaderField: "Idempotency-Key") }
        return try await transport.send(request)
    }

    func expect(_ response: CreatorResponse, _ accepted: Set<Int> = [200, 201, 202]) throws -> [String: Any] {
        guard accepted.contains(response.status) else {
            throw CreatorCLIError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        return response.json()
    }
}

enum CreatorOutput {
    static func printJSON(_ object: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func operationID(_ label: String) -> String {
        "creator-\(label)-\(UUID().uuidString.lowercased())"
    }
}

struct CreatorContext {
    let home: CreatorHome
    let client: CreatorClient

    static func load(transport: CreatorTransport = URLSessionCreatorTransport()) throws -> CreatorContext {
        let home = CreatorHome.resolve()
        return CreatorContext(home: home, client: CreatorClient(login: try home.login(), transport: transport))
    }
}

// MARK: - Operations (pure enough to test with a fake transport)

enum CreatorOperations {
    static let rootIssuerKeyID = "root-1"
    static let manifestAuthorityKeyID = "manifest-authority-1"
    static let policySignerKeyID = "policy-signer-1"
    static let genesisSignerSetNotBefore: UInt64 = 1
    static let genesisSignerSetExpiresAt: UInt64 = 9_999_999_999
    static let custodyDisclosure = #"{"class":"software","description":"Generated and held by macprovider-cli creator on the creator's Mac; never uploaded."}"#

    static func keygen(home: CreatorHome) throws -> CreatorPoolIdentity {
        let root = P256.Signing.PrivateKey()
        let authority = Curve25519.Signing.PrivateKey()
        let policy = Curve25519.Signing.PrivateKey()
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CreatorCLIError.invalidInput("could not read secure random bytes") }
        let der = root.publicKey.derRepresentation
        let core = PoolIdentityCore(rootIssuerKeyID: manifestAuthorityKeyID, genesisNonce: nonce)
        let identity = CreatorPoolIdentity(
            poolID: try core.poolID(), genesisNonce: nonce, rootIssuerKeyID: rootIssuerKeyID,
            manifestAuthorityKeyID: manifestAuthorityKeyID, manifestAuthorityPublicKey: authority.publicKey.rawRepresentation,
            policySignerKeyID: policySignerKeyID, policySignerPublicKey: policy.publicKey.rawRepresentation,
            rootIssuerPublicKeyDER: der, rootIssuerPublicKeyFingerprint: CreatorRootSigning.fingerprint(spkiDER: der)
        )
        let dir = home.poolDir(identity.poolID)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw CreatorCLIError.invalidInput("pool directory already exists: \(dir.path)")
        }
        try home.ensureDirectory(dir)
        try home.write(CreatorPoolKeys(
            rootIssuerP256: root.rawRepresentation,
            manifestAuthorityEd25519: authority.rawRepresentation,
            policySignerEd25519: policy.rawRepresentation
        ), to: dir.appendingPathComponent("keys.json"), mode: 0o600)
        try home.write(identity, to: dir.appendingPathComponent("identity.json"), mode: 0o644)
        return identity
    }

    static func me(_ client: CreatorClient) async throws -> [String: Any] {
        let body = try client.expect(try await client.request("GET", "me"))
        guard let creator = body["creator"] as? [String: Any] else {
            throw CreatorCLIError.invalidInput("no creator approval; run `creator agree` first")
        }
        return creator
    }

    static func createPool(home: CreatorHome, client: CreatorClient, poolID: String) async throws -> [String: Any] {
        let identity = try home.identity(poolID)
        let approval = try await me(client)
        guard let approvalID = approval["approval_record_id"] as? String else {
            throw CreatorCLIError.invalidInput("creator approval has no approval_record_id")
        }
        let snapshot = PoolManifestSnapshot(
            rootIssuerKeyID: identity.manifestAuthorityKeyID, genesisNonce: identity.genesisNonce,
            rootIssuerKey: PoolSignerKey(keyID: identity.manifestAuthorityKeyID, publicKey: identity.manifestAuthorityPublicKey),
            authorityLog: [], policies: []
        )
        let event: [String: Any] = [
            "event_type": "pool_created",
            "pool_id": poolID,
            "approval_record_id": approvalID,
            "manifest_snapshot": try snapshot.canonicalBytes().base64EncodedString(),
        ]
        return try client.expect(try await client.request("POST", "events", body: event, operationID: "creator-create-\(poolID)"))
    }

    static func registerRoot(home: CreatorHome, client: CreatorClient, poolID: String, displayName: String) async throws -> [String: Any] {
        let identity = try home.identity(poolID)
        let keys = try home.keys(poolID)
        let root = try P256.Signing.PrivateKey(rawRepresentation: keys.rootIssuerP256)
        guard root.publicKey.derRepresentation == identity.rootIssuerPublicKeyDER else {
            throw CreatorCLIError.invalidInput("root issuer key does not match identity.json")
        }
        // A registration is signed over a one-time nonce, so a retry must resend
        // the exact signed event under its operation id; re-signing would make
        // the coordinator see a conflicting payload for an already-committed op.
        let pendingURL = home.poolDir(poolID).appendingPathComponent("root-registration-pending.json")
        if FileManager.default.fileExists(atPath: pendingURL.path) {
            let pending = try home.read(CreatorPendingRootRegistration.self, from: pendingURL)
            guard let event = try JSONSerialization.jsonObject(with: pending.event) as? [String: Any] else {
                throw CreatorCLIError.invalidInput("malformed root-registration-pending.json")
            }
            return try await sendPendingRootRegistration(client: client, pendingURL: pendingURL, operationID: pending.operationID, event: event)
        }
        let nonceBody = try client.expect(try await client.request("POST", "root-registration-nonces", body: [:], operationID: CreatorOutput.operationID("nonce")))
        guard let nonce = nonceBody["root_registration_nonce"] as? [String: Any],
              let creatorID = nonce["creator_account_id"] as? String,
              let approvalID = nonce["approval_record_id"] as? String,
              let approvalVersion = nonce["current_approval_version"] as? String,
              let environment = nonce["launch_environment"] as? String,
              let nonceValue = nonce["nonce"] as? String,
              let expiry = nonce["expires_at_utc"] as? String
        else {
            throw CreatorCLIError.invalidInput("malformed root registration nonce response")
        }
        let fields: [String: String] = [
            "approval_record_id": approvalID,
            "creator_account_id": creatorID,
            "current_approval_version": approvalVersion,
            "environment": environment,
            "genesis_nonce_digest": PoolBytes.hex(PoolBytes.sha256(identity.genesisNonce)),
            "intended_pool_display_name_hash": PoolBytes.hex(PoolBytes.sha256(Data(displayName.utf8))),
            "launch_environment": environment,
            "nonce": nonceValue,
            "nonce_expiry": expiry,
            "purpose": CreatorRootSigning.purpose,
            "root_issuer_key_id": identity.rootIssuerKeyID,
            "root_issuer_public_key_fingerprint": identity.rootIssuerPublicKeyFingerprint,
            "root_signature_algorithm": CreatorRootSigning.algorithm,
            "manifest_authority_root_key_id": identity.manifestAuthorityKeyID,
            "manifest_authority_root_public_key": identity.manifestAuthorityPublicKey.base64EncodedString(),
            "structured_key_custody_disclosure_hash": PoolBytes.hex(PoolBytes.sha256(Data(custodyDisclosure.utf8))),
        ]
        let signature = try CreatorRootSigning.signP256(root, try CreatorRootSigning.rootRegistrationMessage(fields))
        var event: [String: Any] = fields
        event["event_type"] = "root_issuer_registered"
        event["pool_id"] = poolID
        event["root_issuer_public_key_der"] = identity.rootIssuerPublicKeyDER.base64EncodedString()
        event["proof_of_possession_signature"] = signature
        let operationID = CreatorOutput.operationID("root")
        let encoded = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        try home.write(CreatorPendingRootRegistration(operationID: operationID, event: encoded), to: pendingURL, mode: 0o600)
        return try await sendPendingRootRegistration(client: client, pendingURL: pendingURL, operationID: operationID, event: event)
    }

    /// Sends the persisted registration unchanged and forgets it only on a
    /// definitive answer (see `isDefinitive`). A replay of a committed registration is
    /// answered as success by the coordinator's idempotent replay.
    static func sendPendingRootRegistration(client: CreatorClient, pendingURL: URL, operationID: String, event: [String: Any]) async throws -> [String: Any] {
        let response = try await client.request("POST", "events", body: event, operationID: operationID)
        if CreatorOperations.isDefinitive(response.status) { try FileManager.default.removeItem(at: pendingURL) }
        return try client.expect(response)
    }

    struct ManifestOptions {
        var models: [String] = []
        var modelEntries: [PoolModelEntry] = []
        var attestedMembers: [PoolAttestedMember] = []
        var settlementMode = "enforce"
        var retentionPolicyID = "standard"
        var minBinaryVersion = "1.8.0"
        var minAttestationTier = "self_signed"
        var minEligibleMembers: UInt64 = 1
        var notBefore = Date()
        var validityDays = 90
    }

    struct ModelsFile: Decodable {
        var modelEntries: [PoolModelEntry]?
        var attestedMembers: [PoolAttestedMember]?

        enum CodingKeys: String, CodingKey {
            case modelEntries = "model_entries"
            case attestedMembers = "attested_members"
        }
    }

    static func loadModelsFile(_ path: String) throws -> ([PoolModelEntry], [PoolAttestedMember]) {
        let file = try JSONDecoder().decode(ModelsFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let entries = (file.modelEntries ?? []).map { entry -> PoolModelEntry in
            var e = entry
            e.allowedRuntimeSources.sort(by: PoolBytes.byteLess)
            return e
        }.sorted { PoolBytes.byteLess($0.poolModelID, $1.poolModelID) }
        let members = (file.attestedMembers ?? []).map { member -> PoolAttestedMember in
            var m = member
            m.runtimeClasses.sort(by: PoolBytes.byteLess)
            return m
        }.sorted { PoolBytes.byteLess($0.providerAccountID, $1.providerAccountID) }
        return (entries, members)
    }

    /// Builds and signs the next manifest_accepted event and stores it as
    /// pending; nothing is sent.
    static func signManifest(home: CreatorHome, poolID: String, options: ManifestOptions) throws -> CreatorPendingManifest {
        let identity = try home.identity(poolID)
        let keys = try home.keys(poolID)
        let root = try P256.Signing.PrivateKey(rawRepresentation: keys.rootIssuerP256)
        let policySigner = try Curve25519.Signing.PrivateKey(rawRepresentation: keys.policySignerEd25519)
        let previous = try home.manifestState(poolID)

        var allowlist = options.models
        for entry in options.modelEntries where !allowlist.contains(entry.poolModelID) {
            allowlist.append(entry.poolModelID)
        }
        guard !allowlist.isEmpty else { throw CreatorCLIError.invalidInput("name at least one model (--models or --models-file)") }
        let externalRuntimes = Set(options.modelEntries.flatMap(\.allowedRuntimeSources)).subtracting(["mlx_cache"])
        var extensions: [PoolPolicyExtension] = []
        if !options.attestedMembers.isEmpty {
            extensions.append(PoolPolicyExtension(id: PoolExtensions.attestedMembersV1, body: try PoolExtensions.encodeAttestedMembers(options.attestedMembers)))
        }
        if !options.modelEntries.isEmpty {
            extensions.append(PoolPolicyExtension(id: PoolExtensions.modelEntriesV1, body: try PoolExtensions.encodeModelEntries(options.modelEntries)))
        }
        var notBefore = UInt64(max(1, options.notBefore.timeIntervalSince1970.rounded(.down)))
        var snapshot: PoolManifestSnapshot
        let version: UInt64
        let prevHash: Data
        if let previous {
            snapshot = previous.snapshot
            version = previous.manifestVersion + 1
            guard let digest = PoolBytes.fromHex(previous.manifestCoreDigest), digest.count == 32,
                  let prevCore = previous.snapshot.policies.last?.core
            else {
                throw CreatorCLIError.invalidInput("local manifest state is corrupt")
            }
            prevHash = digest
            notBefore = max(notBefore, prevCore.expiresAtUnix)
        } else {
            let authority = try Curve25519.Signing.PrivateKey(rawRepresentation: keys.manifestAuthorityEd25519)
            version = 1
            prevHash = Data(count: 32)
            var entry = PoolAuthorityLogEntry(
                poolID: poolID, signerSetVersion: 1, prevAuthorityLogEntryHash: Data(count: 32),
                keys: [PoolSignerKey(keyID: identity.policySignerKeyID, publicKey: identity.policySignerPublicKey)],
                threshold: 1, notBeforeUnix: genesisSignerSetNotBefore, expiresAtUnix: genesisSignerSetExpiresAt,
                revokesVersions: [], authorizingSignerSetVersion: 0, signatures: []
            )
            entry.signatures = [PoolSignature(keyID: identity.manifestAuthorityKeyID, sig: try authority.signature(for: try entry.signingMessage()))]
            snapshot = PoolManifestSnapshot(
                rootIssuerKeyID: identity.manifestAuthorityKeyID, genesisNonce: identity.genesisNonce,
                rootIssuerKey: PoolSignerKey(keyID: identity.manifestAuthorityKeyID, publicKey: identity.manifestAuthorityPublicKey),
                authorityLog: [entry], policies: []
            )
        }
        let core = PoolPolicyCore(
            poolID: poolID, manifestVersion: version, prevManifestCoreHash: prevHash, signerSetVersion: 1,
            modelAllowlist: allowlist, minBinaryVersion: options.minBinaryVersion, minAttestationTier: options.minAttestationTier,
            requireEncryptedLeg: false, settlementMode: options.settlementMode, revenueSplitBps: 0,
            splitExecutionStatus: "declared_not_executed", retentionPolicyID: options.retentionPolicyID,
            minEligibleMembers: options.minEligibleMembers, privacyMode: "none", relayBlindCapable: false,
            receiptContract: "", metadataVisible: "standard", downgradePolicy: "reject", stickyRoutingAllowed: false,
            notBeforeUnix: notBefore, expiresAtUnix: notBefore + UInt64(options.validityDays) * 86400, encoding: 2,
            runtimeAllowlist: externalRuntimes.sorted(by: PoolBytes.byteLess), extensions: extensions
        )
        let digest = try core.manifestCoreDigest()
        snapshot.policies.append(PoolAcceptedPolicy(
            core: core,
            signatures: [PoolSignature(keyID: identity.policySignerKeyID, sig: try policySigner.signature(for: try core.signingMessage()))],
            acceptedAtUnix: UInt64(Date().timeIntervalSince1970)
        ))
        let snapshotBytes = try snapshot.canonicalBytes()
        let digestHex = PoolBytes.hex(digest)
        let message = try CreatorRootSigning.manifestAcceptanceMessage(
            poolID: poolID, manifestVersion: version, manifestCoreDigestHex: digestHex, manifestSnapshot: snapshotBytes,
            rootIssuerKeyID: identity.rootIssuerKeyID, rootFingerprint: identity.rootIssuerPublicKeyFingerprint
        )
        let event: [String: CreatorJSON] = [
            "operation_id": .string("creator-manifest-\(poolID)-v\(version)-\(digestHex.prefix(12))"),
            "event_type": .string("manifest_accepted"),
            "pool_id": .string(poolID),
            "manifest_version": .number(version),
            "manifest_core_digest": .string(digestHex),
            "root_issuer_key_id": .string(identity.rootIssuerKeyID),
            "root_issuer_public_key_fingerprint": .string(identity.rootIssuerPublicKeyFingerprint),
            "manifest_snapshot": .string(snapshotBytes.base64EncodedString()),
            "manifest_signature": .string(try CreatorRootSigning.signP256(root, message)),
        ]
        let pending = CreatorPendingManifest(
            state: CreatorManifestState(snapshot: snapshot, manifestVersion: version, manifestCoreDigest: digestHex),
            event: event
        )
        try home.write(pending, to: home.poolDir(poolID).appendingPathComponent("manifest-pending.json"), mode: 0o600)
        return pending
    }

    static func submitManifest(home: CreatorHome, client: CreatorClient, poolID: String) async throws -> [String: Any] {
        let pendingURL = home.poolDir(poolID).appendingPathComponent("manifest-pending.json")
        guard FileManager.default.fileExists(atPath: pendingURL.path) else {
            throw CreatorCLIError.invalidInput("no signed manifest pending; run `creator manifest sign` first")
        }
        let pending = try home.read(CreatorPendingManifest.self, from: pendingURL)
        let body = pending.event.mapValues(\.anyValue)
        let operationID = (body["operation_id"] as? String) ?? CreatorOutput.operationID("manifest")
        let result = try client.expect(try await client.request("POST", "events", body: body, operationID: operationID))
        try home.write(pending.state, to: home.poolDir(poolID).appendingPathComponent("manifest-state.json"), mode: 0o600)
        try FileManager.default.removeItem(at: pendingURL)
        return result
    }

    /// Whether a status settles the operation itself. Rate limiting, an
    /// authentication failure, a timeout, and a 5xx are answered before the
    /// coordinator looks at the operation, so the pending write is kept.
    static func isDefinitive(_ status: Int) -> Bool {
        switch status {
        case 401, 408, 425, 429: return false
        default: return status < 500
        }
    }

    /// POSTs under a per-pool sticky operation id: the id is kept until the
    /// gateway gives a definitive answer, so re-running a command after a
    /// lost response replays instead of appending a duplicate event.
    static func stickyRequest(home: CreatorHome, client: CreatorClient, poolID: String, key: String, label: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        let operationID = try home.stickyOperationID(poolID: poolID, key: key, label: label)
        let response = try await client.request("POST", path, body: body, operationID: operationID)
        if isDefinitive(response.status) { try home.clearOperationID(poolID: poolID, key: key) }
        return try client.expect(response)
    }

    static func admit(home: CreatorHome, client: CreatorClient, poolID: String, providerID: String) async throws -> [String: Any] {
        try await stickyRequest(home: home, client: client, poolID: poolID, key: "admit:\(providerID)", label: "admit", path: "events", body: [
            "event_type": "member_admitted", "pool_id": poolID, "provider_id": providerID,
        ])
    }

    static func authorizeBuyer(home: CreatorHome, client: CreatorClient, poolID: String, accountID: String, remove: Bool) async throws -> [String: Any] {
        let label = remove ? "buyer-remove" : "buyer"
        return try await stickyRequest(home: home, client: client, poolID: poolID, key: "\(label):\(accountID)", label: label, path: "events", body: [
            "event_type": remove ? "buyer_authorization_removed" : "buyer_authorized", "pool_id": poolID, "buyer_account_id": accountID,
        ])
    }

    /// Revokes a member Mac with the same `member_revoked` event an operator
    /// uses (SPEC-043-R005); the coordinator drops it from routing at once.
    static func revokeMember(home: CreatorHome, client: CreatorClient, poolID: String, providerID: String) async throws -> [String: Any] {
        try await stickyRequest(home: home, client: client, poolID: poolID, key: "revoke:\(providerID)", label: "revoke", path: "events", body: [
            "event_type": "member_revoked", "pool_id": poolID, "provider_id": providerID,
        ])
    }

    /// Options for the next manifest version: the accepted core's terms with
    /// one pool model id removed from the allowlist and the model entries.
    static func revokeModelOptions(previous: CreatorManifestState, poolModelID: String, notBefore: Date = Date()) throws -> ManifestOptions {
        guard let core = previous.snapshot.policies.last?.core else {
            throw CreatorCLIError.invalidInput("local manifest state is corrupt")
        }
        var entries: [PoolModelEntry] = []
        var members: [PoolAttestedMember] = []
        for ext in core.extensions {
            switch ext.id {
            case PoolExtensions.modelEntriesV1: entries = try PoolExtensions.decodeModelEntries(ext.body)
            case PoolExtensions.attestedMembersV1: members = try PoolExtensions.decodeAttestedMembers(ext.body)
            default: throw CreatorCLIError.invalidInput("accepted manifest carries extension \(ext.id) this CLI cannot re-sign")
            }
        }
        guard core.modelAllowlist.contains(poolModelID) || entries.contains(where: { $0.poolModelID == poolModelID }) else {
            throw CreatorCLIError.invalidInput("\(poolModelID) is not in the accepted manifest (version \(previous.manifestVersion))")
        }
        entries.removeAll { $0.poolModelID == poolModelID }
        let entryIDs = Set(entries.map(\.poolModelID))
        var options = ManifestOptions()
        options.models = core.modelAllowlist.filter { $0 != poolModelID && !entryIDs.contains($0) }
        options.modelEntries = entries
        options.attestedMembers = members
        guard !options.models.isEmpty || !options.modelEntries.isEmpty else {
            throw CreatorCLIError.invalidInput("\(poolModelID) is the pool's only model; retire the pool instead with `creator lifecycle --set retired --pool \(core.poolID)`")
        }
        options.settlementMode = core.settlementMode
        options.retentionPolicyID = core.retentionPolicyID
        options.minBinaryVersion = core.minBinaryVersion
        options.minAttestationTier = core.minAttestationTier
        options.minEligibleMembers = core.minEligibleMembers
        options.notBefore = notBefore
        options.validityDays = max(1, Int((core.expiresAtUnix &- core.notBeforeUnix) / 86400))
        return options
    }

    /// Signs the next manifest version without `poolModelID`; nothing is sent.
    static func signModelRevocation(home: CreatorHome, poolID: String, poolModelID: String) throws -> CreatorPendingManifest {
        guard let previous = try home.manifestState(poolID) else {
            throw CreatorCLIError.invalidInput("no accepted manifest for pool \(poolID); nothing to revoke")
        }
        return try signManifest(home: home, poolID: poolID, options: try revokeModelOptions(previous: previous, poolModelID: poolModelID))
    }

    static let creatorLifecycles: Set<String> = ["paused", "draining", "retired"]

    /// POST /v1/creator/pools/<id>/lifecycle (coordinator
    /// handleCreatorRestrictiveLifecycle). Only restrictive states; a paused
    /// or draining pool returns to active through `creator promote`.
    static func setLifecycle(home: CreatorHome, client: CreatorClient, poolID: String, lifecycle: String, reason: String?) async throws -> [String: Any] {
        guard creatorLifecycles.contains(lifecycle) else {
            throw CreatorCLIError.invalidInput("--set must be paused, draining, or retired (use `creator promote` to reactivate)")
        }
        var body: [String: Any] = ["lifecycle": lifecycle]
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { body["reason"] = reason }
        return try await stickyRequest(home: home, client: client, poolID: poolID, key: "lifecycle:\(lifecycle)", label: "lifecycle", path: "pools/\(poolID)/lifecycle", body: body)
    }

    static func promote(home: CreatorHome, client: CreatorClient, poolID: String) async throws -> [String: Any] {
        try await stickyRequest(home: home, client: client, poolID: poolID, key: "promote", label: "promote", path: "pools/\(poolID)/promote", body: [:])
    }
}

// MARK: - Commands

struct CreatorPoolOption: ParsableArguments {
    @Option(name: .customLong("pool"), help: "The pool id printed by `creator keygen`.")
    var poolID: String

    static func validate(_ poolID: String) throws {
        guard poolID.range(of: #"^[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil else {
            throw ValidationError("--pool must be a 22-character pool id")
        }
    }

    func validate() throws { try Self.validate(poolID) }
}

struct CreatorLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "login", abstract: "Store your Malibu account API key for creator commands.")

    @Option(help: "Account API key. Prefer --api-key-stdin so the key stays out of shell history.")
    var apiKey: String?

    @Flag(help: "Read the API key from standard input.")
    var apiKeyStdin = false

    @Option(help: "Public gateway URL.")
    var gatewayURL = CreatorHome.defaultGatewayURL

    func run() async throws {
        var key = apiKey ?? ""
        if apiKeyStdin { key = readLine(strippingNewline: true) ?? "" }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ValidationError("give --api-key-stdin or --api-key") }
        _ = try CreatorClient.validatedGatewayURL(gatewayURL)
        let login = CreatorLogin(gatewayURL: gatewayURL, apiKey: key)
        let client = CreatorClient(login: login, transport: URLSessionCreatorTransport())
        _ = try client.expect(try await client.request("GET", "agreement"))
        let home = CreatorHome.resolve()
        try home.write(login, to: home.loginURL, mode: 0o600)
        print("logged in to \(gatewayURL)")
    }
}

struct CreatorAgreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agree", abstract: "Read and accept the self-serve Creator Agreement.")

    @Option(help: "Public display name for your pools.") var displayName: String
    @Option(help: "Legal and support contact.") var legalContact: String
    @Option(help: "Billing contact.") var billingContact: String
    @Option(help: "Emergency notification endpoint (mailto: or https:).") var emergencyEndpoint: String
    @Flag(help: "Accept the Agreement shown. Without it the terms are printed and nothing is accepted.") var yes = false

    func run() async throws {
        let context = try CreatorContext.load()
        let terms = try context.client.expect(try await context.client.request("GET", "agreement"))
        guard let agreement = terms["agreement"] as? [String: Any], let version = agreement["creator_agreement_version"] as? String,
              let termsDigest = terms["agreement_terms_digest"] as? String else {
            throw CreatorCLIError.invalidInput("malformed agreement response")
        }
        CreatorOutput.printJSON(agreement)
        guard yes else {
            print("Not accepted. Re-run with --yes to accept Creator Agreement version \(version).")
            throw ExitCode.failure
        }
        let body: [String: Any] = [
            "creator_agreement_version": version, "agreement_terms_digest": termsDigest, "accept": true, "public_display_name": displayName,
            "legal_support_contact": legalContact, "billing_contact": billingContact,
            "emergency_notification_endpoint": emergencyEndpoint,
        ]
        CreatorOutput.printJSON(try context.client.expect(try await context.client.request("POST", "agreement", body: body)))
    }
}

struct CreatorKeygenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keygen", abstract: "Generate a new pool's root, authority, and policy keys on this Mac.")

    func run() throws {
        let identity = try CreatorOperations.keygen(home: CreatorHome.resolve())
        print("pool_id=\(identity.poolID)")
        print("root_issuer_public_key_fingerprint=\(identity.rootIssuerPublicKeyFingerprint)")
    }
}

struct CreatorPoolCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pool", abstract: "Create a pool.", subcommands: [CreatorPoolCreateCommand.self])
}

struct CreatorPoolCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create the pool identity generated by keygen.")
    @OptionGroup var pool: CreatorPoolOption

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.createPool(home: context.home, client: context.client, poolID: pool.poolID))
    }
}

struct CreatorRegisterRootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "register-root", abstract: "Register the pool's root issuer key with a signed proof of possession.")
    @OptionGroup var pool: CreatorPoolOption
    @Option(help: "Intended pool display name (only its hash is sent).") var displayName: String

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.registerRoot(home: context.home, client: context.client, poolID: pool.poolID, displayName: displayName))
    }
}

struct CreatorManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest", abstract: "Sign and submit the pool's model manifest.",
        subcommands: [CreatorManifestSignCommand.self, CreatorManifestSubmitCommand.self]
    )
}

struct CreatorManifestSignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sign", abstract: "Sign the next manifest version locally. Nothing is sent.")
    @OptionGroup var pool: CreatorPoolOption
    @Option(help: "Comma-separated catalog model ids to allow.") var models = ""
    @Option(help: "JSON file with model_entries (pool_model_proposal model_entry objects, completed) and optional attested_members.") var modelsFile: String?
    @Option(help: "Settlement mode: enforce or observe. Pool model entries require enforce.") var settlementMode = "enforce"
    @Option(help: "Registered retention policy id.") var retentionPolicyId = "standard"
    @Option(help: "Minimum provider CLI version.") var minBinaryVersion = "1.8.0"
    @Option(help: "Minimum attestation tier.") var minAttestationTier = "self_signed"
    @Option(help: "Minimum eligible members.") var minEligibleMembers: UInt64 = 1
    @Option(help: "Policy validity in days.") var validityDays = 90

    func run() throws {
        var options = CreatorOperations.ManifestOptions()
        options.models = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let modelsFile {
            (options.modelEntries, options.attestedMembers) = try CreatorOperations.loadModelsFile(modelsFile)
        }
        options.settlementMode = settlementMode
        options.retentionPolicyID = retentionPolicyId
        options.minBinaryVersion = minBinaryVersion
        options.minAttestationTier = minAttestationTier
        options.minEligibleMembers = minEligibleMembers
        options.validityDays = validityDays
        let pending = try CreatorOperations.signManifest(home: CreatorHome.resolve(), poolID: pool.poolID, options: options)
        print("signed manifest_version=\(pending.state.manifestVersion) manifest_core_digest=\(pending.state.manifestCoreDigest)")
    }
}

struct CreatorManifestSubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "submit", abstract: "Submit the pending signed manifest.")
    @OptionGroup var pool: CreatorPoolOption

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.submitManifest(home: context.home, client: context.client, poolID: pool.poolID))
    }
}

struct CreatorAdmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "admit", abstract: "Admit a provider Mac you have claimed (`macprovider-cli claim`).")
    @Argument(help: "Provider id.") var providerID: String
    @OptionGroup var pool: CreatorPoolOption

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.admit(home: context.home, client: context.client, poolID: pool.poolID, providerID: providerID))
    }
}

struct CreatorAuthorizeBuyerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "authorize-buyer", abstract: "Let a buyer account select this pool.")
    @Argument(help: "Buyer account id.") var accountID: String
    @OptionGroup var pool: CreatorPoolOption
    @Flag(help: "Remove the grant instead.") var remove = false

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.authorizeBuyer(home: context.home, client: context.client, poolID: pool.poolID, accountID: accountID, remove: remove))
    }
}

struct CreatorPromoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "promote", abstract: "Activate the private pool through the automated gate.")
    @OptionGroup var pool: CreatorPoolOption

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.promote(home: context.home, client: context.client, poolID: pool.poolID))
        print("Pool active. Restart macprovider-cli on each member Mac so it serves the pool's models.")
    }
}

struct CreatorStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show your approval and pools, or one pool.")
    @Option(name: .customLong("pool"), help: "One pool id.") var poolID: String?

    func validate() throws { if let poolID { try CreatorPoolOption.validate(poolID) } }

    func run() async throws {
        let context = try CreatorContext.load()
        let path = poolID.map { "pools/\($0)" } ?? "pools"
        var out: [String: Any] = ["creator": try await CreatorOperations.me(context.client)]
        out["result"] = try context.client.expect(try await context.client.request("GET", path))
        CreatorOutput.printJSON(out)
    }
}

struct CreatorProvidersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "providers", abstract: "List the provider Macs your GitHub identity has claimed.")

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try context.client.expect(try await context.client.request("GET", "providers")))
    }
}

struct CreatorEarningsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "earnings", abstract: "Show payable provider credits your Macs earned on your pools.")
    @Option(name: .customLong("pool"), help: "One pool id.") var poolID: String?
    @Option(help: "UTC start day YYYY-MM-DD (with --to, at most 31 days).") var from: String?
    @Option(help: "UTC end day YYYY-MM-DD, exclusive.") var to: String?

    func validate() throws { if let poolID { try CreatorPoolOption.validate(poolID) } }

    func run() async throws {
        let context = try CreatorContext.load()
        var query: [URLQueryItem] = []
        if let poolID { query.append(URLQueryItem(name: "pool_id", value: poolID)) }
        if let from { query.append(URLQueryItem(name: "from", value: from)) }
        if let to { query.append(URLQueryItem(name: "to", value: to)) }
        CreatorOutput.printJSON(try context.client.expect(try await context.client.request("GET", "earnings", query: query)))
    }
}

struct CreatorRevokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke a member Mac (--provider) or a pool model entry (--model).",
        discussion: """
        --provider <id> sends member_revoked; the Mac stops routing for the pool at once.
        --model <pool_model_id> signs the next manifest version without that entry and
        leaves it pending: review it, then run `creator manifest submit --pool <id>`.
        """
    )
    @OptionGroup var pool: CreatorPoolOption
    @Option(help: "Provider id of the member Mac to revoke.") var provider: String?
    @Option(help: "pool_model_id of the manifest entry to remove.") var model: String?

    func validate() throws {
        guard (provider == nil) != (model == nil) else { throw ValidationError("give exactly one of --provider or --model") }
    }

    func run() async throws {
        if let model {
            let pending = try CreatorOperations.signModelRevocation(home: CreatorHome.resolve(), poolID: pool.poolID, poolModelID: model)
            print("signed manifest_version=\(pending.state.manifestVersion) without \(model); run `macprovider-cli creator manifest submit --pool \(pool.poolID)` to apply it")
            return
        }
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.revokeMember(home: context.home, client: context.client, poolID: pool.poolID, providerID: provider ?? ""))
    }
}

struct CreatorLifecycleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lifecycle",
        abstract: "Pause, drain, or retire a pool. Reactivate a paused or draining pool with `creator promote`."
    )
    @OptionGroup var pool: CreatorPoolOption
    @Option(name: .customLong("set"), help: "paused, draining, or retired. retired is final.") var lifecycle: String
    @Option(help: "Optional reason recorded with the change.") var reason: String?

    func validate() throws {
        guard CreatorOperations.creatorLifecycles.contains(lifecycle) else {
            throw ValidationError("--set must be paused, draining, or retired")
        }
    }

    func run() async throws {
        let context = try CreatorContext.load()
        CreatorOutput.printJSON(try await CreatorOperations.setLifecycle(home: context.home, client: context.client, poolID: pool.poolID, lifecycle: lifecycle, reason: reason))
    }
}
