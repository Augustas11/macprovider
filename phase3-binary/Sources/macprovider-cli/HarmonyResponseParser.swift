import Foundation

enum HarmonyResponseParser {
    static let channelTokenID = 200_005
    static let startTokenID = 200_006
    static let endTokenID = 200_007
    static let messageTokenID = 200_008
    static let constrainTokenID = 200_003
    static let returnTokenID = 200_002
    static let callTokenID = 200_012

    static func isHarmonyModelID(_ modelID: String) -> Bool {
        modelID.range(of: "gpt-oss", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    struct ParseResult: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case notApplicable
            case parsed
            case incomplete
            case malformed
        }

        let status: Status
        let content: String?
        let toolCalls: [ToolCall]
        let finalContentTokenCount: Int
        let finalContentTokenIDs: [Int]
        let failure: Failure?

        var isHarmony: Bool {
            status != .notApplicable
        }
    }

    enum Failure: Equatable, Sendable {
        case malformed
        case perCallByteCapExceeded
        case responseByteCapExceeded
    }

    enum Mode: Equatable, Sendable {
        case streaming
        case complete(finishReason: String? = nil)
    }

    static func parse(
        tokenIDs: [Int],
        decode: ([Int]) -> String,
        allowedFunctionNames: Set<String>? = nil,
        mode: Mode = .complete(),
        stopCandidates: [String] = []
    ) -> ParseResult {
        guard tokenIDs.contains(where: { isSpecialTokenID($0) }) else {
            return ParseResult(
                status: .notApplicable,
                content: nilIfBlank(decode(tokenIDs)),
                toolCalls: [],
                finalContentTokenCount: 0,
                finalContentTokenIDs: [],
                failure: nil
            )
        }

        do {
            return try parseHarmony(
                tokenIDs,
                decode: decode,
                allowedFunctionNames: allowedFunctionNames,
                mode: mode,
                stopCandidates: stopCandidates
            )
        } catch ParseError.incomplete {
            switch mode {
            case .streaming:
                return ParseResult(status: .incomplete, content: nil, toolCalls: [], finalContentTokenCount: 0, finalContentTokenIDs: [], failure: nil)
            case .complete:
                return malformedResult(.malformed)
            }
        } catch ParseError.perCallByteCapExceeded {
            return malformedResult(.perCallByteCapExceeded)
        } catch ParseError.responseByteCapExceeded {
            return malformedResult(.responseByteCapExceeded)
        } catch {
            return malformedResult(.malformed)
        }
    }

    struct StreamingParser {
        private let decode: ([Int]) -> String
        private let decodeFinalToken: ((Int) -> String?)?
        private let allowedFunctionNames: Set<String>?
        private let stopCandidates: [String]
        private var seenTokenIDs: [Int] = []
        private var phase = Phase.preamble
        private var headerTokenIDs: [Int] = []
        private var constrainTokenIDs: [Int] = []
        private var bodyTokenIDs: [Int] = []
        private var currentFrame: Header?
        private var roleHeaderTokenIDs: [Int] = []
        private var pendingRoleRecipient: String?
        private var finalContent = ""
        private var finalContentTokenIDs: [Int] = []
        private var toolCalls: [ToolCall] = []
        private var toolArgumentBytes = 0
        private var observedTerminal = false
        private var failure: Failure?
        private var suppressedStopMatcher: StopCandidateMatcher

        init(
            decode: @escaping ([Int]) -> String,
            decodeFinalToken: ((Int) -> String?)? = nil,
            allowedFunctionNames: Set<String>? = nil,
            stopCandidates: [String] = []
        ) {
            self.decode = decode
            self.decodeFinalToken = decodeFinalToken
            self.allowedFunctionNames = allowedFunctionNames
            self.stopCandidates = stopCandidates
            self.suppressedStopMatcher = StopCandidateMatcher(stopCandidates: stopCandidates)
        }

        mutating func parse(cumulativeTokenIDs: [Int]) -> ParseResult {
            guard failure == nil else {
                return HarmonyResponseParser.malformedResult(failure ?? .malformed)
            }
            guard cumulativeTokenIDs.count >= seenTokenIDs.count,
                  Array(cumulativeTokenIDs.prefix(seenTokenIDs.count)) == seenTokenIDs
            else {
                failure = .malformed
                return HarmonyResponseParser.malformedResult(.malformed)
            }

            let newTokenIDs = Array(cumulativeTokenIDs.dropFirst(seenTokenIDs.count))
            guard cumulativeTokenIDs.contains(where: { isSpecialTokenID($0) }) else {
                seenTokenIDs = cumulativeTokenIDs
                return ParseResult(
                    status: .notApplicable,
                    content: nilIfBlank(decode(cumulativeTokenIDs)),
                    toolCalls: [],
                    finalContentTokenCount: 0,
                    finalContentTokenIDs: [],
                    failure: nil
                )
            }
            return parse(newTokenIDs: newTokenIDs)
        }

        mutating func parse(newTokenIDs: [Int]) -> ParseResult {
            guard failure == nil else {
                return HarmonyResponseParser.malformedResult(failure ?? .malformed)
            }
            do {
                for tokenID in newTokenIDs {
                    seenTokenIDs.append(tokenID)
                    try consume(tokenID)
                }
                return snapshot()
            } catch ParseError.perCallByteCapExceeded {
                failure = .perCallByteCapExceeded
                return HarmonyResponseParser.malformedResult(.perCallByteCapExceeded)
            } catch ParseError.responseByteCapExceeded {
                failure = .responseByteCapExceeded
                return HarmonyResponseParser.malformedResult(.responseByteCapExceeded)
            } catch {
                failure = .malformed
                return HarmonyResponseParser.malformedResult(.malformed)
            }
        }

        private mutating func consume(_ tokenID: Int) throws {
            guard !observedTerminal else {
                throw ParseError.malformed
            }
            switch phase {
            case .preamble:
                if tokenID == startTokenID {
                    roleHeaderTokenIDs.removeAll(keepingCapacity: true)
                    pendingRoleRecipient = nil
                    phase = .roleHeader
                    return
                }
                if tokenID == channelTokenID {
                    headerTokenIDs.removeAll(keepingCapacity: true)
                    phase = .header
                    return
                }
                guard !isMessageBoundary(tokenID), !isStructuralTokenID(tokenID) else {
                    throw ParseError.malformed
                }
            case .roleHeader:
                if tokenID == channelTokenID {
                    pendingRoleRecipient = try parseRoleHeaderTokenIDs(roleHeaderTokenIDs, decode: decode, boundaryReached: true, mode: .streaming)
                    roleHeaderTokenIDs.removeAll(keepingCapacity: true)
                    headerTokenIDs.removeAll(keepingCapacity: true)
                    phase = .header
                    return
                }
                guard !isSpecialTokenID(tokenID) else {
                    throw ParseError.malformed
                }
                roleHeaderTokenIDs.append(tokenID)
                try suppressedStopMatcher.append(decode([tokenID]))
            case .header:
                if tokenID == messageTokenID || tokenID == constrainTokenID {
                    let channelHeader = try parseChannelHeaderTokenIDs(headerTokenIDs, decode: decode, boundaryReached: true, mode: .streaming)
                    currentFrame = try mergeHeader(channelHeader, roleRecipient: pendingRoleRecipient)
                    pendingRoleRecipient = nil
                    headerTokenIDs.removeAll(keepingCapacity: true)
                    bodyTokenIDs.removeAll(keepingCapacity: true)
                    constrainTokenIDs.removeAll(keepingCapacity: true)
                    phase = tokenID == constrainTokenID ? .constrain : .body
                    return
                }
                guard !isMessageBoundary(tokenID), !isStructuralTokenID(tokenID) else {
                    throw ParseError.malformed
                }
                headerTokenIDs.append(tokenID)
                try suppressedStopMatcher.append(decode([tokenID]))
            case .constrain:
                if tokenID == messageTokenID {
                    constrainTokenIDs.removeAll(keepingCapacity: true)
                    bodyTokenIDs.removeAll(keepingCapacity: true)
                    phase = .body
                    return
                }
                guard !isMessageBoundary(tokenID), !isStructuralTokenID(tokenID) else {
                    throw ParseError.malformed
                }
                constrainTokenIDs.append(tokenID)
                try suppressedStopMatcher.append(decode([tokenID]))
            case .body:
                if tokenID == endTokenID || tokenID == returnTokenID || tokenID == callTokenID {
                    try finishBody(terminator: tokenID)
                    currentFrame = nil
                    bodyTokenIDs.removeAll(keepingCapacity: true)
                    phase = .preamble
                    return
                }
                guard !isStructuralTokenID(tokenID) else {
                    throw ParseError.malformed
                }
                bodyTokenIDs.append(tokenID)
                if currentFrame?.channel != "final" {
                    try suppressedStopMatcher.append(decode([tokenID]))
                }
                if currentFrame?.channel == "final" {
                    if let decodeFinalToken {
                        if let text = decodeFinalToken(tokenID) {
                            finalContent += text
                        }
                    } else {
                        finalContent += decode([tokenID])
                    }
                    finalContentTokenIDs.append(tokenID)
                }
            }
        }

        private mutating func finishBody(terminator: Int) throws {
            guard let frame = currentFrame else {
                throw ParseError.malformed
            }
            if isFunctionRecipient(frame.recipient), frame.channel != "commentary" {
                throw ParseError.malformed
            }
            if frame.channel != "final" {
                try rejectStopCandidate(in: decode(bodyTokenIDs), stopCandidates: stopCandidates)
            }
            switch frame.channel {
            case "final":
                guard terminator == endTokenID || terminator == returnTokenID else {
                    throw ParseError.malformed
                }
                if terminator == returnTokenID {
                    observedTerminal = true
                }
            case "commentary":
                let hasFunctionRecipient = frame.recipient?.hasPrefix("functions.") ?? false
                if hasFunctionRecipient {
                    guard terminator == callTokenID, let recipient = frame.recipient else {
                        throw ParseError.malformed
                    }
                    let functionName = String(recipient.dropFirst("functions.".count))
                    guard let allowedFunctionNames, allowedFunctionNames.contains(functionName) else {
                        throw ParseError.malformed
                    }
                    let body = decode(bodyTokenIDs)
                    let argumentBytes = try toolArgumentByteCount(body)
                    guard toolArgumentBytes + argumentBytes <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                        throw ParseError.responseByteCapExceeded
                    }
                    let parsedCall = try toolCall(
                        functionName: functionName,
                        arguments: body,
                        prevalidatedArgumentBytes: argumentBytes
                    )
                    let call = parsedCall.call
                    toolArgumentBytes += argumentBytes
                    toolCalls.append(call)
                } else if terminator == callTokenID {
                    throw ParseError.malformed
                } else if terminator == returnTokenID {
                    observedTerminal = true
                }
            case "analysis":
                guard terminator != callTokenID else {
                    throw ParseError.malformed
                }
                if terminator == returnTokenID {
                    observedTerminal = true
                }
            default:
                throw ParseError.malformed
            }
        }

        private func snapshot() -> ParseResult {
            ParseResult(
                status: observedTerminal ? .parsed : .incomplete,
                content: nilIfEmpty(finalContent),
                toolCalls: toolCalls,
                finalContentTokenCount: finalContentTokenIDs.count,
                finalContentTokenIDs: finalContentTokenIDs,
                failure: nil
            )
        }

        private enum Phase {
            case preamble
            case roleHeader
            case header
            case constrain
            case body
        }
    }

    private static func parseHarmony(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        allowedFunctionNames: Set<String>?,
        mode: Mode,
        stopCandidates: [String]
    ) throws -> ParseResult {
        var index = 0
        var finalContent = ""
        var finalContentTokenCount = 0
        var finalContentTokenIDs: [Int] = []
        var toolCalls: [ToolCall] = []
        var toolArgumentBytes = 0
        var observedTerminal = false
        var observedReturnTerminal = false
        var pendingRoleRecipient: String?
        var suppressedStopMatcher = StopCandidateMatcher(stopCandidates: stopCandidates)

        while index < tokenIDs.count {
            guard !observedReturnTerminal else {
                throw ParseError.malformed
            }
            if tokenIDs[index] == startTokenID {
                index += 1
                pendingRoleRecipient = try readRoleHeader(
                    tokenIDs,
                    decode: decode,
                    index: &index,
                    mode: mode,
                    stopMatcher: &suppressedStopMatcher
                )
            } else if tokenIDs[index] != channelTokenID {
                guard tokenIDs[..<index].allSatisfy({ !isSpecialTokenID($0) }) else {
                    throw ParseError.malformed
                }
                if index == 0 {
                    throw ParseError.malformed
                }
                index += 1
                continue
            }

            while index < tokenIDs.count && tokenIDs[index] != channelTokenID {
                guard !isSpecialTokenID(tokenIDs[index]) else {
                    throw ParseError.malformed
                }
                index += 1
            }
            guard index < tokenIDs.count, tokenIDs[index] == channelTokenID else {
                return incompleteResult(mode: mode)
            }
            index += 1

            let channelHeader = try readChannelHeader(
                tokenIDs,
                decode: decode,
                index: &index,
                mode: mode,
                stopMatcher: &suppressedStopMatcher
            )
            let header = try mergeHeader(channelHeader, roleRecipient: pendingRoleRecipient)
            pendingRoleRecipient = nil
            let channel = header.channel
            let recipient = header.recipient
            if isFunctionRecipient(recipient), channel != "commentary" {
                throw ParseError.malformed
            }

            if index < tokenIDs.count, tokenIDs[index] == constrainTokenID {
                index += 1
                let constrain = try readPlainTextUntilControl(tokenIDs, decode: decode, index: &index, mode: mode)
                try suppressedStopMatcher.append(constrain.raw)
            }

            guard index < tokenIDs.count, tokenIDs[index] == messageTokenID else {
                return incompleteResult(mode: mode)
            }
            index += 1

            let bodyStart = index
            let terminator = try consumeBody(tokenIDs, index: &index, mode: mode)
            let consumedTerminator = terminator != nil
            let bodyTokenIDs = Array(tokenIDs[bodyStart..<index])
            let body = decode(bodyTokenIDs)
            if channel != "final" {
                try suppressedStopMatcher.append(body)
            }

            if terminator == nil {
                if channel == "final", allowsLengthTruncatedFinal(mode: mode) {
                    finalContent += body
                    finalContentTokenCount += bodyTokenIDs.count
                    finalContentTokenIDs.append(contentsOf: bodyTokenIDs)
                    if let stopped = stopTruncatedResult(
                        content: finalContent,
                        tokenIDs: finalContentTokenIDs,
                        decode: decode,
                        stopCandidates: stopCandidates
                    ) {
                        return stopped
                    }
                    return ParseResult(
                        status: .incomplete,
                        content: nilIfEmpty(finalContent),
                        toolCalls: toolCalls,
                        finalContentTokenCount: finalContentTokenCount,
                        finalContentTokenIDs: finalContentTokenIDs,
                        failure: nil
                    )
                } else {
                    return incompleteResult(mode: mode)
                }
            }

            guard let terminator else {
                throw ParseError.incomplete
            }

            switch channel {
            case "final":
                guard terminator == endTokenID || terminator == returnTokenID else {
                    throw ParseError.malformed
                }
                finalContent += body
                finalContentTokenCount += bodyTokenIDs.count
                finalContentTokenIDs.append(contentsOf: bodyTokenIDs)
                if let stopped = stopTruncatedResult(
                    content: finalContent,
                    tokenIDs: finalContentTokenIDs,
                    decode: decode,
                    stopCandidates: stopCandidates
                ) {
                    return stopped
                }
                if terminator == returnTokenID {
                    observedTerminal = true
                    observedReturnTerminal = true
                }
            case "commentary":
                let hasFunctionRecipient = recipient?.hasPrefix("functions.") ?? false
                if hasFunctionRecipient {
                    guard terminator == callTokenID, let recipient else {
                        throw ParseError.malformed
                    }
                    let functionName = String(recipient.dropFirst("functions.".count))
                    guard let allowedFunctionNames, allowedFunctionNames.contains(functionName) else {
                        throw ParseError.malformed
                    }
                    let argumentBytes = try toolArgumentByteCount(body)
                    guard toolArgumentBytes + argumentBytes <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                        throw ParseError.responseByteCapExceeded
                    }
                    let parsedCall = try toolCall(
                        functionName: functionName,
                        arguments: body,
                        prevalidatedArgumentBytes: argumentBytes
                    )
                    let call = parsedCall.call
                    toolArgumentBytes += argumentBytes
                    toolCalls.append(call)
                    observedTerminal = true
                } else if terminator == callTokenID {
                    throw ParseError.malformed
                } else if terminator == returnTokenID {
                    observedTerminal = true
                    observedReturnTerminal = true
                }
            case "analysis":
                guard terminator != callTokenID else {
                    throw ParseError.malformed
                }
                if terminator == returnTokenID {
                    observedTerminal = true
                    observedReturnTerminal = true
                }
                break
            default:
                break
            }

            if consumedTerminator {
                guard index < tokenIDs.count, tokenIDs[index] == terminator else {
                    throw ParseError.incomplete
                }
                index += 1
            }
        }

        switch mode {
        case .streaming:
            guard observedTerminal else {
                return ParseResult(
                    status: .incomplete,
                    content: nilIfEmpty(finalContent),
                    toolCalls: toolCalls,
                    finalContentTokenCount: finalContentTokenCount,
                    finalContentTokenIDs: finalContentTokenIDs,
                    failure: nil
                )
            }
        case .complete(let finishReason):
            guard observedTerminal else {
                if finishReason == "length" || finishReason == "request_stop" {
                    return malformedResult(.malformed)
                }
                throw ParseError.malformed
            }
        }

        return ParseResult(
            status: .parsed,
            content: nilIfEmpty(finalContent),
            toolCalls: toolCalls,
            finalContentTokenCount: finalContentTokenCount,
            finalContentTokenIDs: finalContentTokenIDs,
            failure: nil
        )
    }

    private static func readRoleHeader(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        index: inout Int,
        mode: Mode,
        stopMatcher: inout StopCandidateMatcher
    ) throws -> String? {
        let header = try readPlainTextUntilChannel(tokenIDs, decode: decode, index: &index, mode: mode)
        try stopMatcher.append(header.raw)
        return try parseRoleHeader(header.raw, boundaryReached: header.boundaryReached, mode: mode)
    }

    private static func readChannelHeader(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        index: inout Int,
        mode: Mode,
        stopMatcher: inout StopCandidateMatcher
    ) throws -> Header {
        let header = try readPlainTextUntilControl(tokenIDs, decode: decode, index: &index, mode: mode)
        try stopMatcher.append(header.raw)
        return try parseChannelHeader(header.raw, boundaryReached: header.boundaryReached, mode: mode)
    }

    private static func readPlainTextUntilChannel(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        index: inout Int,
        mode: Mode
    ) throws -> (raw: String, boundaryReached: Bool) {
        let start = index
        while index < tokenIDs.count, tokenIDs[index] != channelTokenID {
            guard !isSpecialTokenID(tokenIDs[index]) else {
                throw ParseError.malformed
            }
            index += 1
        }
        guard index < tokenIDs.count || mode == .streaming else {
            throw ParseError.incomplete
        }
        return (decode(Array(tokenIDs[start..<index])).trimmingCharacters(in: .whitespacesAndNewlines), index < tokenIDs.count)
    }

    private static func readPlainTextUntilControl(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        index: inout Int,
        mode: Mode
    ) throws -> (raw: String, boundaryReached: Bool) {
        let start = index
        while index < tokenIDs.count, !isHeaderBoundary(tokenIDs[index]) {
            guard !isSpecialTokenID(tokenIDs[index]) else {
                throw ParseError.malformed
            }
            index += 1
        }
        guard index < tokenIDs.count || mode == .streaming else {
            throw ParseError.incomplete
        }
        return (decode(Array(tokenIDs[start..<index])).trimmingCharacters(in: .whitespacesAndNewlines), index < tokenIDs.count)
    }

    private static func consumeBody(_ tokenIDs: [Int], index: inout Int, mode _: Mode) throws -> Int? {
        while index < tokenIDs.count {
            let tokenID = tokenIDs[index]
            if tokenID == endTokenID || tokenID == returnTokenID || tokenID == callTokenID {
                return tokenID
            }
            guard !isStructuralTokenID(tokenID) else {
                throw ParseError.malformed
            }
            index += 1
        }
        return nil
    }

    private static func incompleteResult(mode: Mode) -> ParseResult {
        switch mode {
        case .streaming:
            return ParseResult(status: .incomplete, content: nil, toolCalls: [], finalContentTokenCount: 0, finalContentTokenIDs: [], failure: nil)
        case .complete(let finishReason) where finishReason == "length":
            return malformedResult(.malformed)
        case .complete(let finishReason) where finishReason == "request_stop":
            return malformedResult(.malformed)
        case .complete:
            return malformedResult(.malformed)
        }
    }

    private static func allowsLengthTruncatedFinal(mode: Mode) -> Bool {
        switch mode {
        case .streaming:
            return true
        case .complete(let finishReason):
            return finishReason == "length" || finishReason == "request_stop"
        }
    }

    private struct Header {
        let channel: String
        let recipient: String?
    }

    private static func parseRoleHeaderTokenIDs(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        boundaryReached: Bool,
        mode: Mode
    ) throws -> String? {
        try parseRoleHeader(
            decode(tokenIDs).trimmingCharacters(in: .whitespacesAndNewlines),
            boundaryReached: boundaryReached,
            mode: mode
        )
    }

    private static func parseChannelHeaderTokenIDs(
        _ tokenIDs: [Int],
        decode: ([Int]) -> String,
        boundaryReached: Bool,
        mode: Mode
    ) throws -> Header {
        try parseChannelHeader(
            decode(tokenIDs).trimmingCharacters(in: .whitespacesAndNewlines),
            boundaryReached: boundaryReached,
            mode: mode
        )
    }

    private static func parseRoleHeader(_ raw: String, boundaryReached: Bool, mode: Mode) throws -> String? {
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.first == "assistant" else {
            if mode == .streaming, !boundaryReached {
                throw ParseError.incomplete
            }
            throw ParseError.malformed
        }
        var recipient: String?
        for part in parts.dropFirst() {
            guard part.hasPrefix("to=") else {
                if mode == .streaming, !boundaryReached {
                    throw ParseError.incomplete
                }
                throw ParseError.malformed
            }
            let value = String(part.dropFirst(3))
            guard recipient == nil, !value.isEmpty else {
                throw ParseError.malformed
            }
            recipient = value
        }
        return recipient
    }

    private static func parseChannelHeader(_ raw: String, boundaryReached: Bool, mode: Mode) throws -> Header {
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let channel = parts.first, isKnownChannel(channel) else {
            if mode == .streaming, !boundaryReached {
                throw ParseError.incomplete
            }
            throw ParseError.malformed
        }
        var recipient: String?
        for part in parts.dropFirst() {
            guard part.hasPrefix("to=") else {
                if mode == .streaming, !boundaryReached {
                    throw ParseError.incomplete
                }
                throw ParseError.malformed
            }
            let value = String(part.dropFirst(3))
            guard recipient == nil, !value.isEmpty else {
                throw ParseError.malformed
            }
            recipient = value
        }
        return Header(channel: channel, recipient: recipient)
    }

    private static func mergeHeader(_ channelHeader: Header, roleRecipient: String?) throws -> Header {
        guard roleRecipient == nil || channelHeader.recipient == nil else {
            throw ParseError.malformed
        }
        return Header(channel: channelHeader.channel, recipient: channelHeader.recipient ?? roleRecipient)
    }

    private static func malformedResult(_ failure: Failure) -> ParseResult {
        ParseResult(
            status: .malformed,
            content: nil,
            toolCalls: [],
            finalContentTokenCount: 0,
            finalContentTokenIDs: [],
            failure: failure
        )
    }

    private static func stopTruncatedResult(
        content: String,
        tokenIDs: [Int],
        decode: ([Int]) -> String,
        stopCandidates: [String]
    ) -> ParseResult? {
        let candidates = stopCandidates.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        var earliestStop: String.Index?
        for stop in candidates {
            if let range = content.range(of: stop),
               earliestStop == nil || range.lowerBound < earliestStop!
            {
                earliestStop = range.lowerBound
            }
        }
        guard earliestStop != nil else { return nil }
        return ParseResult(
            status: .incomplete,
            content: nilIfEmpty(content),
            toolCalls: [],
            finalContentTokenCount: tokenIDs.count,
            finalContentTokenIDs: tokenIDs,
            failure: nil
        )
    }

    private static func rejectStopCandidate(in text: String, stopCandidates: [String]) throws {
        guard containsStopCandidate(text, stopCandidates: stopCandidates) else { return }
        throw ParseError.malformed
    }

    private static func containsStopCandidate(_ text: String, stopCandidates: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        return stopCandidates.contains { stop in
            !stop.isEmpty && text.contains(stop)
        }
    }

    private struct StopCandidateMatcher {
        private let candidates: [String]
        private let maxCandidateLength: Int
        private var suffix = ""

        init(stopCandidates: [String]) {
            candidates = stopCandidates.filter { !$0.isEmpty }
            maxCandidateLength = candidates.map(\.count).max() ?? 0
        }

        mutating func append(_ text: String) throws {
            guard !text.isEmpty, !candidates.isEmpty else { return }
            let window = suffix + text
            if containsStopCandidate(window, stopCandidates: candidates) {
                throw ParseError.malformed
            }
            guard maxCandidateLength > 1 else {
                suffix = ""
                return
            }
            suffix = String(window.suffix(maxCandidateLength - 1))
        }
    }

    private static func toolArgumentByteCount(_ arguments: String) throws -> Int {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.malformed
        }
        let argumentBytes = trimmed.utf8.count
        guard argumentBytes <= ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
            throw ParseError.perCallByteCapExceeded
        }
        return argumentBytes
    }

    private static func toolCall(
        functionName: String,
        arguments: String,
        prevalidatedArgumentBytes: Int? = nil
    ) throws -> (call: ToolCall, argumentBytes: Int) {
        guard isFunctionName(functionName) else {
            throw ParseError.malformed
        }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8)
        else {
            throw ParseError.malformed
        }
        let argumentBytes: Int
        if let prevalidatedArgumentBytes {
            argumentBytes = prevalidatedArgumentBytes
        } else {
            argumentBytes = try toolArgumentByteCount(arguments)
        }
        try JSONValidator.validate(data)
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard parsed is [String: Any] else {
            throw ParseError.malformed
        }
        return (
            ToolCall(
                id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                functionName: functionName,
                arguments: trimmed
            ),
            argumentBytes
        )
    }

    private static func isFunctionRecipient(_ recipient: String?) -> Bool {
        recipient?.hasPrefix("functions.") ?? false
    }

    private static func isKnownChannel(_ channel: String) -> Bool {
        channel == "analysis" || channel == "commentary" || channel == "final"
    }

    private static func isFunctionName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    private static func isHeaderBoundary(_ tokenID: Int) -> Bool {
        tokenID == messageTokenID || tokenID == constrainTokenID
    }

    private static func isMessageBoundary(_ tokenID: Int) -> Bool {
        tokenID == endTokenID || tokenID == returnTokenID || tokenID == callTokenID
    }

    private static func isStructuralTokenID(_ tokenID: Int) -> Bool {
        tokenID == startTokenID || tokenID == channelTokenID || tokenID == messageTokenID || tokenID == constrainTokenID
    }

    private static func isSpecialTokenID(_ tokenID: Int) -> Bool {
        isStructuralTokenID(tokenID) || isMessageBoundary(tokenID)
    }

    private static func nilIfBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private enum ParseError: Error {
        case incomplete
        case malformed
        case perCallByteCapExceeded
        case responseByteCapExceeded
    }
}

private enum JSONValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(data: data)
        try parser.parse()
    }

    private struct Parser {
        private let bytes: [UInt8]
        private var index = 0

        init(data: Data) {
            bytes = Array(data)
        }

        mutating func parse() throws {
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else {
                throw ValidationError.invalid
            }
        }

        private mutating func parseValue(depth: Int) throws {
            skipWhitespace()
            guard index < bytes.count else {
                throw ValidationError.invalid
            }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                try parseObject(depth: depth + 1)
            case UInt8(ascii: "["):
                try parseArray(depth: depth + 1)
            case UInt8(ascii: "\""):
                try parseString()
            case UInt8(ascii: "t"):
                try consume("true")
            case UInt8(ascii: "f"):
                try consume("false")
            case UInt8(ascii: "n"):
                try consume("null")
            default:
                try parseNumber()
            }
        }

        private mutating func parseObject(depth: Int) throws {
            guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else {
                throw ValidationError.invalid
            }
            try consumeByte(UInt8(ascii: "{"))
            skipWhitespace()
            var keys = Set<String>()
            if consumeByteIfPresent(UInt8(ascii: "}")) {
                return
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw ValidationError.invalid
                }
                skipWhitespace()
                try consumeByte(UInt8(ascii: ":"))
                try parseValue(depth: depth)
                skipWhitespace()
                if consumeByteIfPresent(UInt8(ascii: "}")) {
                    return
                }
                try consumeByte(UInt8(ascii: ","))
            }
        }

        private mutating func parseArray(depth: Int) throws {
            guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else {
                throw ValidationError.invalid
            }
            try consumeByte(UInt8(ascii: "["))
            skipWhitespace()
            if consumeByteIfPresent(UInt8(ascii: "]")) {
                return
            }
            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consumeByteIfPresent(UInt8(ascii: "]")) {
                    return
                }
                try consumeByte(UInt8(ascii: ","))
            }
        }

        @discardableResult
        private mutating func parseString() throws -> String {
            try consumeByte(UInt8(ascii: "\""))
            let start = index
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                    index += 1
                    continue
                }
                if byte == UInt8(ascii: "\\") {
                    escaped = true
                    index += 1
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    let data = Data(bytes[start..<index])
                    index += 1
                    guard let raw = String(data: data, encoding: .utf8),
                          let decodedData = "\"\(raw)\"".data(using: .utf8),
                          let decoded = try JSONSerialization.jsonObject(with: decodedData, options: [.fragmentsAllowed]) as? String
                    else {
                        throw ValidationError.invalid
                    }
                    return decoded
                }
                index += 1
            }
            throw ValidationError.invalid
        }

        private mutating func parseNumber() throws {
            let start = index
            if consumeByteIfPresent(UInt8(ascii: "-")) {}
            guard index < bytes.count, bytes[index].isDigit else {
                throw ValidationError.invalid
            }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, bytes[index].isDigit {
                    index += 1
                }
            }
            if consumeByteIfPresent(UInt8(ascii: ".")) {
                guard index < bytes.count, bytes[index].isDigit else {
                    throw ValidationError.invalid
                }
                while index < bytes.count, bytes[index].isDigit {
                    index += 1
                }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                guard index < bytes.count, bytes[index].isDigit else {
                    throw ValidationError.invalid
                }
                while index < bytes.count, bytes[index].isDigit {
                    index += 1
                }
            }
            guard start < index else {
                throw ValidationError.invalid
            }
        }

        private mutating func consume(_ string: String) throws {
            for byte in string.utf8 {
                try consumeByte(byte)
            }
        }

        private mutating func consumeByte(_ byte: UInt8) throws {
            guard consumeByteIfPresent(byte) else {
                throw ValidationError.invalid
            }
        }

        private mutating func consumeByteIfPresent(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else {
                return false
            }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, bytes[index].isJSONWhitespace {
                index += 1
            }
        }
    }

    private enum ValidationError: Error {
        case invalid
    }
}

private extension UInt8 {
    var isDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }

    var isJSONWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\n") || self == UInt8(ascii: "\r") || self == UInt8(ascii: "\t")
    }
}
