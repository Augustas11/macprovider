import Foundation
import MLX
import MacProviderCore

/// SPEC-001-R017: an estimate of whether a named second model fits beside
/// the primary, and the context and slots it would get, from arithmetic
/// alone: no model is loaded, measured, evicted or downloaded, and the
/// primary is never lowered.
///
/// It applies the runtime's rule (`SharedModelMemoryRules.loadDecision` and
/// the command-buffer budget check a load runs first) to inputs read from
/// files: the primary's weights as its safetensors size, the limit the
/// primary's runtime would apply, the primary pinned at its row
/// reservation, and no other member. A running provider decides from what
/// it measures instead: MLX active memory, which includes a draft model or
/// native-MTP drafter, the limit it applied, and every member it has
/// loaded. So the plan is an estimate (`estimate`, always true) and the
/// provider decides again at load time; `models warm check` asks a running
/// provider for that decision (`warm_set check`). The second model's rows
/// come out of what the limit leaves, never more than the autotune memory
/// envelope for the two models together allows, and never below the
/// runtime's minimum row.
struct AutotuneWarmSetPlan: Equatable, Encodable {
    enum Decision: String, Encodable {
        case fits
        case primaryMustShrink = "primary_must_shrink"
        case doesNotFit = "does_not_fit"
    }

    struct Member: Equatable, Encodable {
        let modelID: String
        /// `primary` or `member`.
        let role: String
        let contextTokens: Int
        let slots: Int
        /// Weights plus the KV of every row at `contextTokens`.
        let bytes: Int

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id", role, contextTokens = "context_tokens", slots, bytes
        }
    }

    /// The largest primary reservation that would let the second model
    /// load, at the primary's current context when one slot fits it.
    struct PrimaryFit: Equatable, Encodable {
        let contextTokens: Int
        let slots: Int

        enum CodingKeys: String, CodingKey {
            case contextTokens = "context_tokens", slots
        }
    }

    /// What the plan reads about one model, all from local files and the
    /// signed catalog.
    struct ModelFacts: Equatable {
        var modelID: String
        /// Bytes of the verified artifact's weights (its safetensors), as a
        /// load estimates them. Nil when the model is not on this Mac.
        var artifactBytes: Int?
        /// KV bytes per token from its verified `config.json`; 0 when unknown.
        var kvBytesPerToken: Int = 0
        var declaredMaxContextTokens: Int?
        /// The family that decides its command-buffer budget.
        var family: String?
        var catalogMinRAMGB: Int = 1
        /// The model has a signed catalog row and a verified local artifact.
        var catalogBound = true
    }

    struct Inputs: Equatable {
        var physicalMemoryBytes: UInt64
        /// Metal's recommended working set; nil when unknown.
        var recommendedWorkingSetBytes: Int?
        var primary: ModelFacts
        var primaryContextTokens: Int
        var primarySlots: Int
        /// The primary is bound to a verified catalog artifact, so a second
        /// model must be too.
        var primaryVerified: Bool
        var member: ModelFacts
        /// `MLX_MAX_MB_PER_BUFFER` set by the operator.
        var operatorCommandBufferMB: Int?
    }

    let decision: Decision
    /// A short code: `fits`, `primary_reservation`, `insufficient_memory`,
    /// `command_buffer_budget_conflict`, `not_on_this_mac`,
    /// `not_in_signed_catalog`, `same_model` or `memory_limit_unavailable`.
    let reason: String
    let members: [Member]
    let primaryFit: PrimaryFit?
    let limitBytes: Int?
    let requiredBytes: Int?
    /// Always true: the running provider decides again when it loads the
    /// model. Encoded so a JSON reader cannot take the plan for that decision.
    let estimate = true

    enum CodingKeys: String, CodingKey {
        case decision, reason, members, primaryFit = "primary_fit", limitBytes = "limit_bytes", requiredBytes = "required_bytes"
        case estimate
    }

    /// The label printed before the plan's summary.
    static let estimateLabel = "Estimate, nothing loaded (the provider decides again when it loads the model):"

    /// The smallest row the runtime admits and reserves for a load.
    static let minimumContextTokens = SharedModelMemoryRules.minimumRowTokens

    static func compute(_ inputs: Inputs) -> AutotuneWarmSetPlan {
        let p = inputs.primary
        let s = inputs.member
        let primaryReservedTokens = SharedModelMemoryRules.saturatingMultiply(
            max(1, inputs.primarySlots), max(1, inputs.primaryContextTokens))
        let primaryMember = Member(
            modelID: p.modelID, role: "primary", contextTokens: inputs.primaryContextTokens, slots: inputs.primarySlots,
            bytes: SharedModelMemoryRules.saturatingAdd(
                p.artifactBytes ?? 0, MLXMemoryBudget.kvBytes(tokens: primaryReservedTokens, bytesPerToken: p.kvBytesPerToken)))
        func refused(_ reason: String, limit: Int? = nil) -> AutotuneWarmSetPlan {
            AutotuneWarmSetPlan(
                decision: .doesNotFit, reason: reason, members: [primaryMember], primaryFit: nil,
                limitBytes: limit, requiredBytes: nil)
        }
        if p.modelID.lowercased(with: nil) == s.modelID.lowercased(with: nil) { return refused("same_model") }
        if inputs.primaryVerified, !s.catalogBound { return refused("not_in_signed_catalog") }
        guard let memberWeights = s.artifactBytes else { return refused("not_on_this_mac") }
        // The limit the primary's runtime applied: the working-set cap, never
        // below its own weights plus one workspace.
        guard let limit = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: inputs.recommendedWorkingSetBytes,
            physicalMemoryBytes: inputs.physicalMemoryBytes,
            residentBytes: p.artifactBytes ?? 0) else {
            return refused("memory_limit_unavailable")
        }
        if let family = s.family, commandBufferBudgetConflicts(
            family: family, primaryFamily: p.family, operatorMB: inputs.operatorCommandBufferMB) {
            return refused("command_buffer_budget_conflict", limit: limit)
        }

        let memberMinimumRow = MLXMemoryBudget.kvBytes(tokens: minimumContextTokens, bytesPerToken: s.kvBytesPerToken)
        let atCurrent = loadDecision(inputs, limit: limit, primaryReservedTokens: primaryReservedTokens)
        guard atCurrent.admitted, atCurrent.eviction == nil else {
            let atMinimum = loadDecision(inputs, limit: limit, primaryReservedTokens: 0)
            guard atMinimum.admitted, atMinimum.eviction == nil else {
                return AutotuneWarmSetPlan(
                    decision: .doesNotFit, reason: "insufficient_memory", members: [primaryMember], primaryFit: nil,
                    limitBytes: limit, requiredBytes: atMinimum.requiredBytes)
            }
            return AutotuneWarmSetPlan(
                decision: .primaryMustShrink, reason: "primary_reservation",
                members: [primaryMember, member(s, contextTokens: min(minimumContextTokens, s.declaredMaxContextTokens ?? .max), slots: 1, weights: memberWeights)],
                primaryFit: primaryFit(inputs, limit: limit, memberWeights: memberWeights, memberMinimumRow: memberMinimumRow),
                limitBytes: limit, requiredBytes: atCurrent.requiredBytes)
        }

        // What the limit leaves the second model's rows once the load is in.
        let primaryRows = max(
            MLXMemoryBudget.kvBytes(tokens: primaryReservedTokens, bytesPerToken: p.kvBytesPerToken),
            MLXMemoryBudget.kvBytes(tokens: minimumContextTokens, bytesPerToken: p.kvBytesPerToken))
        let held = [p.artifactBytes ?? 0, memberWeights, primaryRows, 2 * SharedModelMemoryRules.perMemberMarginBytes]
            .reduce(0, SharedModelMemoryRules.saturatingAdd)
        let runtimeFree = max(0, limit - held)
        // The autotune envelope for both models, less the primary's rows.
        let envelope = AutotuneModelContextCap.usableKVBytes(
            hardwareMemoryGB: Int(inputs.physicalMemoryBytes / (1 << 30)),
            catalogMinRAMGB: max(p.catalogMinRAMGB, s.catalogMinRAMGB),
            verifiedArtifactSizesBytes: [p.artifactBytes ?? 0, memberWeights])
        let envelopeFree = Int(clamping: envelope > UInt64(primaryRows) ? envelope - UInt64(primaryRows) : 0)
        let allowance = min(runtimeFree, envelopeFree)

        let (context, slots) = memberShape(
            defaultContext: inputs.primaryContextTokens, defaultSlots: inputs.primarySlots,
            declaredMax: s.declaredMaxContextTokens, kvBytesPerToken: s.kvBytesPerToken, allowance: allowance)
        return AutotuneWarmSetPlan(
            decision: .fits, reason: "fits",
            members: [primaryMember, member(s, contextTokens: context, slots: slots, weights: memberWeights)],
            primaryFit: nil, limitBytes: limit, requiredBytes: atCurrent.requiredBytes)
    }

    /// The second model's context and slots: the primary's values (what it
    /// takes without its own limits), its context capped by the model's
    /// declared maximum and floored at the minimum row; then as many of the
    /// slots as `allowance` holds, else one slot at the largest context it
    /// holds, never below the minimum row.
    static func memberShape(
        defaultContext: Int, defaultSlots: Int, declaredMax: Int?, kvBytesPerToken: Int, allowance: Int
    ) -> (context: Int, slots: Int) {
        let ceiling = declaredMax ?? .max
        let context = min(ceiling, max(minimumContextTokens, defaultContext))
        guard kvBytesPerToken > 0 else { return (context, max(1, defaultSlots)) }
        let perSlot = MLXMemoryBudget.kvBytes(tokens: context, bytesPerToken: kvBytesPerToken)
        let slots = min(max(1, defaultSlots), perSlot > 0 ? allowance / perSlot : 0)
        if slots >= 1 { return (context, slots) }
        let fitting = allowance / kvBytesPerToken
        return (min(context, max(min(minimumContextTokens, ceiling), fitting)), 1)
    }

    /// R017 *Load* with the primary pinned at `primaryReservedTokens` of rows.
    private static func loadDecision(
        _ inputs: Inputs, limit: Int, primaryReservedTokens: Int
    ) -> SharedModelMemoryRules.LoadDecision {
        var primary = SharedModelMemoryMember(label: inputs.primary.modelID)
        primary.loaded = true
        primary.residentBytes = inputs.primary.artifactBytes ?? 0
        primary.kvBytesPerToken = inputs.primary.kvBytesPerToken
        primary.pinned = true
        primary.reservedRowKVBytes = MLXMemoryBudget.kvBytes(
            tokens: primaryReservedTokens, bytesPerToken: inputs.primary.kvBytesPerToken)
        return SharedModelMemoryRules.loadDecision(
            limitBytes: limit, members: [1: primary],
            estimatedResidentBytes: inputs.member.artifactBytes ?? 0,
            newMinimumRowKVBytes: MLXMemoryBudget.kvBytes(
                tokens: minimumContextTokens, bytesPerToken: inputs.member.kvBytesPerToken))
    }

    /// The primary's largest reservation that lets the load in: its
    /// current context with fewer slots, else one slot at a smaller context.
    private static func primaryFit(_ inputs: Inputs, limit: Int, memberWeights: Int, memberMinimumRow: Int) -> PrimaryFit {
        let perToken = inputs.primary.kvBytesPerToken
        let held = [inputs.primary.artifactBytes ?? 0, memberWeights, memberMinimumRow, 2 * SharedModelMemoryRules.perMemberMarginBytes]
            .reduce(0, SharedModelMemoryRules.saturatingAdd)
        let tokens = perToken > 0 ? max(0, limit - held) / perToken : 0
        let slots = min(inputs.primarySlots, tokens / max(1, inputs.primaryContextTokens))
        if slots >= 1 { return PrimaryFit(contextTokens: inputs.primaryContextTokens, slots: slots) }
        return PrimaryFit(contextTokens: max(minimumContextTokens, min(inputs.primaryContextTokens, tokens)), slots: 1)
    }

    private static func member(_ facts: ModelFacts, contextTokens: Int, slots: Int, weights: Int) -> Member {
        Member(
            modelID: facts.modelID, role: "member", contextTokens: contextTokens, slots: slots,
            bytes: SharedModelMemoryRules.saturatingAdd(weights, MLXMemoryBudget.kvBytes(
                tokens: SharedModelMemoryRules.saturatingMultiply(slots, contextTokens), bytesPerToken: facts.kvBytesPerToken)))
    }

    /// The check a load runs before anything else, against the budget the
    /// device recorded when the primary loaded: the operator's
    /// `MLX_MAX_MB_PER_BUFFER`, else the value the primary's family set
    /// (`ModelRuntime.applyMLXCommandBufferBudget`), else MLX's default with
    /// no owning family.
    static func commandBufferBudgetConflicts(family: String, primaryFamily: String?, operatorMB: Int?) -> Bool {
        let effective: (family: String?, megabytes: Int?)
        if let operatorMB {
            effective = ("environment", operatorMB)
        } else if let primaryFamily, let primaryMB = ModelRuntime.commandBufferBudgetMBByFamily[primaryFamily] {
            effective = (primaryFamily, primaryMB)
        } else {
            effective = (nil, nil)
        }
        return SharedModelMemoryRules.commandBufferBudgetConflicts(
            family: family, wantedMB: ModelRuntime.commandBufferBudgetMBByFamily[family],
            effective: effective, operatorMB: operatorMB)
    }
}

extension AutotuneWarmSetPlan {
    /// The plan's inputs as this Mac has them: weights, KV per token,
    /// declared context and family from each model's local files (the
    /// verified catalog artifact when there is one), memory from the OS and
    /// Metal. Nothing is downloaded or loaded.
    static func localInputs(
        primaryModelID: String,
        primaryLoadPath: String?,
        primaryContextTokens: Int,
        primarySlots: Int,
        primaryVerified: Bool,
        memberModelID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Inputs {
        var rows: [String: CandidateCatalog.Row] = [:]
        let authorities = ServeCommand.localRuntimeTargetAuthorities(
            supportedModels: [primaryModelID, memberModelID],
            onVerifiedTarget: { ids, row, _ in for id in ids { rows[id.lowercased(with: nil)] = row } })
        func authority(_ id: String) -> ModelRuntimeTargetAuthority? {
            authorities[id] ?? authorities[id.lowercased(with: nil)]
        }
        func facts(_ id: String, loadPath: String) -> ModelFacts {
            var facts = ModelFacts(modelID: id)
            facts.catalogBound = authority(id) != nil
            facts.catalogMinRAMGB = rows[id.lowercased(with: nil)]?.minRAMGB ?? 1
            guard let directory = try? ModelRuntime.localModelDirectory(for: loadPath) else { return facts }
            facts.artifactBytes = SharedModelMemoryRules.estimatedResidentBytes(modelDirectory: directory)
            facts.kvBytesPerToken = MLXMemoryLimit.kvBytesPerToken(modelDirectory: directory) ?? 0
            if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")) {
                facts.declaredMaxContextTokens = AutotuneModelContextCap.declaredMaxContextTokens(configData: data)
            }
            facts.family = ModelRuntime.localModelFamily(loadPath)
            return facts
        }
        return Inputs(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            recommendedWorkingSetBytes: GPU.maxRecommendedWorkingSetBytes(),
            primary: facts(primaryModelID, loadPath: primaryLoadPath ?? authority(primaryModelID)?.modelArgument ?? primaryModelID),
            primaryContextTokens: primaryContextTokens,
            primarySlots: primarySlots,
            primaryVerified: primaryVerified,
            member: facts(memberModelID, loadPath: authority(memberModelID)?.modelArgument ?? memberModelID),
            operatorCommandBufferMB: environment["MLX_MAX_MB_PER_BUFFER"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// One JSON object, keys sorted.
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// One line for a person.
    func summary(memberModelID: String) -> String {
        let member = members.count > 1 ? members[1] : nil
        let primaryName = members.first?.modelID ?? "the main model"
        switch decision {
        case .fits:
            guard let member else { return "\(memberModelID) fits beside \(primaryName)." }
            return "\(member.modelID) fits beside \(primaryName): \(member.contextTokens) tokens of context, \(member.slots) \(member.slots == 1 ? "slot" : "slots")."
        case .primaryMustShrink:
            let name = memberModelID
            guard let primaryFit else { return "\(name) fits only if \(primaryName) serves less." }
            return "\(name) fits only if \(primaryName) is lowered to \(primaryFit.contextTokens) tokens of context, \(primaryFit.slots) \(primaryFit.slots == 1 ? "slot" : "slots")."
        case .doesNotFit:
            let why: String
            switch reason {
            case "insufficient_memory": why = "there is not enough memory"
            case "command_buffer_budget_conflict": why = "it needs a different GPU buffer setting than the loaded model"
            case "not_on_this_mac": why = "it is not downloaded on this Mac"
            case "not_in_signed_catalog": why = "it is not a verified catalog model"
            case "same_model": why = "it is the main model"
            case "memory_limit_unavailable": why = "the memory limit of this Mac could not be read"
            default: why = reason
            }
            return "\(memberModelID) does not fit beside \(primaryName): \(why)."
        }
    }
}
