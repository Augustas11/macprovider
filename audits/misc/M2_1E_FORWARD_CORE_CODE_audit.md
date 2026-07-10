CRITICAL (0):
  (none)

HIGH (0):
  (none)

MEDIUM (0):
  (none)

LOW (2):
  L1. Streaming failover-hit comment now misattributes the WS-only gate to the classifier.
      Evidence: phase4-coordinator/internal/buyer/server.go:1314, phase4-coordinator/internal/buyer/server.go:1324, phase4-coordinator/internal/buyer/server.go:1354
      Fix:     Update the callback comment to say the dispatch callback clears failoverEligible for non-WS streaming attempts, or move that gate into the classifier if the architecture lane chooses that shape.

  L2. Some row-sequence-sensitive branches remain covered functionally, but not by forward_loop row-sequence assertions.
      Evidence: phase4-coordinator/internal/buyer/server.go:1647, phase4-coordinator/internal/buyer/server_test.go:990, phase4-coordinator/internal/buyer/server.go:1452, phase4-coordinator/internal/buyer/server_test.go:2873
      Fix:     Add focused row-sequence tests before the next core edit for receipt-bearing null-usage early-return, HTTP retry-budget exhaustion, and WS-non-streaming cancelled logging/no-logging.

QUESTIONS (2):
  Q1. Should the HTTP-streaming pre-chunk failover gate live in classifyStreamResult instead of the streaming dispatch callback?
      Evidence: phase4-coordinator/internal/buyer/server.go:1314, phase4-coordinator/internal/buyer/server.go:1324, phase4-coordinator/internal/buyer/transport_result.go:154
      Fix:     Architect-overlap only: current placement preserves behavior, but classifier ownership would make the transportResult contract more self-contained.

  Q2. The prompt says 12 forward_loop row-sequence scenarios, but the file currently has 11 named RowSequence tests.
      Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:54, phase4-coordinator/internal/buyer/forward_loop_test.go:755
      Fix:     Confirm whether the "12" count includes a non-RowSequence test or whether one expected scenario is missing from forward_loop_test.go.

CODE-LANE TRACE NOTES:
  - Core order reviewed as dispatch -> committed -> non-retryable terminal -> success -> fault mutations -> failover -> retry gate -> log -> advance -> afterAdvance. Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:68, phase4-coordinator/internal/buyer/forward_with_failover.go:82, phase4-coordinator/internal/buyer/forward_with_failover.go:94, phase4-coordinator/internal/buyer/forward_with_failover.go:106, phase4-coordinator/internal/buyer/forward_with_failover.go:114, phase4-coordinator/internal/buyer/forward_with_failover.go:130, phase4-coordinator/internal/buyer/forward_with_failover.go:163, phase4-coordinator/internal/buyer/forward_with_failover.go:176, phase4-coordinator/internal/buyer/forward_with_failover.go:177, phase4-coordinator/internal/buyer/forward_with_failover.go:190.
  - WS-non-streaming queue-full path preserves markBusy, retry-budget bypass, 502/503 logAttempt behavior, advance, and HTTP fallthrough guard. Evidence: phase4-coordinator/internal/buyer/transport_result.go:97, phase4-coordinator/internal/buyer/forward_with_failover.go:116, phase4-coordinator/internal/buyer/server.go:1482, phase4-coordinator/internal/buyer/server.go:1499, phase4-coordinator/internal/buyer/forward_with_failover.go:177, phase4-coordinator/internal/buyer/server.go:1509, phase4-coordinator/internal/buyer/forward_loop_test.go:755.
  - WS-non-streaming failover miss bypasses shouldRetry because onFailoverMiss returns handled=true and the core returns immediately. Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:145, phase4-coordinator/internal/buyer/server.go:1473.
  - HTTP-streaming pre-chunk disconnect on non-WS preserves advance-driven retry rather than same-attempt failover by clearing failoverEligible before the core sees it. Evidence: phase4-coordinator/internal/buyer/server.go:1314, phase4-coordinator/internal/buyer/server.go:1324, phase4-coordinator/internal/buyer/forward_loop_test.go:330, phase4-coordinator/internal/buyer/forward_loop_test.go:418, phase4-coordinator/internal/buyer/forward_loop_test.go:549, phase4-coordinator/internal/buyer/forward_loop_test.go:616.
  - HTTP 200 success is rendered entirely inside dispatch and returns ok=false, so the core success branch cannot double-render; cancelAttempt is called before return. Evidence: phase4-coordinator/internal/buyer/server.go:1606, phase4-coordinator/internal/buyer/server.go:1632, phase4-coordinator/internal/buyer/server.go:1636, phase4-coordinator/internal/buyer/forward_with_failover.go:68.
  - HTTP receipt-bearing null-usage early-return calls shouldRetry only in dispatch and returns ok=false on terminal handling; if retry continues, the core later consults shouldRetry once for the classified attempt. Evidence: phase4-coordinator/internal/buyer/server.go:1651, phase4-coordinator/internal/buyer/server.go:1668, phase4-coordinator/internal/buyer/server.go:1673, phase4-coordinator/internal/buyer/forward_with_failover.go:163.
  - The core is the only failover-hit state.provider mutator; callbacks log but do not also assign state.provider. Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:134, phase4-coordinator/internal/buyer/forward_with_failover.go:136, phase4-coordinator/internal/buyer/server.go:1353, phase4-coordinator/internal/buyer/server.go:1466.
  - failoverAttempted is per forwardWithFailover invocation and only flips false -> true after a hit. Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:62, phase4-coordinator/internal/buyer/forward_with_failover.go:135.
  - The failed route is added to excluded before failoverCandidate/advance, matching the preserved streaming/WS ordering and the HTTP entry excluded seeding. Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:114, phase4-coordinator/internal/buyer/forward_with_failover.go:132, phase4-coordinator/internal/buyer/server.go:1243, phase4-coordinator/internal/buyer/server.go:1247.

FORWARD_LOOP SCENARIOS:
  1. TestM2_1C_RowSequence_HTTPSuccessFirstAttempt: HTTP dispatch handles 200 success inline. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:54, phase4-coordinator/internal/buyer/server.go:1606.
  2. TestM2_1C_RowSequence_HTTPRetryToSuccess: HTTP shouldRetry + logProviderRow + advance. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:100, phase4-coordinator/internal/buyer/server.go:1711.
  3. TestM2_1C_RowSequence_StreamingCommittedSingleRow: streaming renderCommitted early return. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:169, phase4-coordinator/internal/buyer/server.go:1333.
  4. TestM2_1C_RowSequence_WSNonStreamingFailoverDoesNotBumpRetried: WS-non-streaming failover hit and afterFailoverHit fallthrough. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:240, phase4-coordinator/internal/buyer/server.go:1466.
  5. TestM92_RowSequence_HTTPStreamingZeroBodyTriggersFailover: non-WS streaming pre-chunk disconnect advances to success. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:330, phase4-coordinator/internal/buyer/server.go:1324.
  6. TestM92_RowSequence_HTTPStreamingOneBytePartialTriggersFailover: non-WS streaming invalid pre-commit byte advances to success. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:418, phase4-coordinator/internal/buyer/server.go:1324.
  7. TestM92_RowSequence_HTTPStreamingSlowFirstEventCommits: valid first event commits with one 200 row. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:495, phase4-coordinator/internal/buyer/server.go:1333.
  8. TestM92_RowSequence_HTTPStreamingCommentOnlyTriggersFailover: comment-only pre-commit advances to success. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:549, phase4-coordinator/internal/buyer/server.go:1324.
  9. TestM92_RowSequence_HTTPStreamingDoneOnlyTriggersFailover: DONE-only pre-commit advances to success. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:616, phase4-coordinator/internal/buyer/server.go:1324.
  10. TestM92_RowSequence_HTTPStreamingUsageOnlyFirstChunkCommits: usage-only first chunk commits with one 200 row. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:685, phase4-coordinator/internal/buyer/server.go:1333.
  11. TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance: WS-non-streaming queue-full skips shouldRetry and advances. Evidence: phase4-coordinator/internal/buyer/forward_loop_test.go:755, phase4-coordinator/internal/buyer/server.go:1482.

VALIDATION:
  - go test ./internal/buyer -run 'TestM2_1C_RowSequence|TestM92_RowSequence|TestM2_1D_RowSequence' -count=1: PASS
  - go test ./internal/buyer -race -count=5: PASS

VERDICT: code lane READY TO MERGE
