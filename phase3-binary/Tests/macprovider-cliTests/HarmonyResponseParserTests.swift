import XCTest
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli

final class HarmonyResponseParserTests: XCTestCase {
    private var decodedTextByID: [Int: String] = [:]
    private var nextTextTokenID = 1_000

    override func setUp() {
        super.setUp()
        decodedTextByID = [:]
        nextTextTokenID = 1_000
    }

    func testHarmonyModelIDDetectionMatchesGptOssCaseInsensitively() {
        XCTAssertTrue(HarmonyResponseParser.isHarmonyModelID("openai/gpt-oss-20b"))
        XCTAssertTrue(HarmonyResponseParser.isHarmonyModelID("GPT-OSS-120B"))
        XCTAssertFalse(HarmonyResponseParser.isHarmonyModelID("mlx-community/Qwen3-32B-4bit"))
    }

    func testHarmonyTerminalPreservingTokenizerHidesReturnEOSFromGenerationStopSet() {
        let tokenizer = HarmonyFixtureTokenizer(eosToken: "<|return|>", unknownToken: "<unk>")
        XCTAssertEqual(tokenizer.eosTokenId, HarmonyResponseParser.returnTokenID)

        let wrapped = ModelRuntime.HarmonyTerminalPreservingTokenizer(base: tokenizer)

        XCTAssertNil(wrapped.eosToken)
        XCTAssertNil(wrapped.eosTokenId)
        XCTAssertEqual(wrapped.convertTokenToId("<|return|>"), HarmonyResponseParser.returnTokenID)
        XCTAssertEqual(wrapped.convertTokenToId("<|call|>"), HarmonyResponseParser.callTokenID)
        XCTAssertEqual(wrapped.decode(tokenIds: [HarmonyResponseParser.returnTokenID]), "<|return|>")
    }

    func testNonHarmonyEOSTokenSurvivesTerminalPreservingTokenizer() {
        let tokenizer = HarmonyFixtureTokenizer(eosToken: "<eos>", unknownToken: "<unk>")
        let wrapped = ModelRuntime.HarmonyTerminalPreservingTokenizer(base: tokenizer)

        XCTAssertEqual(wrapped.eosToken, "<eos>")
        XCTAssertEqual(wrapped.eosTokenId, 2)
    }

    func testHarmonyTerminalFinishDetectsTerminalAtMaxTokenBoundary() {
        XCTAssertTrue(ModelRuntime.isHarmonyTerminalFinish(
            modelID: "openai/gpt-oss-120b",
            generatedTokenIDs: [1_001, HarmonyResponseParser.returnTokenID]
        ))
        XCTAssertTrue(ModelRuntime.isHarmonyTerminalFinish(
            modelID: "openai/gpt-oss-120b",
            generatedTokenIDs: [1_001, HarmonyResponseParser.callTokenID]
        ))
        XCTAssertFalse(ModelRuntime.isHarmonyTerminalFinish(
            modelID: "mlx-community/Qwen3-32B-4bit",
            generatedTokenIDs: [1_001, HarmonyResponseParser.returnTokenID]
        ))
    }

    func testFinalChannelContentIsExposedAndTokenCounted() {
        let parsed = parse([
            token(.start),
            text("assistant"),
            token(.channel),
            text("final"),
            token(.message),
            text("Hello"),
            text(", world"),
            token(.return),
        ])

        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertEqual(parsed.content, "Hello, world")
        XCTAssertEqual(parsed.finalContentTokenCount, 2)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testWhitespaceOnlyFinalChannelContentIsPreservedAndTokenCounted() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text(" \n"),
            token(.return),
        ]
        let parsed = parse(ids)

        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertEqual(parsed.content, " \n")
        XCTAssertEqual(parsed.finalContentTokenCount, 1)

        let runtimeParsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )
        XCTAssertEqual(runtimeParsed.content, " \n")
        XCTAssertEqual(runtimeParsed.completionTokens, 1)
    }

    func testOutputMayBeginDirectlyAtChannelToken() {
        let parsed = parse([
            token(.channel),
            text("final"),
            token(.message),
            text("Ready"),
            token(.return),
        ])

        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertEqual(parsed.content, "Ready")
        XCTAssertEqual(parsed.finalContentTokenCount, 1)
    }

    func testAnalysisAndNonToolCommentaryAreSuppressed() {
        let parsed = parse([
            token(.start),
            text("assistant"),
            token(.channel),
            text("analysis"),
            token(.message),
            text("secret reasoning"),
            token(.end),
            token(.start),
            text("assistant"),
            token(.channel),
            text("commentary"),
            token(.message),
            text("visible commentary"),
            token(.end),
            token(.start),
            text("assistant"),
            token(.channel),
            text("final"),
            token(.message),
            text("Public answer"),
            token(.return),
        ])

        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertEqual(parsed.content, "Public answer")
        XCTAssertEqual(parsed.finalContentTokenCount, 1)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testCommentaryFunctionJSONCallConvertsToToolCall() throws {
        let parsed = parse([
            token(.start),
            text("assistant"),
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather","limit":2}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertNil(parsed.content)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertTrue(call.id.hasPrefix("call_"))
        XCTAssertEqual(call.functionName, "lookup")
        XCTAssertEqual(try argumentValue(call.arguments, key: "query") as? String, "weather")
        XCTAssertEqual(try argumentValue(call.arguments, key: "limit") as? Int, 2)
    }

    func testRoleHeaderFunctionRecipientConvertsToToolCall() throws {
        let ids = [
            token(.start),
            text("assistant to=functions.lookup"),
            token(.channel),
            text("commentary"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ]

        let parsed = parse(ids, allowedFunctionNames: ["lookup"])
        let streamed = parse(ids, allowedFunctionNames: ["lookup"], mode: .streaming)

        XCTAssertEqual(parsed.status, .parsed)
        XCTAssertEqual(streamed.toolCalls.count, 1)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "lookup")
        XCTAssertEqual(try argumentValue(call.arguments, key: "query") as? String, "weather")
    }

    func testDuplicateRoleAndChannelRecipientsFailClosed() {
        let parsed = parse([
            token(.start),
            text("assistant to=functions.lookup"),
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMalformedToolJSONFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"one","query":"two"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testNonObjectToolJSONFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"["not","an","object"]"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testFunctionRecipientRequiresDeclaredAllowedFunction() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testFunctionRecipientRejectsExtraHeaderFields() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup extra=ignored"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testFunctionRecipientOnFinalChannelFailsClosed() {
        let ids = [
            token(.channel),
            text("final to=functions.lookup"),
            token(.message),
            text("not a tool"),
            token(.return),
        ]

        let parsed = parse(ids, allowedFunctionNames: ["lookup"])
        let streamed = parse(ids, allowedFunctionNames: ["lookup"], mode: .streaming)

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(streamed.status, .malformed)
        XCTAssertNil(streamed.content)
        XCTAssertTrue(streamed.toolCalls.isEmpty)
    }

    func testFunctionRecipientOnAnalysisChannelFailsClosed() {
        let ids = [
            token(.channel),
            text("analysis to=functions.lookup"),
            token(.message),
            text("hidden"),
            token(.return),
        ]

        let parsed = parse(ids, allowedFunctionNames: ["lookup"])
        let streamed = parse(ids, allowedFunctionNames: ["lookup"], mode: .streaming)

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(streamed.status, .malformed)
        XCTAssertNil(streamed.content)
        XCTAssertTrue(streamed.toolCalls.isEmpty)
    }

    func testCallTerminatorWithoutFunctionRecipientFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("commentary"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testCumulativeStreamingPrefixesDoNotLeakHeadersOrMarkers() {
        let prefixes: [[Int]] = [
            [token(.channel)],
            [token(.channel), text("final")],
            [token(.channel), text("final"), token(.message)],
        ]

        for prefix in prefixes {
            let parsed = parse(prefix, mode: .streaming)
            XCTAssertEqual(parsed.status, .incomplete)
            XCTAssertNil(parsed.content)
            XCTAssertTrue(parsed.toolCalls.isEmpty)
            XCTAssertEqual(parsed.finalContentTokenCount, 0)
        }

        let partial = parse([
            token(.channel),
            text("final"),
            token(.message),
            text("partial"),
        ], mode: .streaming)
        XCTAssertEqual(partial.status, .incomplete)
        XCTAssertEqual(partial.content, "partial")
        XCTAssertTrue(partial.toolCalls.isEmpty)
        XCTAssertEqual(partial.finalContentTokenCount, 1)

        let complete = parse([
            token(.channel),
            text("final"),
            token(.message),
            text("partial"),
            token(.return),
        ])
        XCTAssertEqual(complete.status, .parsed)
        XCTAssertEqual(complete.content, "partial")
        XCTAssertEqual(complete.finalContentTokenCount, 1)
    }

    func testCompletedTruncatedHarmonyFailsClosedAsMalformed() {
        let parsed = parse([
            token(.start),
            text("assistant"),
            token(.channel),
            text("final"),
            token(.message),
            text("unfinished"),
        ])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testCompletedStopAfterHiddenEndFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.end),
        ], mode: .complete(finishReason: "stop"))

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testStreamingAfterHiddenEndIsSnapshotIncomplete() {
        let parsed = parse([
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.end),
        ], mode: .streaming)

        XCTAssertEqual(parsed.status, .incomplete)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testCompletedLengthTruncatedFinalChannelCanExposeCurrentContent() {
        let parsed = parse([
            token(.channel),
            text("final"),
            token(.message),
            text("unfinished"),
        ], mode: .complete(finishReason: "length"))

        XCTAssertEqual(parsed.status, .incomplete)
        XCTAssertEqual(parsed.content, "unfinished")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 1)
    }

    func testCompletedLengthTruncatedHiddenChannelFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
        ], mode: .complete(finishReason: "length"))

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testCompletedLengthTruncatedFunctionCallFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"unfinished"#),
        ], allowedFunctionNames: ["lookup"], mode: .complete(finishReason: "length"))

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testStreamingIncompleteToolCallDoesNotEmitPartialToolCall() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"partial""#),
        ], mode: .streaming)

        XCTAssertEqual(parsed.status, .incomplete)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testStreamingSplitHeadersRemainIncompleteUntilBoundary() {
        let finalPrefix = parse([
            token(.channel),
            text("fi"),
        ], mode: .streaming)
        XCTAssertEqual(finalPrefix.status, .incomplete)
        XCTAssertNil(finalPrefix.content)

        let analysisPrefix = parse([
            token(.channel),
            text("anal"),
        ], mode: .streaming)
        XCTAssertEqual(analysisPrefix.status, .incomplete)
        XCTAssertNil(analysisPrefix.content)

        let commentaryPrefix = parse([
            token(.channel),
            text("commentary to=functions.look"),
        ], mode: .streaming)
        XCTAssertEqual(commentaryPrefix.status, .incomplete)
        XCTAssertNil(commentaryPrefix.content)
    }

    func testCompleteParserRejectsStrayStructuralTokensBeforeChannel() {
        let ids = [
            token(.start),
            token(.message),
            token(.channel),
            text("final"),
            token(.message),
            text("Public"),
            token(.return),
        ]

        XCTAssertEqual(parse(ids).status, .malformed)
        XCTAssertEqual(parse(ids, mode: .streaming).status, .malformed)
    }

    func testCompleteParserRejectsStructuralTokensInsideHeader() {
        let ids = [
            token(.channel),
            text("fi"),
            token(.channel),
            text("nal"),
            token(.message),
            text("Public"),
            token(.return),
        ]

        XCTAssertEqual(parse(ids).status, .malformed)
        XCTAssertEqual(parse(ids, mode: .streaming).status, .malformed)
    }

    func testCompleteParserRejectsStructuralTokensInsideConstrainLabel() {
        let ids = [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("js"),
            token(.channel),
            text("on"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ]

        XCTAssertEqual(parse(ids, allowedFunctionNames: ["lookup"]).status, .malformed)
        XCTAssertEqual(parse(ids, allowedFunctionNames: ["lookup"], mode: .streaming).status, .malformed)
    }

    func testStreamingParserProcessesCumulativeSnapshotsWithoutLeakingMarkers() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.end),
            token(.channel),
            text("final"),
            token(.message),
            text("Public"),
            text(" answer"),
            token(.return),
        ]
        var parser = HarmonyResponseParser.StreamingParser(decode: decode)

        XCTAssertEqual(parser.parse(cumulativeTokenIDs: Array(ids.prefix(1))).status, .incomplete)
        XCTAssertNil(parser.parse(cumulativeTokenIDs: Array(ids.prefix(5))).content)

        let partial = parser.parse(cumulativeTokenIDs: Array(ids.prefix(10)))
        XCTAssertEqual(partial.status, .incomplete)
        XCTAssertEqual(partial.content, "Public answer")
        XCTAssertEqual(partial.finalContentTokenCount, 2)

        let terminal = parser.parse(cumulativeTokenIDs: ids)
        XCTAssertEqual(terminal.status, .parsed)
        XCTAssertEqual(terminal.content, "Public answer")
        XCTAssertEqual(terminal.finalContentTokenCount, 2)

        let complete = parse(ids)
        XCTAssertEqual(terminal.content, complete.content)
        XCTAssertEqual(terminal.toolCalls, complete.toolCalls)
        XCTAssertEqual(terminal.finalContentTokenCount, complete.finalContentTokenCount)
    }

    func testStreamingParserDoesNotStopAfterFirstToolCallInMultiCallOutput() throws {
        let first = harmonyToolCall(functionName: "lookup", arguments: #"{"query":"one"}"#)
        let second = harmonyToolCall(functionName: "lookup", arguments: #"{"query":"two"}"#)
        let ids = first + second
        var parser = HarmonyResponseParser.StreamingParser(decode: decode, allowedFunctionNames: ["lookup"])

        let afterFirst = parser.parse(cumulativeTokenIDs: first)
        XCTAssertEqual(afterFirst.status, .incomplete)
        XCTAssertEqual(afterFirst.toolCalls.count, 1)

        let afterSecond = parser.parse(cumulativeTokenIDs: ids)
        XCTAssertEqual(afterSecond.status, .incomplete)
        XCTAssertEqual(afterSecond.toolCalls.count, 2)

        let complete = parse(ids, allowedFunctionNames: ["lookup"])
        XCTAssertEqual(complete.status, .parsed)
        XCTAssertEqual(complete.toolCalls.count, 2)
        XCTAssertEqual(afterSecond.toolCalls.map(\.functionName), complete.toolCalls.map(\.functionName))
    }

    func testStreamingParserFinalContentUsesStreamingDetokenizerHook() {
        let firstScalarToken = text("\u{FFFD}")
        let secondScalarToken = text("")
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            firstScalarToken,
            secondScalarToken,
            token(.return),
        ]
        let nonAdditiveDecode: ([Int]) -> String = { [decodedTextByID] tokenIDs in
            if tokenIDs == [firstScalarToken, secondScalarToken] {
                return "é"
            }
            return tokenIDs.map { decodedTextByID[$0] ?? "" }.joined()
        }
        var bufferedFinalTokens: [Int] = []
        var parser = HarmonyResponseParser.StreamingParser(
            decode: nonAdditiveDecode,
            decodeFinalToken: { tokenID in
                bufferedFinalTokens.append(tokenID)
                guard bufferedFinalTokens == [firstScalarToken, secondScalarToken] else {
                    return nil
                }
                bufferedFinalTokens.removeAll(keepingCapacity: true)
                return "é"
            }
        )

        let streamed = parser.parse(cumulativeTokenIDs: ids)
        let complete = HarmonyResponseParser.parse(tokenIDs: ids, decode: nonAdditiveDecode)

        XCTAssertEqual(streamed.status, .parsed)
        XCTAssertEqual(streamed.content, "é")
        XCTAssertEqual(streamed.content, complete.content)
        XCTAssertEqual(streamed.finalContentTokenCount, complete.finalContentTokenCount)
    }

    func testNonHarmonyReturnsOriginalContentAsNotApplicable() {
        let parsed = parse([
            text("plain "),
            text("answer"),
        ])

        XCTAssertEqual(parsed.status, .notApplicable)
        XCTAssertEqual(parsed.content, "plain answer")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.finalContentTokenCount, 0)
    }

    func testRuntimeHarmonyOutputUsesFinalChannelContentAndTokenAccounting() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.end),
            token(.channel),
            text("commentary"),
            token(.message),
            text("not public"),
            token(.end),
            token(.channel),
            text("final"),
            token(.message),
            text("Public"),
            text(" answer"),
            token(.return),
        ]

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "mlx-community/gpt-oss-20b"),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )

        XCTAssertEqual(parsed.content, "Public answer")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.completionTokens, 2)
        XCTAssertEqual(parsed.generatedCompletionTokens, ids.count)
        XCTAssertTrue(parsed.isTerminal)
    }

    func testRuntimeHarmonyToolCallOnlyOutputHasNullContentAccounting() throws {
        let ids = [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ]

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )

        XCTAssertEqual(parsed.content, "")
        XCTAssertEqual(parsed.completionTokens, 0)
        XCTAssertEqual(parsed.generatedCompletionTokens, ids.count)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "lookup")
        XCTAssertEqual(try argumentValue(call.arguments, key: "query") as? String, "weather")
    }

    func testRuntimeHarmonyMissingFinalReturnFailsClosedOnCleanStop() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("Public"),
            text(" answer"),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyMissingToolCallTerminatorFailsClosedOnCleanStop() throws {
        let ids = [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyMissingHiddenReturnFailsClosedOnCleanStop() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyLengthDoesNotInferStrippedTerminalEOS() throws {
        let ids = [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "length"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyVisibleStopSuppressesLaterToolCall() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("Public "),
            text("STOP"),
            text("hidden"),
            token(.end),
        ] + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"weather"}"#)

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )

        XCTAssertEqual(parsed.content, "Public ")
        XCTAssertEqual(parsed.completionTokens, 1)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertTrue(parsed.hitStop)
    }

    func testHarmonyPostReturnToolCallFailsClosed() {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("Done"),
            token(.return),
        ] + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"post-stop"}"#)

        let parsed = parse(ids, allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testHarmonyPostAnalysisReturnToolCallFailsClosed() {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.return),
        ] + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"post-stop"}"#)

        let parsed = parse(ids, allowedFunctionNames: ["lookup"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testStreamingHarmonyPostReturnToolCallFailsClosed() {
        let terminal = [
            token(.channel),
            text("final"),
            token(.message),
            text("Done"),
            token(.return),
        ]
        let ids = terminal + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"post-stop"}"#)
        var parser = HarmonyResponseParser.StreamingParser(decode: decode, allowedFunctionNames: ["lookup"])

        let terminalParsed = parser.parse(cumulativeTokenIDs: terminal)
        XCTAssertEqual(terminalParsed.status, .parsed)
        XCTAssertEqual(terminalParsed.content, "Done")

        let parsed = parser.parse(cumulativeTokenIDs: ids)
        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testRuntimeHarmonyPostReturnToolCallFailsClosed() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("Done"),
            token(.return),
        ] + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"post-stop"}"#)

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyToolThenFinalSuppressesMixedContent() throws {
        let ids = harmonyToolCall(functionName: "lookup", arguments: #"{"query":"weather"}"#) + [
            token(.channel),
            text("final"),
            token(.message),
            text("ignored"),
            token(.return),
        ]

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )

        XCTAssertEqual(parsed.content, "")
        XCTAssertEqual(parsed.completionTokens, 0)
        XCTAssertEqual(parsed.toolCalls.count, 1)
    }

    func testRuntimeHarmonyFinalThenToolSuppressesMixedContent() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("ignored"),
            token(.end),
        ] + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"weather"}"#)

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )

        XCTAssertEqual(parsed.content, "")
        XCTAssertEqual(parsed.completionTokens, 0)
        XCTAssertEqual(parsed.toolCalls.count, 1)
    }

    func testRuntimeHarmonyRequestStopAdjustsVisibleTokenAccounting() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("Public "),
            text("STOP"),
            text("hidden"),
            token(.return),
        ]

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )

        XCTAssertEqual(parsed.content, "Public ")
        XCTAssertEqual(parsed.completionTokens, 1)
        XCTAssertTrue(parsed.hitStop)
    }

    func testRuntimeHarmonyRequestStopBeforeReturnDoesNotFailClosed() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("Public "),
            text("STOP"),
            text("hidden"),
        ]

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )

        XCTAssertEqual(parsed.content, "Public ")
        XCTAssertEqual(parsed.completionTokens, 1)
        XCTAssertTrue(parsed.hitStop)
        XCTAssertFalse(parsed.isTerminal)
    }

    func testRuntimeHarmonyRequestStopInsideHiddenAnalysisFailsClosed() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("STOP"),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: "",
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyRequestStopInsideClosedHiddenAnalysisFailsClosed() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("STOP"),
            token(.end),
            token(.channel),
            text("final"),
            token(.message),
            text("Public"),
            token(.return),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: "",
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b"),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyRequestStopInsideHiddenAnalysisBeforeToolFailsClosed() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("STOP"),
            token(.end),
        ] + harmonyToolCall(functionName: "lookup", arguments: #"{"query":"weather"}"#)

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: "",
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyRequestStopInsideIncompleteFunctionCallFailsClosed() throws {
        let ids = [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"STOP"#),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: "",
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["STOP"]
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testHarmonyRequestStopInsideClosedFunctionCallFailsClosed() {
        let parsed = parse(
            harmonyToolCall(functionName: "lookup", arguments: #"{"query":"STOP"}"#),
            allowedFunctionNames: ["lookup"],
            stopCandidates: ["STOP"]
        )

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testHarmonyRequestStopInsideHeaderFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookupSTOP"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookupSTOP"], stopCandidates: ["STOP"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testHarmonyRequestStopInsideConstrainFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("jsSTOPon"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"], stopCandidates: ["STOP"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testHarmonyRequestStopAcrossHiddenAndHeaderFailsClosed() {
        let parsed = parse([
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.end),
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ], allowedFunctionNames: ["lookup"], stopCandidates: ["hiddencommentary"])

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testRuntimeHarmonyGlobalRequestStopOutsideVisibleFinalFailsClosed() throws {
        let ids = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("hidden"),
            token(.end),
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.call),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "request_stop"),
            defaultCompletionTokens: ids.count,
            requestStops: ["hiddencommentary"],
            globalHitStop: true
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testStreamingHarmonyRequestStopInsideHiddenAnalysisFailsClosed() {
        let hidden = [
            token(.channel),
            text("analysis"),
            token(.message),
            text("ST"),
            text("OP"),
        ]
        var parser = HarmonyResponseParser.StreamingParser(
            decode: decode,
            allowedFunctionNames: ["lookup"],
            stopCandidates: ["STOP"]
        )

        let prefix = parser.parse(cumulativeTokenIDs: Array(hidden.prefix(4)))
        XCTAssertEqual(prefix.status, .incomplete)

        let stopped = parser.parse(cumulativeTokenIDs: hidden)
        XCTAssertEqual(stopped.status, .malformed)
        XCTAssertNil(stopped.content)
        XCTAssertTrue(stopped.toolCalls.isEmpty)
    }

    func testRuntimeHarmonyMalformedOutputFailsClosedWithRetryableCode() throws {
        let ids = [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            text(#"{"query":"weather"}"#),
            token(.end),
        ]

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "malformed_tool_call_final_json")
        }
    }

    func testRuntimeHarmonyPerCallByteCapUsesSpecificCode() throws {
        let oversizedArguments = #"{"blob":"\#(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP))"}"#
        let ids = harmonyToolCall(functionName: "lookup", arguments: oversizedArguments)

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "byte_cap_exceeded")
        }
    }

    func testHarmonyOversizedInvalidToolArgumentsHitByteCapBeforeJSONValidation() {
        let oversizedInvalidArguments = #"{"blob":"\#(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP))"#
        let parsed = parse(
            harmonyToolCall(functionName: "lookup", arguments: oversizedInvalidArguments),
            allowedFunctionNames: ["lookup"]
        )

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertEqual(parsed.failure, .perCallByteCapExceeded)
    }

    func testRuntimeHarmonyAggregateByteCapUsesSpecificCode() throws {
        let arguments = #"{"blob":"\#(String(repeating: "x", count: 700_000))"}"#
        let ids = harmonyToolCall(functionName: "lookup", arguments: arguments)
            + harmonyToolCall(functionName: "lookup", arguments: arguments)
            + harmonyToolCall(functionName: "lookup", arguments: arguments)

        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids),
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "openai/gpt-oss-120b", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "response_byte_cap_exceeded")
        }
    }

    func testHarmonyAggregateByteCapBeatsMalformedJSONValidation() {
        let validArguments = #"{"blob":"\#(String(repeating: "x", count: 700_000))"}"#
        let oversizedMalformedArguments = #"{"blob":"\#(String(repeating: "x", count: 700_000))"#
        let parsed = parse(
            harmonyToolCall(functionName: "lookup", arguments: validArguments)
                + harmonyToolCall(functionName: "lookup", arguments: validArguments)
                + harmonyToolCall(functionName: "lookup", arguments: oversizedMalformedArguments),
            allowedFunctionNames: ["lookup"]
        )

        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertEqual(parsed.failure, .responseByteCapExceeded)
        XCTAssertNil(parsed.content)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testStreamingFunctionByteCapUsesDecodedBodyAtTerminatorNotSingletonTokenBytes() {
        let firstBodyToken = 91_001
        let secondBodyToken = 91_002
        let oversizedBody = #"{"blob":"\#(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP))"}"#
        var parser = HarmonyResponseParser.StreamingParser(
            decode: { tokenIDs in
                switch tokenIDs {
                case [firstBodyToken], [secondBodyToken]:
                    return ""
                case [firstBodyToken, secondBodyToken]:
                    return oversizedBody
                default:
                    return self.decode(tokenIDs)
                }
            },
            allowedFunctionNames: ["lookup"]
        )

        var parsed = parser.parse(newTokenIDs: [
            token(.channel),
            text("commentary to=functions.lookup"),
            token(.constrain),
            text("json"),
            token(.message),
            firstBodyToken,
        ])
        XCTAssertEqual(parsed.status, .incomplete)
        XCTAssertNil(parsed.failure)

        parsed = parser.parse(newTokenIDs: [secondBodyToken])
        XCTAssertEqual(parsed.status, .incomplete)
        XCTAssertNil(parsed.failure)

        parsed = parser.parse(newTokenIDs: [token(.call)])
        XCTAssertEqual(parsed.status, .malformed)
        XCTAssertEqual(parsed.failure, .perCallByteCapExceeded)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testRuntimeNonHarmonyIgnoresHarmonyTokenIDs() throws {
        let ids = [
            token(.channel),
            text("final"),
            token(.message),
            text("plain marker-looking answer"),
            token(.return),
        ]
        let decoded = decode(ids)

        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decoded,
            generatedTokenIDs: ids,
            decode: decode,
            request: request(model: "mlx-community/Qwen3-32B-4bit", tools: ["lookup"]),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: ids.count
        )

        XCTAssertEqual(parsed.content, decoded)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.completionTokens, ids.count)
        XCTAssertTrue(parsed.isTerminal)
    }

    private func parse(
        _ tokenIDs: [Int],
        allowedFunctionNames: Set<String>? = nil,
        mode: HarmonyResponseParser.Mode = .complete(),
        stopCandidates: [String] = []
    ) -> HarmonyResponseParser.ParseResult {
        HarmonyResponseParser.parse(
            tokenIDs: tokenIDs,
            decode: decode,
            allowedFunctionNames: allowedFunctionNames,
            mode: mode,
            stopCandidates: stopCandidates
        )
    }

    private func decode(_ tokenIDs: [Int]) -> String {
        tokenIDs.map { decodedTextByID[$0] ?? "" }.joined()
    }

    private func token(_ special: Special) -> Int {
        special.id
    }

    private func text(_ value: String) -> Int {
        let id = nextTextTokenID
        nextTextTokenID += 1
        decodedTextByID[id] = value
        return id
    }

    private func argumentValue(_ arguments: String, key: String) throws -> Any? {
        let data = try XCTUnwrap(arguments.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object[key]
    }

    private func harmonyToolCall(functionName: String, arguments: String) -> [Int] {
        [
            token(.channel),
            text("commentary to=functions.\(functionName)"),
            token(.constrain),
            text("json"),
            token(.message),
            text(arguments),
            token(.call),
        ]
    }

    private func request(model: String, tools: [String] = []) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hello"]],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { name in
                [
                    "type": "function",
                    "function": [
                        "name": name,
                        "description": "fixture",
                        "parameters": [
                            "type": "object",
                            "properties": [:],
                        ],
                    ],
                ]
            }
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private enum Special {
        case channel
        case start
        case end
        case message
        case constrain
        case `return`
        case call

        var id: Int {
            switch self {
            case .channel: return HarmonyResponseParser.channelTokenID
            case .start: return HarmonyResponseParser.startTokenID
            case .end: return HarmonyResponseParser.endTokenID
            case .message: return HarmonyResponseParser.messageTokenID
            case .constrain: return HarmonyResponseParser.constrainTokenID
            case .return: return HarmonyResponseParser.returnTokenID
            case .call: return HarmonyResponseParser.callTokenID
            }
        }
    }

    private struct HarmonyFixtureTokenizer: MLXLMCommon.Tokenizer {
        let bosToken: String? = "<bos>"
        let eosToken: String?
        let unknownToken: String?

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            let encoded = text.utf8.map(Int.init)
            return addSpecialTokens ? [1] + encoded + [eosTokenId ?? 2] : encoded
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            tokenIds.compactMap(convertIdToToken).joined()
        }

        func convertTokenToId(_ token: String) -> Int? {
            switch token {
            case "<bos>": return 1
            case "<eos>": return 2
            case "<unk>": return 0
            case "<|return|>": return HarmonyResponseParser.returnTokenID
            case "<|call|>": return HarmonyResponseParser.callTokenID
            default: return nil
            }
        }

        func convertIdToToken(_ id: Int) -> String? {
            switch id {
            case 1: return "<bos>"
            case 2: return "<eos>"
            case 0: return "<unk>"
            case HarmonyResponseParser.returnTokenID: return "<|return|>"
            case HarmonyResponseParser.callTokenID: return "<|call|>"
            default: return UnicodeScalar(id).map(String.init) ?? ""
            }
        }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            encode(text: "\(messages)", addSpecialTokens: true)
        }
    }
}
