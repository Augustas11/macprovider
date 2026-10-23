import Foundation

/// Byte-level regular grammar; literals are matched as UTF-8, without normalization.
public indirect enum ByteGrammar: Sendable, Hashable {
    case literal(String)
    case bytes(Set<UInt8>)
    case sequence([ByteGrammar])
    case choice([ByteGrammar])
    case zeroOrMore(ByteGrammar)
    case optional(ByteGrammar)

    public func compile(limits: GrammarCompileLimits = .init()) throws -> GrammarAutomaton {
        try GrammarCompiler(limits: limits).compile(self)
    }
}

public struct GrammarCompileLimits: Sendable {
    public var maxNodes: Int
    public var maxStates: Int
    public var maxWork: Int
    public var maxDepth: Int
    public var maxSeconds: Double
    public init(maxNodes: Int = 4096, maxStates: Int = 1024, maxWork: Int = 8_000_000,
                maxDepth: Int = 128, maxSeconds: Double = 2) {
        self.maxNodes = maxNodes; self.maxStates = maxStates; self.maxWork = maxWork
        self.maxDepth = maxDepth; self.maxSeconds = maxSeconds
    }
}

public struct GrammarAutomaton: Sendable {
    public let initialState = 0
    private let transitions: [[Int]]
    private let acceptingStates: Set<Int>
    public var stateCount: Int { transitions.count }
    fileprivate init(transitions: [[Int]], acceptingStates: Set<Int>) {
        self.transitions = transitions; self.acceptingStates = acceptingStates
    }
    public func accepting(state: Int) -> Bool { acceptingStates.contains(state) }
    public func transition(state: Int, bytes: [UInt8]) -> Int? {
        guard transitions.indices.contains(state) else { return nil }
        var current = state
        for byte in bytes {
            current = transitions[current][Int(byte)]
            if current < 0 { return nil }
        }
        return current
    }
}

func unsupportedGrammar(_ message: String) -> APIError {
    APIError(status: 400, message: message, code: "unsupported_output_grammar")
}

private final class GrammarCompiler {
    struct Node { var epsilon: [Int] = []; var edges: [(Set<UInt8>, Int)] = [] }
    let limits: GrammarCompileLimits
    let started = ProcessInfo.processInfo.systemUptime
    var nodes: [Node] = []
    var work = 0
    init(limits: GrammarCompileLimits) { self.limits = limits }
    func spend(_ amount: Int = 1) throws {
        guard amount <= limits.maxWork - work,
              ProcessInfo.processInfo.systemUptime - started <= limits.maxSeconds else {
            throw unsupportedGrammar("Output grammar compilation budget exceeded")
        }
        work += amount
    }
    func node() throws -> Int {
        try spend()
        guard nodes.count < limits.maxNodes else { throw unsupportedGrammar("Output grammar node limit exceeded") }
        nodes.append(Node()); return nodes.count - 1
    }
    func build(_ grammar: ByteGrammar, depth: Int) throws -> (Int, Int) {
        try spend()
        guard depth <= limits.maxDepth else { throw unsupportedGrammar("Output grammar nesting limit exceeded") }
        let start = try node(), end = try node()
        switch grammar {
        case .literal(let string):
            var previous = start
            for byte in string.utf8 {
                let next = try node()
                nodes[previous].edges.append(([byte], next)); previous = next
            }
            nodes[previous].epsilon.append(end)
        case .bytes(let bytes): nodes[start].edges.append((bytes, end))
        case .sequence(let children):
            var previous = start
            for child in children {
                let (a, b) = try build(child, depth: depth + 1)
                nodes[previous].epsilon.append(a); previous = b
            }
            nodes[previous].epsilon.append(end)
        case .choice(let children):
            for child in children {
                let (a, b) = try build(child, depth: depth + 1)
                nodes[start].epsilon.append(a); nodes[b].epsilon.append(end)
            }
        case .zeroOrMore(let child):
            let (a, b) = try build(child, depth: depth + 1)
            nodes[start].epsilon += [a, end]; nodes[b].epsilon += [a, end]
        case .optional(let child):
            let (a, b) = try build(child, depth: depth + 1)
            nodes[start].epsilon += [a, end]; nodes[b].epsilon.append(end)
        }
        return (start, end)
    }
    func closure(_ seed: Set<Int>) throws -> Set<Int> {
        var result = seed, stack = Array(seed)
        while let state = stack.popLast() {
            try spend()
            for next in nodes[state].epsilon {
                try spend()
                if result.insert(next).inserted { stack.append(next) }
            }
        }
        return result
    }
    func compile(_ grammar: ByteGrammar) throws -> GrammarAutomaton {
        guard limits.maxNodes > 0, limits.maxStates > 0, limits.maxWork > 0,
              limits.maxDepth >= 0, limits.maxSeconds.isFinite, limits.maxSeconds > 0 else {
            throw unsupportedGrammar("Invalid output grammar compilation limits")
        }
        let (start, end) = try build(grammar, depth: 0)
        let initial = try closure([start])
        var states = [initial], indices: [Set<Int>: Int] = [initial: 0]
        var transitions: [[Int]] = [], accepting: Set<Int> = []
        var index = 0
        while index < states.count {
            let state = states[index]
            if state.contains(end) { accepting.insert(index) }
            var destinations = [Set<Int>](repeating: [], count: 256)
            for n in state {
                for (bytes, target) in nodes[n].edges {
                    for byte in bytes { try spend(); destinations[Int(byte)].insert(target) }
                }
            }
            var row = [Int](repeating: -1, count: 256)
            for byte in 0..<256 where !destinations[byte].isEmpty {
                let next = try closure(destinations[byte])
                if let known = indices[next] { row[byte] = known }
                else {
                    guard states.count < limits.maxStates else { throw unsupportedGrammar("Output grammar state limit exceeded") }
                    row[byte] = states.count; indices[next] = states.count; states.append(next)
                }
            }
            transitions.append(row); index += 1
        }
        // Remove paths that cannot reach acceptance (for example an empty choice
        // after a literal). Such paths are not valid prefixes for token masking.
        var reverse = [[Int]](repeating: [], count: states.count)
        for (source, row) in transitions.enumerated() {
            for target in Set(row) where target >= 0 {
                try spend(); reverse[target].append(source)
            }
        }
        var productive = accepting, stack = Array(accepting)
        while let target = stack.popLast() {
            for source in reverse[target] {
                try spend()
                if productive.insert(source).inserted { stack.append(source) }
            }
        }
        for source in transitions.indices {
            for byte in 0..<256 where transitions[source][byte] >= 0 {
                try spend()
                if !productive.contains(transitions[source][byte]) { transitions[source][byte] = -1 }
            }
        }
        return GrammarAutomaton(transitions: transitions, acceptingStates: accepting)
    }
}
