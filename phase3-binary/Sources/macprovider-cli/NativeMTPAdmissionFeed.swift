import CryptoKit
import Foundation

/// SPEC-023 §12.5 Stage A delivery of the native-MTP admission set. The
/// sidecar, its signature, the artifact projection manifest, and the signed
/// self-test challenge bank are served by the static-feed origin at
/// `/v1/native-mtp-*` (never a provider-payload member). The provider fetches
/// them, pre-checks the sidecar signature and release binding, and writes the
/// exact bytes into a private per-release directory that the serve-path loader
/// reads; the loader re-verifies every byte and binding before admission.
/// Any failure leaves the provider ordinary.
enum NativeMTPAdmissionFeed {
    static let sidecarFileName = "native-mtp-admission.json"
    static let signatureFileName = "native-mtp-admission.json.sig"
    static let manifestFileName = "native-mtp-artifact-manifest.json"
    static let bankFileName = "native-mtp-selftest-bank.json"
    static let bankSignatureFileName = "native-mtp-selftest-bank.json.sig"
    static let maxManifestBytes = 4 * 1024 * 1024
    static var productionBaseURL: URL { StaticFeedOrigin.base }

    struct Members: Equatable {
        let sidecar: Data
        let signature: Data
        let manifest: Data
        let bank: Data
        let bankSignature: Data
    }

    enum FetchError: Error, Equatable {
        case invalidOrigin
        case invalidHTTPStatus(Int)
        case redirectRejected
        case transportFailed(String)
        case fetchFailed(String)
        case oversized(String)
        case signatureInvalid
        case releaseMismatch
        case signerMismatch
        case storeFailed(String)
    }

    struct FetchResponse: Equatable, Sendable {
        let statusCode: Int
        let body: Data
        let redirected: Bool

        init(statusCode: Int, body: Data, redirected: Bool = false) {
            self.statusCode = statusCode
            self.body = body
            self.redirected = redirected
        }
    }

    typealias Fetcher = @Sendable (URL, Int) async throws -> FetchResponse
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    /// The private directory holding the admission set of one release.
    static func releaseDirectory(root: URL, releaseID: String) -> URL {
        let digest = SHA256.hash(data: Data(releaseID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/native-mtp-admission", isDirectory: true)
    }

    /// Fetches the set for `releaseID`, signed by `signerKeyID`, and returns
    /// the materialized sidecar URL. Members of other releases are removed.
    static func fetchAndMaterialize(
        releaseID: String,
        signerKeyID: String,
        trustedPublicKeys: [String: String],
        fetch: (URL) async throws -> Data,
        baseURL: URL = productionBaseURL,
        root: URL = defaultRoot()
    ) async throws -> URL {
        let members = try await fetchMembers(fetch: fetch, baseURL: baseURL)
        try precheck(members, releaseID: releaseID, signerKeyID: signerKeyID, trustedPublicKeys: trustedPublicKeys)
        return try materialize(members, releaseID: releaseID, root: root)
    }

    /// Production remote admission fetch: exact static-feed origin, no
    /// redirects, bounded member bodies, and bounded 429 retry.
    static func fetchAndMaterialize(
        releaseID: String,
        signerKeyID: String,
        trustedPublicKeys: [String: String],
        fetcher: Fetcher = defaultFetch,
        baseURL: URL = productionBaseURL,
        root: URL = defaultRoot()
    ) async throws -> URL {
        let members = try await fetchMembers(fetcher: fetcher, baseURL: baseURL)
        try precheck(members, releaseID: releaseID, signerKeyID: signerKeyID, trustedPublicKeys: trustedPublicKeys)
        return try materialize(members, releaseID: releaseID, root: root)
    }

    static func fetchMembers(fetch: (URL) async throws -> Data, baseURL: URL) async throws -> Members {
        func get(_ name: String, limit: Int) async throws -> Data {
            let url = AutotuneStaticInputs.staticFeedURL(baseURL: baseURL, name: name)
            let data: Data
            do {
                data = try await fetch(url)
            } catch {
                throw FetchError.fetchFailed(name)
            }
            guard !data.isEmpty, data.count <= limit else { throw FetchError.oversized(name) }
            return data
        }
        return Members(
            sidecar: try await get("native-mtp-admission", limit: NativeMTPAdmissionSidecar.maxSidecarBytes),
            signature: try await get("native-mtp-admission.sig", limit: NativeMTPAdmissionSidecar.maxSignatureBytes),
            manifest: try await get("native-mtp-artifact-manifest", limit: maxManifestBytes),
            bank: try await get("native-mtp-selftest-bank", limit: NativeMTPAdmissionSidecar.maxSelfTestChallengeBankBytes),
            bankSignature: try await get("native-mtp-selftest-bank.sig", limit: NativeMTPAdmissionSidecar.maxSignatureBytes)
        )
    }

    static func fetchMembers(
        fetcher: Fetcher = defaultFetch,
        baseURL: URL,
        sleeper: Sleeper = defaultSleep
    ) async throws -> Members {
        func get(_ name: String, limit: Int) async throws -> Data {
            let url = try memberURL(baseURL: baseURL, name: name)
            return try await fetch(url, maxBytes: limit, fetcher: fetcher, sleeper: sleeper)
        }
        return Members(
            sidecar: try await get("native-mtp-admission", limit: NativeMTPAdmissionSidecar.maxSidecarBytes),
            signature: try await get("native-mtp-admission.sig", limit: NativeMTPAdmissionSidecar.maxSignatureBytes),
            manifest: try await get("native-mtp-artifact-manifest", limit: maxManifestBytes),
            bank: try await get("native-mtp-selftest-bank", limit: NativeMTPAdmissionSidecar.maxSelfTestChallengeBankBytes),
            bankSignature: try await get("native-mtp-selftest-bank.sig", limit: NativeMTPAdmissionSidecar.maxSignatureBytes)
        )
    }

    private static func memberURL(baseURL: URL, name: String) throws -> URL {
        guard baseURL.scheme == "https" || StaticFeedOrigin.isLabLoopback(baseURL),
              baseURL.host?.isEmpty == false,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.fragment == nil else {
            throw FetchError.invalidOrigin
        }
        let url = AutotuneStaticInputs.staticFeedURL(baseURL: baseURL, name: name).absoluteURL
        guard url.scheme == baseURL.scheme,
              url.host == baseURL.host,
              url.port == baseURL.port,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw FetchError.invalidOrigin
        }
        return url
    }

    static func defaultFetch(url: URL, maxBytes: Int) async throws -> FetchResponse {
        guard maxBytes > 0 else { throw FetchError.oversized(url.lastPathComponent) }
        guard url.scheme == "https" || StaticFeedOrigin.isLabLoopback(url),
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw FetchError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let delegate = NoRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        delegate.maxBytes = maxBytes
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    private static func fetch(
        _ url: URL,
        maxBytes: Int,
        fetcher: Fetcher,
        sleeper: Sleeper = defaultSleep
    ) async throws -> Data {
        var response = try await fetcher(url, maxBytes)
        for _ in 0..<AutotuneStaticInputs.rateLimitRetries where response.statusCode == 429 {
            try await sleeper(AutotuneStaticInputs.rateLimitRetryNanoseconds)
            response = try await fetcher(url, maxBytes)
        }
        if response.redirected || (response.statusCode >= 300 && response.statusCode < 400) {
            throw FetchError.redirectRejected
        }
        guard response.statusCode == 200 else {
            throw FetchError.invalidHTTPStatus(response.statusCode)
        }
        guard !response.body.isEmpty, response.body.count <= maxBytes else {
            throw FetchError.oversized(url.lastPathComponent)
        }
        return response.body
    }

    private static func defaultSleep(_ nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    final class NoRedirectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var maxBytes = 0
        var continuation: CheckedContinuation<FetchResponse, Error>?

        private let lock = NSLock()
        private var statusCode: Int?
        private var body = Data()
        private var completed = false

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
            resume(throwing: FetchError.redirectRejected)
            task.cancel()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard !isCompleted else {
                completionHandler(.cancel)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                resume(throwing: FetchError.transportFailed("missing_http_response"))
                return
            }
            if http.statusCode >= 300 && http.statusCode < 400 {
                completionHandler(.cancel)
                resume(throwing: FetchError.redirectRejected)
                return
            }
            guard http.statusCode == 200 || http.statusCode == 429 else {
                completionHandler(.cancel)
                resume(throwing: FetchError.invalidHTTPStatus(http.statusCode))
                return
            }
            if maxBytes > 0, http.expectedContentLength > Int64(maxBytes) {
                completionHandler(.cancel)
                resume(throwing: FetchError.oversized("network"))
                return
            }
            statusCode = http.statusCode
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !isCompleted else { return }
            guard maxBytes > 0, data.count <= maxBytes - body.count else {
                resume(throwing: FetchError.oversized("network"))
                dataTask.cancel()
                return
            }
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if isCompleted { return }
            if let error {
                resume(throwing: FetchError.transportFailed(String(describing: error)))
                return
            }
            guard let statusCode else {
                resume(throwing: FetchError.transportFailed("missing_http_status"))
                return
            }
            resume(returning: FetchResponse(statusCode: statusCode, body: body))
        }

        private var isCompleted: Bool {
            lock.lock()
            let value = completed
            lock.unlock()
            return value
        }

        private func resume(returning response: FetchResponse) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: response)
        }

        private func resume(throwing error: Error) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: error)
        }
    }

    /// Rejects bytes the loader would reject anyway, before anything is
    /// written: the detached signature must verify under the required key, and
    /// the body must name this release and signer.
    static func precheck(
        _ members: Members,
        releaseID: String,
        signerKeyID: String,
        trustedPublicKeys: [String: String]
    ) throws {
        guard let envelope = try? JSONSerialization.jsonObject(with: members.signature) as? [String: Any],
              envelope["alg"] as? String == "ed25519",
              let keyID = envelope["key_id"] as? String,
              let signatureText = envelope["signature"] as? String,
              let signature = Data(base64Encoded: signatureText)
        else {
            throw FetchError.signatureInvalid
        }
        guard keyID == signerKeyID else { throw FetchError.signerMismatch }
        guard let publicKeyText = trustedPublicKeys[keyID],
              let publicKeyBytes = Data(base64Encoded: publicKeyText),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes),
              publicKey.isValidSignature(signature, for: members.sidecar)
        else {
            throw FetchError.signatureInvalid
        }
        guard let body = try? JSONSerialization.jsonObject(with: members.sidecar) as? [String: Any] else {
            throw FetchError.signatureInvalid
        }
        guard body["release_id"] as? String == releaseID else { throw FetchError.releaseMismatch }
        guard body["signer_key_id"] as? String == signerKeyID else { throw FetchError.signerMismatch }
    }

    /// Writes the exact member bytes into a fresh `0700` release directory,
    /// each file `0600`, through a staging directory renamed into place, and
    /// removes every other release's directory.
    static func materialize(_ members: Members, releaseID: String, root: URL) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let target = releaseDirectory(root: root, releaseID: releaseID)
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fileManager.removeItem(at: staging) }
            for (name, data) in [
                (sidecarFileName, members.sidecar),
                (signatureFileName, members.signature),
                (manifestFileName, members.manifest),
                (bankFileName, members.bank),
                (bankSignatureFileName, members.bankSignature),
            ] {
                let url = staging.appendingPathComponent(name, isDirectory: false)
                guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw FetchError.storeFailed(name)
                }
            }
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: staging, to: target)
            for entry in try fileManager.contentsOfDirectory(atPath: root.path) where entry != target.lastPathComponent {
                try? fileManager.removeItem(at: root.appendingPathComponent(entry))
            }
            return target.appendingPathComponent(sidecarFileName, isDirectory: false)
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.storeFailed(String(describing: type(of: error)))
        }
    }
}

/// SPEC-023 §12.5 Stage A store layout. A fetched admission set cannot carry
/// the target or the MTP drafter, so its signed projection manifest names both
/// by their content-addressed durable-store paths,
/// `<repo owner>--<repo name>/<40-hex revision>/<snapshot-manifest sha256>`.
/// The target is the verified catalog artifact this provider serves; the
/// drafter is fetched from its pinned Hugging Face revision when the store has
/// no verified copy, and adopted only after its digest matches. The serve-path
/// loader then re-verifies every projected byte against that manifest.
enum NativeMTPStoreProjection {
    struct Member: Equatable {
        let repoID: String
        let revision: String
        let sha256: String
    }

    /// The drafter fetch is bounded so a slow source cannot hold serve start.
    static let drafterFetchTimeout: TimeInterval = 15 * 60

    /// Parses one store-layout path. Hugging Face repo ids never contain
    /// `--` or `..`, so the store escaping (`/` -> `--`) reverses exactly.
    static func member(path: String, sha256: String) -> Member? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[1].range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              parts[2] == sha256
        else {
            return nil
        }
        let halves = parts[0].components(separatedBy: "--")
        guard halves.count == 2,
              halves.allSatisfy({
                  $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
                      && !$0.contains("..")
                      && !$0.hasSuffix("-")
              })
        else {
            return nil
        }
        return Member(repoID: halves.joined(separator: "/"), revision: parts[1], sha256: sha256)
    }

    /// The target and MTP members of a projection manifest in store layout,
    /// or nil when the manifest is not one.
    static func members(manifest: Data) -> (target: Member, mtp: Member)? {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["schema_version"] as? String == "macprovider.native-mtp-artifact-projection.v1",
              let artifacts = object["artifacts"] as? [String: Any]
        else {
            return nil
        }
        func entry(_ name: String) -> Member? {
            guard let fields = artifacts[name] as? [String: Any],
                  let path = fields["path"] as? String,
                  let sha256 = fields["sha256"] as? String
            else {
                return nil
            }
            return member(path: path, sha256: sha256)
        }
        guard let target = entry("target"), let mtp = entry("mtp") else { return nil }
        return (target, mtp)
    }

    static func storePath(_ member: Member) -> String {
        "\(member.repoID.replacingOccurrences(of: "/", with: "--"))/\(member.revision)/\(member.sha256)"
    }

    /// Returns the durable store root the loader resolves the projection
    /// against once the projected target is the served artifact and a
    /// verified drafter is in the store; nil leaves the provider ordinary.
    static func prepare(
        manifest: Data,
        servedTargetURL: URL,
        resolver: CachedModelArtifactResolver,
        fetchDrafter: (CachedModelArtifactResolver, CandidateCatalog.Row, Date) async throws -> VerifiedModelArtifact = {
            try await $0.verifiedArtifact(for: $1, deadline: $2)
        },
        now: Date = Date()
    ) async -> URL? {
        guard let members = members(manifest: manifest) else { return nil }
        let root = resolver.durableRoot.standardizedFileURL
        func resolved(_ member: Member) -> String {
            root.appendingPathComponent(storePath(member), isDirectory: true).standardizedFileURL.path
        }
        guard resolved(members.target) == servedTargetURL.standardizedFileURL.path else { return nil }
        let drafterRow = CandidateCatalog.Row(
            modelID: members.mtp.repoID,
            modelRevision: members.mtp.revision,
            modelSHA256: members.mtp.sha256,
            minRAMGB: 1,
            minBandwidthTier: .c,
            benchGate: CandidateCatalog.BenchGate(minSustainedTPS: 1, max4KTTFTMS: 1),
            runtimeStatus: "listed",
            notes: nil
        )
        guard let drafter = try? await fetchDrafter(resolver, drafterRow, now.addingTimeInterval(drafterFetchTimeout)),
              drafter.sha256 == members.mtp.sha256,
              URL(fileURLWithPath: drafter.modelArgument).standardizedFileURL.path == resolved(members.mtp)
        else {
            return nil
        }
        return root
    }
}
