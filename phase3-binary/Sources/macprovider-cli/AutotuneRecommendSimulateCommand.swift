import ArgumentParser
import Foundation

struct AutotuneRecommendSimulateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recommend-simulate",
        abstract: "Run the autotune recommendation engine from a JSON envelope.",
        shouldDisplay: false
    )

    func run() async throws {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let simulator = AutotuneRecommendSimulator.production
            let result = try await simulator.recommend(envelopeData: input)
            print(result.simulatorJSON())
        } catch {
            FileHandle.standardError.write(Data("recommend-simulate: \(error)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct AutotuneDumpBakedSnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-baked-snapshot",
        abstract: "Emit the release-baked candidate catalog or demand rank snapshot.",
        shouldDisplay: false
    )

    enum Kind: String, ExpressibleByArgument, CaseIterable {
        case catalog
        case demandRank = "demand-rank"
    }

    @Option(help: "Which baked snapshot to emit.")
    var kind: Kind

    func run() throws {
        switch kind {
        case .catalog:
            print(AutotuneStaticInputs.bakedCandidateCatalogJSON)
        case .demandRank:
            print(AutotuneStaticInputs.bakedDemandRankJSON)
        }
    }
}

struct AutotuneRecommendSimulator: @unchecked Sendable {
    var fetchRateCard: (URL) async throws -> Data
    var bakedCandidateCatalogBytes: () throws -> Data
    var bakedDemandRankBytes: () throws -> Data

    static let liveRateCardURL = URL(string: "https://coordinator.streamvc.live/v1/rate-card")!

    // Dedicated URLSession that refuses HTTP redirects. Reuses the vetted
    // NoRedirectURLSessionDelegate from CoordinatorClient.swift so a 3xx
    // response from the pinned coordinator cannot forward the rate-card
    // fetch to an attacker-controlled host — SEC-H-1 (r3 security audit).
    // Process-wide singleton because URLSession retains its delegate
    // until the session is invalidated.
    private static let noRedirectRateCardSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldUsePipelining = false
        config.httpAdditionalHeaders = nil
        return URLSession(
            configuration: config,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }()

    static let production = AutotuneRecommendSimulator(
        fetchRateCard: { url in
            guard url.scheme == "https",
                  url.host == "coordinator.streamvc.live",
                  url.path == "/v1/rate-card"
            else {
                throw ValidationError("@LIVE rate-card URL must be pinned to coordinator.streamvc.live/v1/rate-card")
            }
            let (data, response) = try await noRedirectRateCardSession.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw ValidationError("@LIVE rate-card fetch returned HTTP \(http.statusCode)")
            }
            return data
        },
        bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
        bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
    )

    func recommend(envelopeData: Data) async throws -> AutotuneRecommendResult {
        let envelope = try JSONDecoder.autotuneSim.decode(AutotuneRecommendSimulateEnvelope.self, from: envelopeData)
        let request = try await envelope.request(
            fetchRateCard: fetchRateCard,
            bakedCandidateCatalogBytes: bakedCandidateCatalogBytes,
            bakedDemandRankBytes: bakedDemandRankBytes
        )
        return AutotuneRecommendEngine().recommend(request)
    }
}

struct AutotuneRecommendSimulateEnvelope: Decodable {
    var hardware: HardwareEnvelope
    var rateCard: RateCardEnvelope
    var candidateCatalog: CandidateCatalogEnvelope
    var candidateCatalogSHA256: String
    var demandRank: DemandRankEnvelope
    var benchmarks: [String: CandidateBenchmark]
    var warnings: [AutotuneRecommendWarning]
    var generatedAt: Date
    var donorMode: Bool

    enum CodingKeys: String, CodingKey {
        case hardware
        case rateCard
        case candidateCatalog
        case candidateCatalogSHA256
        case demandRank
        case benchmarks
        case warnings
        case generatedAt
        case donorMode
        case electricityUSDPerKWH
        case assumedUtilization
        case availabilityHoursPerDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hardware = try c.decode(HardwareEnvelope.self, forKey: .hardware)
        rateCard = try c.decode(RateCardEnvelope.self, forKey: .rateCard)
        candidateCatalog = try c.decode(CandidateCatalogEnvelope.self, forKey: .candidateCatalog)
        candidateCatalogSHA256 = try c.decode(String.self, forKey: .candidateCatalogSHA256)
        demandRank = try c.decode(DemandRankEnvelope.self, forKey: .demandRank)
        benchmarks = try c.decode([String: CandidateBenchmark].self, forKey: .benchmarks)
        warnings = try c.decode([AutotuneRecommendWarning].self, forKey: .warnings)
        let rawGeneratedAt = try c.decode(String.self, forKey: .generatedAt)
        guard let parsedGeneratedAt = ISO8601DateFormatter.autotuneInternet.date(from: rawGeneratedAt) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: c, debugDescription: "generatedAt must be RFC3339")
        }
        generatedAt = parsedGeneratedAt
        donorMode = try c.decode(Bool.self, forKey: .donorMode)
    }

    func request(
        fetchRateCard: (URL) async throws -> Data,
        bakedCandidateCatalogBytes: () throws -> Data,
        bakedDemandRankBytes: () throws -> Data
    ) async throws -> AutotuneRecommendRequest {
        let rateCard = try await rateCard.resolve(fetchRateCard: fetchRateCard)
        let catalog = try candidateCatalog.resolve(bakedBytes: bakedCandidateCatalogBytes)
        let demand = try demandRank.resolve(bakedBytes: bakedDemandRankBytes)
        var patchedBenchmarks = benchmarks
        for key in patchedBenchmarks.keys {
            if patchedBenchmarks[key]?.modelKey.isEmpty == true {
                patchedBenchmarks[key]?.modelKey = key
            }
        }
        return AutotuneRecommendRequest(
            hardware: hardware.value,
            demandRank: demand,
            candidateCatalog: catalog,
            candidateCatalogSHA256: candidateCatalogSHA256,
            rateCard: rateCard,
            benchmarks: patchedBenchmarks,
            warnings: Set(warnings),
            generatedAt: generatedAt,
            donorMode: donorMode
        )
    }
}

struct HardwareEnvelope: Decodable {
    var value: AutotuneRecommendHardware

    enum CodingKeys: String, CodingKey {
        case machine
        case chip
        case memoryGB
        case memory_gb
        case bandwidthTier
        case bandwidth_tier
        case detected
        case osVersion
        case os_version
        case binaryVersion
        case binary_version
        case diversificationID
        case diversification_id
        case hardwareIdentityHash
        case hardware_identity_hash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = AutotuneRecommendHardware(
            machine: try c.decodeIfPresent(String.self, forKey: .machine),
            chip: try c.decode(String.self, forKey: .chip),
            memoryGB: try c.decodeEither(Int.self, .memoryGB, .memory_gb),
            bandwidthTier: try c.decodeEither(BandwidthTier.self, .bandwidthTier, .bandwidth_tier),
            detected: try c.decodeIfPresent(Bool.self, forKey: .detected) ?? true,
            osVersion: try c.decodeEither(String.self, .osVersion, .os_version),
            binaryVersion: try c.decodeEither(String.self, .binaryVersion, .binary_version),
            diversificationID: try c.decodeEither(String.self, .diversificationID, .diversification_id),
            hardwareIdentityHash: try c.decodeEither(String.self, .hardwareIdentityHash, .hardware_identity_hash)
        )
    }
}

enum RateCardEnvelope: Decodable {
    case live
    case value(RateCardProjection)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let sentinel = try? c.decode(String.self), sentinel == "@LIVE" {
            self = .live
            return
        }
        self = .value(try RateCardProjection(from: decoder).validated())
    }

    func resolve(fetchRateCard: (URL) async throws -> Data) async throws -> RateCardProjection {
        switch self {
        case .live:
            let bytes = try await fetchRateCard(AutotuneRecommendSimulator.liveRateCardURL)
            return try AutotuneStaticInputs.decodeRateCard(bytes)
        case .value(let value):
            return value
        }
    }
}

enum CandidateCatalogEnvelope: Decodable {
    case live
    case value(CandidateCatalog)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let sentinel = try? c.decode(String.self), sentinel == "@LIVE" {
            self = .live
            return
        }
        self = .value(try CandidateCatalog(from: decoder).validated())
    }

    func resolve(bakedBytes: () throws -> Data) throws -> CandidateCatalog {
        switch self {
        case .live:
            return try AutotuneStaticInputs.decodeCandidateCatalog(bakedBytes())
        case .value(let value):
            return value
        }
    }
}

enum DemandRankEnvelope: Decodable {
    case live
    case value(DemandRank)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let sentinel = try? c.decode(String.self), sentinel == "@LIVE" {
            self = .live
            return
        }
        self = .value(try DemandRank(from: decoder).validated())
    }

    func resolve(bakedBytes: () throws -> Data) throws -> DemandRank {
        switch self {
        case .live:
            return try AutotuneStaticInputs.decodeDemandRank(bakedBytes())
        case .value(let value):
            return value
        }
    }
}

extension CandidateBenchmark: Decodable {
    enum CodingKeys: String, CodingKey {
        case modelKey
        case model_key
        case sustainedTPS
        case sustained_tps
        case ttftMS
        case ttft_ms
        case swapDetected
        case swap_detected
        case thermalThrottleDetected
        case thermal_throttle_detected
        case artifactSHA256
        case artifact_sha256
        case modelArtifactPath
        case model_artifact_path
        case benchmarkID
        case benchmark_id
        case generatedAt
        case generated_at
        case candidateCatalogSHA256
        case candidate_catalog_sha256
        case binaryVersion
        case binary_version
        case modelID
        case model_id
        case hardwareIdentityHash
        case hardware_identity_hash
        case candidateRowIdentity
        case candidate_row_identity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modelKey: try c.decodeEitherIfPresent(String.self, .modelKey, .model_key) ?? "",
            sustainedTPS: try c.decodeEither(Double.self, .sustainedTPS, .sustained_tps),
            ttftMS: try c.decodeEither(Int.self, .ttftMS, .ttft_ms),
            swapDetected: try c.decodeEither(Bool.self, .swapDetected, .swap_detected),
            thermalThrottleDetected: try c.decodeEither(Bool.self, .thermalThrottleDetected, .thermal_throttle_detected),
            artifactSHA256: try c.decodeEither(String.self, .artifactSHA256, .artifact_sha256),
            modelArtifactPath: try c.decodeEither(String.self, .modelArtifactPath, .model_artifact_path),
            benchmarkID: try c.decodeEitherIfPresent(String.self, .benchmarkID, .benchmark_id),
            generatedAt: try c.decodeDateEither(.generatedAt, .generated_at),
            candidateCatalogSHA256: try c.decodeEither(String.self, .candidateCatalogSHA256, .candidate_catalog_sha256),
            binaryVersion: try c.decodeEither(String.self, .binaryVersion, .binary_version),
            modelID: try c.decodeEither(String.self, .modelID, .model_id),
            hardwareIdentityHash: try c.decodeEither(String.self, .hardwareIdentityHash, .hardware_identity_hash),
            candidateRowIdentity: try c.decodeEitherIfPresent(String.self, .candidateRowIdentity, .candidate_row_identity) ?? ""
        )
    }
}

extension AutotuneRecommendWarning: Codable {}

private extension JSONDecoder {
    static let autotuneSim: JSONDecoder = JSONDecoder()
}

private extension KeyedDecodingContainer {
    func decodeEither<T: Decodable>(_ type: T.Type, _ first: Key, _ second: Key) throws -> T {
        if let value = try decodeIfPresent(type, forKey: first) {
            return value
        }
        return try decode(type, forKey: second)
    }

    func decodeEitherIfPresent<T: Decodable>(_ type: T.Type, _ first: Key, _ second: Key) throws -> T? {
        if let value = try decodeIfPresent(type, forKey: first) {
            return value
        }
        return try decodeIfPresent(type, forKey: second)
    }

    func decodeDateEither(_ first: Key, _ second: Key) throws -> Date {
        let raw = try decodeEither(String.self, first, second)
        guard let date = ISO8601DateFormatter.autotuneInternet.date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: first, in: self, debugDescription: "date must be RFC3339")
        }
        return date
    }
}
