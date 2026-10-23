import Foundation

// Issue #2084 placement: split a model's layers into contiguous stage ranges across
// the members of a shard group (SPEC-051-R006). Pure arithmetic over byte counts, so
// the planner is unit-tested with real model shapes without loading any weights.
//
// The split is proportional: each member's share is its usable memory, or its
// relative compute weight when every member carries one. Shares become layer counts
// by largest-remainder rounding. The LM head counts against the last stage's share
// (it is a vocab-wide matmul every step), so that stage gets fewer layers; the
// embedding is a gather and counts only toward memory. The plan is then checked
// against each member's memory and repaired by moving boundary layers toward
// members with room. A model that cannot fit is refused with the shortfall.

public struct ShardPlacementMember: Equatable, Sendable {
    public var id: String
    /// Memory this member can give to weights and KV (after the OS and runtime reserve).
    public var usableMemoryBytes: Int64
    /// Relative compute speed. Used for the split only when every member has one.
    public var computeWeight: Double?

    public init(id: String, usableMemoryBytes: Int64, computeWeight: Double? = nil) {
        self.id = id
        self.usableMemoryBytes = usableMemoryBytes
        self.computeWeight = computeWeight
    }
}

public struct ShardPlacementModel: Equatable, Sendable {
    /// Weight bytes of each transformer layer, in order. Dense and MoE layers differ.
    public var layerWeightBytes: [Int64]
    /// Token embedding, held by the first stage.
    public var embeddingBytes: Int64
    /// Final norm and LM head (or the tied embedding table), held by the last stage.
    public var headBytes: Int64
    /// Weights every stage loads regardless of its layers.
    public var sharedBytes: Int64
    /// KV cache bytes one token occupies in one layer.
    public var kvBytesPerTokenPerLayer: Int64

    public init(
        layerWeightBytes: [Int64],
        embeddingBytes: Int64,
        headBytes: Int64,
        sharedBytes: Int64 = 0,
        kvBytesPerTokenPerLayer: Int64
    ) {
        self.layerWeightBytes = layerWeightBytes
        self.embeddingBytes = embeddingBytes
        self.headBytes = headBytes
        self.sharedBytes = sharedBytes
        self.kvBytesPerTokenPerLayer = kvBytesPerTokenPerLayer
    }
}

public struct ShardPlacementStage: Codable, Equatable, Sendable {
    public var memberID: String
    public var layerStart: Int
    public var layerEnd: Int
    public var layerWeightBytes: Int64
    public var kvBytes: Int64
    /// Embedding, head and shared weights this stage holds besides its layers.
    public var extraBytes: Int64
    public var totalBytes: Int64
    public var usableMemoryBytes: Int64
    public var headroomBytes: Int64

    public var layerCount: Int { layerEnd - layerStart }
}

public struct ShardPlacementPlan: Codable, Equatable, Sendable {
    public var stages: [ShardPlacementStage]
    public var contextTokens: Int
    public var totalDemandBytes: Int64
    public var totalUsableBytes: Int64
    /// Smallest headroom over usable memory across stages.
    public var minimumHeadroomFraction: Double
    /// Some stage's headroom is below the requested fraction: it fits, with little margin
    /// for activations, a longer context or a runtime that needs more than planned.
    public var isTight: Bool
}

public enum ShardPlacementError: Error, Equatable, Sendable {
    case tooFewMembers(Int)
    case invalidMember(String)
    case invalidModel(String)
    case moreStagesThanLayers(stages: Int, layers: Int)
    /// The whole group lacks `shortfallBytes` of memory.
    case insufficientMemory(demandBytes: Int64, usableBytes: Int64, shortfallBytes: Int64)
    /// The group has the memory in total, but no contiguous split gives this member a
    /// stage that fits; it lacks `shortfallBytes` in the best split found.
    case stageDoesNotFit(memberID: String, shortfallBytes: Int64)
}

public enum ShardPlacementPlanner {
    /// Plan contiguous layer ranges for `members` in stage order (the first holds the
    /// embedding, the last the LM head), each holding KV for `contextTokens` tokens.
    public static func plan(
        members: [ShardPlacementMember],
        model: ShardPlacementModel,
        contextTokens: Int,
        tightHeadroomFraction: Double = 0.05
    ) throws -> ShardPlacementPlan {
        try validate(members: members, model: model, contextTokens: contextTokens)
        let layerCount = model.layerWeightBytes.count
        let kvPerLayer = model.kvBytesPerTokenPerLayer * Int64(contextTokens)
        let costs = model.layerWeightBytes.map { $0 + kvPerLayer }
        let demand = costs.reduce(0, +) + model.embeddingBytes + model.headBytes + model.sharedBytes * Int64(members.count)
        let usable = members.reduce(Int64(0)) { $0 + $1.usableMemoryBytes }
        guard demand <= usable else {
            throw ShardPlacementError.insufficientMemory(demandBytes: demand, usableBytes: usable, shortfallBytes: demand - usable)
        }

        var counts = proportionalCounts(members: members, costs: costs, headBytes: model.headBytes)
        try repair(&counts, members: members, model: model, costs: costs)

        var stages = [ShardPlacementStage]()
        var start = 0
        for (index, member) in members.enumerated() {
            let end = start + counts[index]
            let layerWeights = model.layerWeightBytes[start..<end].reduce(0, +)
            let extra = extraBytes(index: index, of: members.count, model: model)
            let total = layerWeights + kvPerLayer * Int64(end - start) + extra
            stages.append(ShardPlacementStage(
                memberID: member.id, layerStart: start, layerEnd: end, layerWeightBytes: layerWeights,
                kvBytes: kvPerLayer * Int64(end - start), extraBytes: extra, totalBytes: total,
                usableMemoryBytes: member.usableMemoryBytes, headroomBytes: member.usableMemoryBytes - total))
            start = end
        }
        precondition(start == layerCount, "placement must cover every layer")
        let minimumFraction = stages.map { Double($0.headroomBytes) / Double($0.usableMemoryBytes) }.min() ?? 0
        return ShardPlacementPlan(
            stages: stages, contextTokens: contextTokens, totalDemandBytes: demand, totalUsableBytes: usable,
            minimumHeadroomFraction: minimumFraction, isTight: minimumFraction < tightHeadroomFraction)
    }

    // MARK: - Internals

    private static func validate(members: [ShardPlacementMember], model: ShardPlacementModel, contextTokens: Int) throws {
        guard members.count >= 2 else { throw ShardPlacementError.tooFewMembers(members.count) }
        guard Set(members.map(\.id)).count == members.count else {
            throw ShardPlacementError.invalidMember("member ids must be unique")
        }
        for member in members {
            guard member.usableMemoryBytes > 0 else {
                throw ShardPlacementError.invalidMember("\(member.id): usable memory must be > 0")
            }
            if let weight = member.computeWeight, !(weight > 0 && weight.isFinite) {
                throw ShardPlacementError.invalidMember("\(member.id): compute weight must be > 0")
            }
        }
        let weighted = members.filter { $0.computeWeight != nil }.count
        guard weighted == 0 || weighted == members.count else {
            throw ShardPlacementError.invalidMember("give a compute weight to every member or to none")
        }
        guard !model.layerWeightBytes.isEmpty, model.layerWeightBytes.allSatisfy({ $0 >= 0 }),
              model.embeddingBytes >= 0, model.headBytes >= 0, model.sharedBytes >= 0,
              model.kvBytesPerTokenPerLayer >= 0, contextTokens >= 0
        else {
            throw ShardPlacementError.invalidModel("byte counts, layer list and context must be non-negative and non-empty")
        }
        guard members.count <= model.layerWeightBytes.count else {
            throw ShardPlacementError.moreStagesThanLayers(stages: members.count, layers: model.layerWeightBytes.count)
        }
    }

    private static func extraBytes(index: Int, of count: Int, model: ShardPlacementModel) -> Int64 {
        var extra = model.sharedBytes
        if index == 0 { extra += model.embeddingBytes }
        if index == count - 1 { extra += model.headBytes }
        return extra
    }

    /// Layer counts by largest remainder. Each member's share of the layer bytes (the
    /// LM head charged to the last member) becomes a fractional boundary position on
    /// the cumulative layer-byte axis, so cheap dense layers count for less than MoE
    /// layers; the fractional counts between boundaries are then rounded.
    private static func proportionalCounts(members: [ShardPlacementMember], costs: [Int64], headBytes: Int64) -> [Int] {
        let layerCount = costs.count
        let weights = members.map { $0.computeWeight ?? Double($0.usableMemoryBytes) }
        let weightSum = weights.reduce(0, +)
        let layerTotal = Double(costs.reduce(0, +))
        let pool = layerTotal + Double(headBytes)
        var budgets = weights.map { pool * $0 / weightSum }
        budgets[budgets.count - 1] -= Double(headBytes)
        budgets = budgets.map { max(0, $0) }
        let budgetSum = budgets.reduce(0, +)
        let quotas: [Double]
        if budgetSum > 0, layerTotal > 0 {
            let scale = layerTotal / budgetSum
            var boundaries = [0.0]
            var running = 0.0
            for budget in budgets.dropLast() {
                running += budget * scale
                boundaries.append(position(ofCumulativeBytes: running, costs: costs))
            }
            boundaries.append(Double(layerCount))
            quotas = (0..<members.count).map { boundaries[$0 + 1] - boundaries[$0] }
        } else {
            quotas = Array(repeating: Double(layerCount) / Double(members.count), count: members.count)
        }

        var counts = quotas.map { Int($0.rounded(.down)) }
        let last = members.count - 1
        // Largest remainder; on a tie the LM-head stage is served last, then lower index.
        let order = quotas.indices.sorted { lhs, rhs in
            let left = quotas[lhs] - Double(counts[lhs])
            let right = quotas[rhs] - Double(counts[rhs])
            if left != right { return left > right }
            if (lhs == last) != (rhs == last) { return rhs == last }
            return lhs < rhs
        }
        var remaining = layerCount - counts.reduce(0, +)
        var cursor = 0
        while remaining > 0 {
            counts[order[cursor % order.count]] += 1
            remaining -= 1
            cursor += 1
        }
        // Every stage holds at least one layer (SPEC-051-R006); take from the largest.
        for index in counts.indices where counts[index] == 0 {
            if let donor = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[donor] > 1 {
                counts[donor] -= 1
                counts[index] = 1
            }
        }
        return counts
    }

    /// Fractional layer index at which the cumulative layer bytes reach `target`.
    private static func position(ofCumulativeBytes target: Double, costs: [Int64]) -> Double {
        var accumulated = 0.0
        for (index, cost) in costs.enumerated() {
            let value = Double(cost)
            if accumulated + value >= target {
                return Double(index) + (value > 0 ? (target - accumulated) / value : 0)
            }
            accumulated += value
        }
        return Double(costs.count)
    }

    /// Move boundary layers off members that overflow until every stage fits. A move
    /// shifts one layer across each boundary between the overflowing member and a
    /// member with room, and is taken only if every stage it touches still fits, so
    /// total overflow falls with every move and the loop ends.
    private static func repair(
        _ counts: inout [Int],
        members: [ShardPlacementMember],
        model: ShardPlacementModel,
        costs: [Int64]
    ) throws {
        func totals(_ counts: [Int]) -> [Int64] {
            var start = 0
            return counts.indices.map { index in
                let end = start + counts[index]
                defer { start = end }
                return costs[start..<end].reduce(0, +) + extraBytes(index: index, of: counts.count, model: model)
            }
        }
        func overflow(_ totals: [Int64]) -> [Int64] {
            zip(totals, members).map { max(0, $0 - $1.usableMemoryBytes) }
        }
        while true {
            let current = totals(counts)
            let over = overflow(current)
            guard let worst = over.indices.max(by: { over[$0] < over[$1] }), over[worst] > 0 else { return }
            var moved = false
            // Nearest receivers first, in both directions.
            let candidates = counts.indices.filter { $0 != worst }.sorted { abs($0 - worst) < abs($1 - worst) }
            for target in candidates where counts[worst] > 1 {
                var trial = counts
                trial[worst] -= 1
                trial[target] += 1
                let trialTotals = totals(trial)
                let low = min(worst, target)
                let high = max(worst, target)
                let touchedFit = (low...high).allSatisfy { $0 == worst || trialTotals[$0] <= members[$0].usableMemoryBytes }
                if touchedFit, trialTotals[worst] < current[worst] {
                    counts = trial
                    moved = true
                    break
                }
            }
            if !moved {
                throw ShardPlacementError.stageDoesNotFit(memberID: members[worst].id, shortfallBytes: over[worst])
            }
        }
    }
}
