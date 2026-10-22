import CryptoKit
import Darwin
import Foundation
import MLXLMCommon
import MacProviderCore
import SystemConfiguration

// Issue #2084 shard group member (SPEC-051): `serve --shard-member` loads only its
// stage's layers, listens for its upstream neighbour, serves stage sessions one
// after another (a lost head or neighbour ends the session, never the process,
// SPEC-051-R014), and signs its per-request sub-receipts with the provider's
// SPEC-015 receipt key. Its coordinator session advertises `shard_member_v1`, so
// it is never routable; its runtime refuses every buyer request.

/// SPEC-051-R029 `interface_type` of the local interface that reaches a peer.
enum ShardLinkInterface {
    static let thunderbolt = "thunderbolt"
    static let ethernet = "ethernet"
    static let wifi = "wifi"
    static let vpn = "vpn"
    static let other = "other"

    /// The interface whose subnet holds the peer's address, classified.
    static func classify(peerAddress: String) -> String {
        guard let host = host(of: peerAddress), let name = interfaceName(reaching: host) else { return other }
        return classify(bsdName: name)
    }

    static func classify(bsdName name: String) -> String {
        for prefix in ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"] where name.hasPrefix(prefix) { return vpn }
        if name.hasPrefix("lo") { return other }
        // macOS names its Thunderbolt Bridge bridge0; bridge100+ are Internet Sharing.
        if name.hasPrefix("bridge") { return Int(name.dropFirst("bridge".count)).map { $0 < 100 } == true ? thunderbolt : other }
        guard name.hasPrefix("en") else { return other }
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return other }
        for interface in interfaces where SCNetworkInterfaceGetBSDName(interface) as String? == name {
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return wifi }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""
            if display.localizedCaseInsensitiveContains("thunderbolt") { return thunderbolt }
            return type == (kSCNetworkInterfaceTypeEthernet as String) ? ethernet : other
        }
        return other
    }

    static func host(of address: String) -> String? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        var host = String(address[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : host
    }

    /// BSD name of the interface with an address in the same subnet as `host`.
    static func interfaceName(reaching host: String) -> String? {
        var peer4 = in_addr()
        var peer6 = in6_addr()
        let isV4 = inet_pton(AF_INET, host, &peer4) == 1
        guard isV4 || inet_pton(AF_INET6, host, &peer6) == 1 else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if isV4, address.pointee.sa_family == sa_family_t(AF_INET) {
                let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if bits != 0, local & bits == peer4.s_addr & bits { return name }
            } else if !isV4, address.pointee.sa_family == sa_family_t(AF_INET6) {
                let local = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bits = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let matches = withUnsafeBytes(of: local) { l in
                    withUnsafeBytes(of: bits) { m in
                        withUnsafeBytes(of: peer6) { p in
                            m.contains { $0 != 0 } && (0..<16).allSatisfy { l[$0] & m[$0] == p[$0] & m[$0] }
                        }
                    }
                }
                if matches { return name }
            }
        }
        return nil
    }
}

/// What a member reports about itself (SPEC-051-R015 member health, R029 hello).
struct ShardMemberStatus: Sendable {
    var listening: Bool
    /// The chain of the session in progress, as far as this member knows it.
    var chain: [ShardBenchHello]
    var stageIndex: Int?
    var upstreamPeer: String?
    var downstreamPeer: String?
    var upstreamInterface: String?
    var downstreamInterface: String?
    var sessionsServed: Int
    var lastError: String?
}

/// The member's accept-and-serve loop on its own thread.
final class ShardMemberStageServer<Stage: ShardBenchStage>: @unchecked Sendable {
    private let stage: Stage
    private let config: ShardMemberConfig
    private let signer: ShardMemberSigner
    private let modelDigest: String?
    private let modelLabel: String
    private let lock = NSLock()
    private var stopped = false
    private var statusValue: ShardMemberStatus
    private var listener: ShardStageListener?
    /// Connect and handshake bound for a session's links.
    static var connectTimeout: TimeInterval { 30 }

    init(stage: Stage, config: ShardMemberConfig, signer: ShardMemberSigner, modelDigest: String?, modelLabel: String) {
        self.stage = stage
        self.config = config
        self.signer = signer
        self.modelDigest = modelDigest
        self.modelLabel = modelLabel
        self.statusValue = ShardMemberStatus(
            listening: false, chain: [], stageIndex: nil, upstreamPeer: nil, downstreamPeer: nil, upstreamInterface: nil,
            downstreamInterface: nil, sessionsServed: 0, lastError: nil)
    }

    var status: ShardMemberStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusValue
    }

    /// The listening port (tests bind port 0).
    var port: UInt16? { listener?.port }

    private var role: ShardBenchRole { stage.layers.upperBound == stage.totalLayers ? .tail : .middle }

    /// Check the stage against the configuration, bind the listener and start serving.
    func start() throws {
        guard stage.layers == config.layerStart..<config.layerEnd else {
            throw ShardGroupConfigError.invalid("the loaded stage holds \(stage.layers), the member config names \(config.layerStart):\(config.layerEnd)")
        }
        if role == .middle, config.connect == nil {
            throw ShardGroupConfigError.invalid("stage \(config.stageIndex) holds middle layers and needs connect (the next stage)")
        }
        let endpoint = try ShardBenchEndpoint.parse(config.listen)
        let bound = try ShardStageListener(host: endpoint.host, port: endpoint.port)
        listener = bound
        update { $0.listening = true }
        shardGroupLog("member \(signer.memberDeviceID) stage \(config.stageIndex) layers \(stage.layers) listening on \(endpoint.host):\(bound.port) epoch=\(config.linkEpoch)")
        let thread = Thread { [self] in serve(bound) }
        thread.name = "shard-member"
        thread.stackSize = 16 << 20
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func update(_ change: (inout ShardMemberStatus) -> Void) {
        lock.lock()
        change(&statusValue)
        lock.unlock()
    }

    private func serve(_ listener: ShardStageListener) {
        let link = config.supervision.link(epoch: config.linkEpoch, frameProtection: config.frameProtection.linkProtection)
        while !isStopped {
            let upstream: ShardStageLink
            do {
                upstream = try listener.accept(timeout: 1, configuration: link)
            } catch ShardLinkError.acceptTimedOut {
                continue
            } catch {
                update { $0.lastError = "accept failed: \(error)" }
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            // SPEC-051-R011: authenticate the upstream link before dialing on, so the
            // stage that dialed this one is never left waiting.
            do {
                try upstream.authenticate(signer: signer, role: .responder, timeout: Self.connectTimeout)
            } catch {
                shardGroupLog("member link key agreement with \(upstream.peerAddress) failed: \(error)")
                update { $0.lastError = "upstream key agreement failed: \(error)" }
                upstream.close()
                continue
            }
            var downstream = upstream
            if let connect = config.connect {
                do {
                    let target = try ShardBenchEndpoint.parse(connect)
                    downstream = try ShardStageLink.connect(
                        host: target.host, port: target.port, timeout: Self.connectTimeout, configuration: link)
                    try downstream.authenticate(signer: signer, role: .initiator, timeout: Self.connectTimeout)
                } catch {
                    shardGroupLog("member could not reach the next stage at \(connect): \(error)")
                    update { $0.lastError = "connect failed: \(error)" }
                    if downstream !== upstream { downstream.close() }
                    upstream.close()
                    continue
                }
            }
            runSession(ShardBenchLinks(upstream: upstream, downstream: downstream), link: link)
        }
        lock.lock()
        self.listener = nil
        lock.unlock()
        update { $0.listening = false }
    }

    private func runSession(_ links: ShardBenchLinks, link: ShardLinkConfiguration) {
        let upstreamInterface = ShardLinkInterface.classify(peerAddress: links.upstream.peerAddress)
        let downstreamInterface = links.isCollapsed ? upstreamInterface : ShardLinkInterface.classify(peerAddress: links.downstream.peerAddress)
        var options = ShardBenchSessionOptions(
            role: role, listen: nil, connect: nil, expectedStages: nil, modelLabel: modelLabel, prompts: [], tokens: 1,
            temperature: 0, seed: 0, link: link, receiveTimeout: Self.connectTimeout, connectTimeout: Self.connectTimeout,
            probeCount: 50, maxSequences: config.maxSequences, warmup: false, prefillChunk: nil,
            prefillChunkDeadline: Double(config.supervision.prefillChunkDeadlineMilliseconds) / 1000, memberID: nil,
            spare: nil, replayBufferBytes: 0, replayDeadline: Double(config.supervision.replayDeadlineMilliseconds) / 1000,
            parity: .skipped)
        options.signer = signer
        options.modelDigest = modelDigest
        options.upstreamInterface = upstreamInterface
        options.returnInterface = links.isCollapsed || role != .tail ? nil : downstreamInterface
        options.onJoined = { [weak self] chain, stageIndex in
            self?.update { status in
                status.chain = chain
                status.stageIndex = stageIndex
                status.upstreamPeer = chain.indices.contains(stageIndex - 1) ? chain[stageIndex - 1].memberDeviceID : nil
                let next = stageIndex + 1 < chain.count ? stageIndex + 1 : 0
                status.downstreamPeer = chain.indices.contains(next) ? chain[next].memberDeviceID : nil
                status.upstreamInterface = upstreamInterface
                status.downstreamInterface = downstreamInterface
                status.lastError = nil
            }
        }
        do {
            let report = try ShardBenchSession(options: options, stage: stage).run(links: links)
            shardGroupLog("member session \(report.stage?.session ?? "?") ended: \(report.stage?.sequencesServed ?? 0) requests")
            update {
                $0.sessionsServed += 1
                $0.chain = []
            }
        } catch {
            shardGroupLog("member session ended: \(error)")
            update {
                $0.sessionsServed += 1
                $0.chain = []
                $0.lastError = "\(error)"
            }
        }
    }
}

/// The handle the member runtime keeps on its stage server, whatever the stage type.
protocol ShardMemberServerHandle: AnyObject, Sendable {
    var status: ShardMemberStatus { get }
    func stop()
}

extension ShardMemberStageServer: ShardMemberServerHandle {}

/// Where a member's `shard_member_hello` stands on the current session.
enum ShardMemberHelloState: Equatable, Sendable {
    case notSent
    case sent(Date)
    case awaitingRegistration
    case accepted
}

actor ShardMemberRuntime: ModelRuntimeServing {
    let config: ShardMemberConfig
    let identity: ShardGroupRuntime.Identity
    let memberDeviceID: String
    let server: any ShardMemberServerHandle
    private var providerStatus: ProviderStatus?
    var helloState = ShardMemberHelloState.notSent

    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { nil }

    init(config: ShardMemberConfig, identity: ShardGroupRuntime.Identity, memberDeviceID: String, server: any ShardMemberServerHandle) {
        self.config = config
        self.identity = identity
        self.memberDeviceID = memberDeviceID
        self.server = server
    }

    var memberStatus: ShardMemberStatus { server.status }

    func stop() {
        server.stop()
    }

    var loadedModelHash: String? { identity.modelHash }
    var loadedModelHashAlgorithm: String? { identity.modelHashAlgorithm }
    var loadedWeightsManifestSHA256: String? { identity.weightsManifestSHA256 }
    var isLoaded: Bool { true }

    func setProviderStatus(_ providerStatus: ProviderStatus) {
        self.providerStatus = providerStatus
    }

    func currentSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready, container: nil, modelID: identity.modelID, modelHash: identity.modelHash,
            modelHashAlgorithm: identity.modelHashAlgorithm, weightsManifestSHA256: identity.weightsManifestSHA256)
    }

    /// SPEC-051-R016: a member serves no buyer request, whatever routed it here.
    static var notRoutable: APIError {
        APIError(
            status: 503, message: "This Mac serves one stage of a shard group and takes no buyer requests",
            type: "server_error", code: "shard_member_not_routable", retryable: true)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle { throw Self.notRoutable }
    func acquireLocalRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle { throw Self.notRoutable }
    func unregisterInFlight(_ id: Int) {}
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { throw Self.notRoutable }

    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        throw Self.notRoutable
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        throw Self.notRoutable
    }
}

/// Builders `serve --shard-group` and `serve --shard-member` use.
enum ShardGroupServe {
    /// Replay buffer of a head with a spare.
    static let replayBufferBytes = 512 * 1_048_576

    /// This Mac's member identity and the SPEC-015 receipt key it signs
    /// sub-receipts with (SPEC-051-R019). Without a configured provider identity
    /// (a local lab group) the member signs with an ephemeral key under
    /// `fallbackMemberID`, and no receipt is ever built from it.
    static func signer(config: AppConfig, fallbackMemberID: String) throws -> ShardMemberSigner {
        guard config.enableReceipts, let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty
        else {
            shardGroupLog("no provider identity or receipts disabled: signing sub-receipts with an ephemeral key as \(fallbackMemberID)")
            return ShardMemberSigner(memberDeviceID: fallbackMemberID, key: Curve25519.Signing.PrivateKey())
        }
        let store = CachedReceiptKeyStore(ProviderCredentialStoreFactory.receiptKeyStore(for: config))
        let key: Curve25519.Signing.PrivateKey
        if config.credentialStore == .protectedFile {
            guard let existing = try store.loadCurrent(providerId: providerID) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerID)
            }
            key = existing
        } else {
            key = try store.loadOrGenerate(providerId: providerID)
        }
        return ShardMemberSigner(memberDeviceID: providerID, key: key)
    }

    /// SPEC-051-R008: the files this Mac loads are the verified catalog artifact
    /// (or, for an uncatalogued local model, the digest every stage must share).
    static func verifiedDigest(directory: URL, expectedSHA256: String?) throws -> String {
        if let expectedSHA256 {
            try ModelRuntime.verifyLoadedArtifact(directory: directory, expectedSHA256: expectedSHA256)
            return expectedSHA256
        }
        return try ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
    }

    static func identity(modelID: String, directory: URL, catalogArtifactSHA256: String?, catalogModelIDAlias: String?) -> ShardGroupRuntime.Identity {
        ShardGroupRuntime.Identity(
            modelID: modelID, modelHash: catalogArtifactSHA256,
            modelHashAlgorithm: catalogArtifactSHA256 == nil ? nil : ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: try? ModelRuntime.modelWeightArtifactManifestHash(in: directory),
            catalogModelIDAlias: catalogModelIDAlias)
    }

    /// End-of-sequence ids: the tokenizer's, plus `eos_token_id` from config.json and
    /// generation_config.json (an id or a list).
    static func eosTokenIDs(directory: URL, tokenizer: any Tokenizer) -> Set<Int> {
        var ids = Set<Int>()
        if let id = tokenizer.eosTokenId { ids.insert(id) }
        for file in ["config.json", "generation_config.json"] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch object["eos_token_id"] {
            case let id as Int: ids.insert(id)
            case let list as [Int]: ids.formUnion(list)
            default: break
            }
        }
        return ids
    }

    static func headRuntime(
        config: ShardGroupHeadConfig,
        modelID: String,
        directory: URL,
        catalogArtifactSHA256: String?,
        verifyArtifactSHA256: String?,
        catalogModelIDAlias: String?,
        maxContextTokens: Int,
        signer: ShardMemberSigner,
        gate: ShardGroupServingGate
    ) async throws -> ShardGroupRuntime {
        let digest = try verifiedDigest(directory: directory, expectedSHA256: verifyArtifactSHA256)
        let stage = ShardBenchStageBox(try await PipelineStageModel.load(directory: directory, layers: 0..<config.headLayerEnd))
        guard stage.stage.totalLayers == config.numLayers else {
            throw ShardGroupConfigError.invalid("the group's stages end at layer \(config.numLayers), the model has \(stage.stage.totalLayers)")
        }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: directory)
        let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json")
        let stopFilter = FileManager.default.fileExists(atPath: tokenizerConfig.path)
            ? try StopTokenConfigExtractor.extract(fromTokenizerConfigAt: tokenizerConfig)
            : StopTokenFilter(tokens: [])
        let thinking = ModelRuntime.chatTemplateSupportsThinkingToggle(in: directory)
        let engineOptions = ShardGroupEngineOptions(
            link: config.supervision.link(epoch: config.groupEpoch, frameProtection: config.frameProtection.linkProtection),
            connectTimeout: ShardMemberStageServer<PipelineStageModel>.connectTimeout,
            decodeHopDeadline: Double(config.supervision.decodeHopDeadlineMilliseconds) / 1000,
            prefillChunkDeadline: Double(config.supervision.prefillChunkDeadlineMilliseconds) / 1000,
            replayDeadline: Double(config.supervision.replayDeadlineMilliseconds) / 1000,
            maxInFlight: config.maxConcurrency, prefillChunk: config.prefillChunkTokens,
            expectedStages: config.stages.count + 1, expectedMembers: config.expectedMembers, modelDigest: digest,
            spare: try config.spare.map { try ShardBenchEndpoint.parse($0.endpoint) }, spareMember: config.spareMember,
            replayBufferBytes: replayBufferBytes, logitTopK: nil, signer: signer)
        let returnListen = try config.returnListen.map { try ShardBenchEndpoint.parse($0) }
        let firstStage = try ShardBenchEndpoint.parse(config.stages[0].endpoint)
        let runtime = ShardGroupRuntime(
            identity: identity(modelID: modelID, directory: directory, catalogArtifactSHA256: catalogArtifactSHA256, catalogModelIDAlias: catalogModelIDAlias),
            prompting: ShardGroupRuntime.Prompting(
                tokenizer: tokenizer, eosTokenIDs: eosTokenIDs(directory: directory, tokenizer: tokenizer), stopFilter: stopFilter,
                templateSupportsThinkingToggle: thinking,
                templateSupportsPreserveThinking: thinking && ModelRuntime.chatTemplateSupportsPreserveThinking(in: directory)),
            maxContextTokens: maxContextTokens, gate: gate,
            registration: ShardGroupRegistration(config: config, signer: signer),
            connect: {
                try await ShardBenchThread.run {
                    let links = try ShardBenchLinks.open(
                        listen: config.stages.count > 1 ? returnListen : nil, connect: firstStage,
                        connectTimeout: engineOptions.connectTimeout, configuration: engineOptions.link, session: "group",
                        signer: signer)
                    let engine = ShardGroupEngine(stage: stage.stage, options: engineOptions)
                    try engine.start(links: links)
                    return engine
                }
            })
        try await runtime.start()
        return runtime
    }

    static func memberRuntime(
        config: ShardMemberConfig,
        modelID: String,
        directory: URL,
        catalogArtifactSHA256: String?,
        verifyArtifactSHA256: String?,
        signer: ShardMemberSigner
    ) async throws -> ShardMemberRuntime {
        let digest = try verifiedDigest(directory: directory, expectedSHA256: verifyArtifactSHA256)
        let stage = try await PipelineStageModel.load(directory: directory, layers: config.layerStart..<config.layerEnd)
        let server = ShardMemberStageServer(stage: stage, config: config, signer: signer, modelDigest: digest, modelLabel: modelID)
        try server.start()
        return ShardMemberRuntime(
            config: config,
            identity: identity(modelID: modelID, directory: directory, catalogArtifactSHA256: catalogArtifactSHA256, catalogModelIDAlias: nil),
            memberDeviceID: signer.memberDeviceID, server: server)
    }
}
