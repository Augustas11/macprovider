import Foundation

/// SPEC-044-R014 (v1 envelope): the catalog-only row a signed catalog model
/// with no local candidate gets. It replaces the builder's conservative
/// sentinel after projection, so `ModelCatalogEconomicsBuilder` (whose body is
/// SPEC-047-R004 signed-journey evidence) stays byte-identical:
///
/// - the source-aware `byom.local.not_offered` guidance, so Malibu's label
///   check accepts the row;
/// - the signed catalog rate as `economics_state: "catalog_reference"` when the
///   rate row passes the R003 checks, never `trusted`: admission stays the
///   local-default `not_offered` sentinel with both authorization booleans
///   false, so nothing here claims earning;
/// - a confirmed `prepare_model` download when the model fits and the signed
///   artifact feed binds a verified primary artifact to the catalog pin.
enum CatalogOnlyRowProjection {
    struct Inputs {
        var candidateCatalog: AutotuneStaticSelection<CandidateCatalog>
        var demand: AutotuneStaticSelection<DemandRank>
        var rateCard: AutotuneStaticSelection<RateCardProjection>?
        var generatedAt: Date
        /// Catalog key -> verified download size (`downloadSizes`).
        var downloadSizes: [String: Int64]
        var hostRAMGB: Int
    }

    /// Catalog key -> size of the current signed artifact feed's verified
    /// primary `mlx_safetensors` artifact that matches the signed catalog
    /// row's pinned revision and hash. Only these keys can be downloaded.
    static func downloadSizes(candidateCatalog: CandidateCatalog, artifactFeed: ArtifactFeed?) -> [String: Int64] {
        guard let feed = artifactFeed else { return [:] }
        var sizes: [String: Int64] = [:]
        for (key, row) in candidateCatalog.rows {
            guard let revision = row.modelRevision, !revision.isEmpty,
                  let sha = row.modelSHA256, !sha.isEmpty,
                  let model = feed.models[key],
                  let primary = model.artifacts[model.primaryArtifactID],
                  primary.runtimeFormat == ArtifactFeed.primaryFormat,
                  primary.verificationStatus == "verified",
                  primary.hash == sha,
                  primary.sourceRef.revision == revision,
                  primary.sizeBytes > 0
            else { continue }
            sizes[key] = Int64(primary.sizeBytes)
        }
        return sizes
    }

    /// The builder's catalog-only sentinel: no candidate, no action, the
    /// local-default `not_offered` admission, for a key in the signed catalog.
    static func isSentinel(_ row: ModelCatalogEconomicsWire.Row, catalog: CandidateCatalog) -> Bool {
        row.actionModelID == nil
            && row.runtimeState == "catalog"
            && !row.weightsPresentLocally
            && row.admission.source == "local_default"
            && row.admission.state == "not_offered"
            && !row.admission.catalogEconomicsPermitted
            && !row.admission.settlementCapable
            && catalog.rows[row.modelKey] != nil
    }

    static func row(
        replacing sentinel: ModelCatalogEconomicsWire.Row,
        inputs: Inputs
    ) -> ModelCatalogEconomicsWire.Row {
        guard let catalogRow = inputs.candidateCatalog.value.rows[sentinel.modelKey] else { return sentinel }
        let modelKey = sentinel.modelKey
        let feedWarnings = inputs.demand.warnings
            .union(inputs.candidateCatalog.warnings)
            .union(inputs.rateCard?.warnings ?? [])
        let reference = referenceRate(modelKey: modelKey, rateCard: inputs.rateCard, feedWarnings: feedWarnings, generatedAt: inputs.generatedAt)
        let demandRow = inputs.demand.value.rows[modelKey]
        let fits = inputs.hostRAMGB >= catalogRow.minRAMGB
        let downloadBytes = inputs.downloadSizes[modelKey]
        let downloadable = fits
            && !sentinel.isCurrent
            && downloadBytes.map { $0 > 0 && $0 <= Int64(ModelPreparationContracts.maxEstimatedBytes) } == true
            && feedWarnings.isDisjoint(with: [.candidateCatalogIntegrityFailure, .candidateCatalogUpdateRequired])

        var warnings = Set(sentinel.warningCodes)
        warnings.insert("admission_state_not_settlement_capable")
        warnings.insert("model_not_local")
        warnings.formUnion(reference.warnings)
        let unavailable = ModelCatalogEconomicsWire.Action.unavailable("no_cli_transaction_available")
        let prepare: ModelCatalogEconomicsWire.Action
        if downloadable, let downloadBytes {
            prepare = .prepareModel(transactionID: UUID().uuidString.lowercased(), estimatedBytes: downloadBytes)
            warnings.remove("action_unavailable")
        } else {
            prepare = unavailable
            warnings.insert("action_unavailable")
        }
        if !fits {
            warnings.insert("hardware_does_not_fit")
        }
        let rate = reference.rate
        return ModelCatalogEconomicsWire.Row(
            modelKey: modelKey,
            servedModelID: sentinel.servedModelID,
            displayModelID: sentinel.displayModelID,
            actionModelID: prepare.available ? modelKey : nil,
            isCurrent: sentinel.isCurrent,
            weightsPresentLocally: false,
            runtimeState: prepare.available ? "needs_preparation" : "catalog",
            estimatedGB: downloadBytes.map { Double($0) / 1_000_000_000 } ?? sentinel.estimatedGB,
            fit: fits ? "fits" : "does_not_fit",
            disabledReason: prepare.available ? nil : (fits ? "no_cli_transaction_available" : "hardware_does_not_fit"),
            warningCodes: Array(warnings).sorted(),
            admission: sentinel.admission,
            providerGuidance: BYOMDiscoveryGuidance.catalogOnlyGuidance(),
            rateCardVersion: rate?.version,
            rateCardGeneratedAt: rate?.generatedAt,
            rateCardKey: rate?.key,
            rateSource: rate == nil ? "none" : "live_signed",
            promptRateUSDPerMillionTokens: rate?.prompt,
            completionRateUSDPerMillionTokens: rate?.completion,
            providerShareBPS: rate?.shareBPS,
            providerPromptPayoutUSDPerMillionTokens: rate.map { $0.prompt * $0.share },
            providerCompletionPayoutUSDPerMillionTokens: rate.map { $0.completion * $0.share },
            economicsState: rate == nil ? "blocked" : "catalog_reference",
            demandRank: demandRow?.rank,
            demandWeight: rate == nil ? nil : demandRow?.demandWeight,
            readyProviderCount: rate == nil ? nil : demandRow?.readyProviderCount,
            supplyDeficitScore: rate == nil ? nil : demandRow?.effectiveSupplyDeficitMultiplier,
            switchAction: unavailable,
            prepare: prepare,
            evaluate: unavailable,
            adoptRecommendation: unavailable,
            cleanupStaging: .unavailable("staging_cleanup_not_required")
        )
    }

    struct ReferenceRate: Equatable {
        var version: String
        var generatedAt: String
        var key: String
        var prompt: Double
        var completion: Double
        var shareBPS: Int

        /// The builder's exact share arithmetic, so payouts match bit for bit.
        var share: Double { Double(shareBPS) / 10_000.0 }
    }

    /// The SPEC-044-R003 trust checks a coordinator-admitted row's economics
    /// pass (live signed, fresh, no blocking feed warning, an exact non-default
    /// rate row), without the admission gate. The parity test
    /// `testCatalogReferenceRateEqualsTheTrustedRateForTheSameKey` keeps this in
    /// step with the builder's `economicsFields`.
    static func referenceRate(
        modelKey: String,
        rateCard: AutotuneStaticSelection<RateCardProjection>?,
        feedWarnings: Set<AutotuneRecommendWarning>,
        generatedAt: Date
    ) -> (rate: ReferenceRate?, warnings: Set<String>) {
        guard let rateCard else { return (nil, ["projection_unavailable"]) }
        var blocking = Set<String>()
        for warning in feedWarnings {
            switch warning {
            case .rateCardIntegrityFailure:
                blocking.insert("feed_signature_invalid")
            case .demandRankIntegrityFailure, .candidateCatalogIntegrityFailure,
                 .rateCardUpdateRequired, .demandRankUpdateRequired, .candidateCatalogUpdateRequired:
                blocking.insert("feed_generation_mismatch")
            case .rateCardDefaultTierUsed:
                blocking.insert("rate_multiplier_unknown")
            default:
                break
            }
        }
        if !blocking.isEmpty { return (nil, blocking) }
        guard let match = rateCard.value.rowForRecommendation(modelKey: modelKey),
              match.key != "default" || modelKey == "default" else {
            return (nil, ["rate_multiplier_unknown"])
        }
        let stale = generatedAt.timeIntervalSince(rateCard.value.generatedAt) > TimeInterval(ModelCatalogEconomicsBuilder.rateCardMaxAgeSeconds)
            || feedWarnings.contains { [.rateCardStale, .demandRankStale, .candidateCatalogStale].contains($0) }
        if stale { return (nil, ["feed_stale"]) }
        let fallback = rateCard.usedFallback
            || feedWarnings.contains { [.rateCardFallbackUsed, .demandRankFallbackUsed, .candidateCatalogFallbackUsed].contains($0) }
        if fallback { return (nil, ["feed_fallback"]) }
        let row = match.row
        return (
            ReferenceRate(
                version: rateCard.value.version,
                generatedAt: ModelSwitchingWireCodec.timestamp(rateCard.value.generatedAt),
                key: match.key,
                prompt: row.usdPerMillionPromptTokens(creditsPerMillion: rateCard.value.usdPerMillionCredits),
                completion: row.usdPerMillionCompletionTokens(creditsPerMillion: rateCard.value.usdPerMillionCredits),
                shareBPS: Int(row.providerShareBPS)
            ),
            []
        )
    }
}

extension ModelCatalogEconomicsWire {
    /// SPEC-044-R014: replaces each catalog-only sentinel row with its R014
    /// row. Candidate rows are untouched.
    func withCatalogOnlyRows(_ inputs: CatalogOnlyRowProjection.Inputs) -> ModelCatalogEconomicsWire {
        let rows = rows.map { row in
            CatalogOnlyRowProjection.isSentinel(row, catalog: inputs.candidateCatalog.value)
                ? CatalogOnlyRowProjection.row(replacing: row, inputs: inputs)
                : row
        }
        return ModelCatalogEconomicsWire(
            generatedAt: generatedAt,
            projectionSequence: projectionSequence,
            source: source,
            rows: rows,
            warnings: warnings
        )
    }
}
