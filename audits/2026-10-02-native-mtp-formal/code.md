METHOD CONSTRAINT: First-party software-correctness / proof review. Do NOT author or construct malformed payloads or exploit inputs; evaluate by reading source and running EXISTING tests; describe gaps abstractly (field + condition) in prose.

LANE: CODE REVIEW (correctness, regressions, test adequacy).

Repository: /Users/augstar/macprovider-mtp-formal-audit (a detached worktree of branch campaign/native-mtp-formal, based on origin/main b29b7b8f5, which merged PR #1820). This is the freeze audit for the #1770 native-MTP formal campaign: formal (non-exploratory) SPEC-048-R015 evidence and the unsigned SPEC-023-R024 sidecar / JOURNEY-NATIVE-MTP-SERVING inputs for the first native-MTP tuple (Qwen3.6-35B-A3B 4-bit + MTP-4bit drafter, qualified_slots 8, max_native_active_rows 1, max_prompt_tokens 4096, sampled request profile, M3 Ultra 256 GB Studio).

SCOPE: the COMPLETE diff `git diff origin/main...HEAD` (list commits with `git log --oneline origin/main..HEAD`). Main surfaces:
- specs/SPEC-048-native-mtp-serving.md 0.1.21 (MTP-15 mandatory matrix right-sized: native-eligible cells slots 1..bound x prompts {1536,4096} capped by the signed max_prompt_tokens incl. the cap, outputs {128,512}; gated cells at bound+1 and qualified_slots p1536 o512 staggered; 1800 s sustained window at s<qualified_slots>-p1536-o512 as a separate bench phase reusing that cell's matrix records; strata counted on the served/templated prompt; MTP-4/MTP-7/MTP-13 edits) and specs/SPEC-023-installer-autotune-recommend.md v0.22.6 (R024 entry gains required max_prompt_tokens, part of native_mtp_admission_tuple_sha256).
- phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift (max_prompt_tokens parsed into the release-envelope capability; previously hardcoded 1048576).
- phase3-binary/Sources/macprovider-cli/ModelRuntime.swift (records a token-bound native->ordinary reselection in status and admission observers; lab-only proposal-override installer and token probe).
- phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift (lab-only NativeMTPLabProposalOverride, compiled only under DEBUG || MACPROVIDER_LAB_HARNESS).
- phase3-binary/Sources/macprovider-cli/NativeMTPBenchCommand.swift (policy gated_cells / maximum_prompt_tokens, exact matrix validation, --phase all|matrix|sustained, served-prompt strata realization, prompt_corpus v2) and NativeMTPJourneyE2ECommand.swift (new lab-only journey hardware harness), NativeMTPHardwareE2ECommand.swift, MacProviderCLI.swift.
- scripts/native_mtp_r015_analyze.py (exact matrix rules, duplicate cells, sustained memory check only on recorded sustained runs) and scripts/native_mtp_admission_sidecar.py (new unsigned R024 sidecar generator; never reads keys) with tests and a cross-language golden fixture.
- docs/research/spec048-r015/** (template, README, frozen policies, sanitized analyses, superseded first freeze), journeys/evidence or docs evidence drafts, specs/CONFORMANCE.json, specs/README.md.

Read first: specs/SPEC-048-native-mtp-serving.md (MTP-4, MTP-7 load gate, MTP-13, MTP-14, MTP-15 incl. "Run order", "Mandatory matrix", "Cell classes", changelog 0.1.21), specs/SPEC-023-installer-autotune-recommend.md §12.5 R024 (changelog v0.22.6), journeys/JOURNEY-NATIVE-MTP-SERVING.md.

Local verification at HEAD: `cd phase3-binary && swift test --filter 'NativeMTP|ModelRuntimeSwap|ContinuousBatchScheduler|PagedKV|ModelRuntime'` 0 failures; plain `swift build -c release` registers no lab command; `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_native_mtp_r015_analyze scripts.tests.test_native_mtp_lab_flag_guard scripts.tests.test_native_mtp_admission_sidecar` OK; gen_spec_index --check and check_spec_governance pass. You may re-run the Python suites. Do NOT modify any file in the repository.

Out of scope (do not report): signing keys or how the operator stores them; the live coordinator; release cutting.

Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a concrete failure scenario described in prose, and a fix; say whether each is new in this diff or pre-existing. Be adversarial but do not report style nits as MEDIUM or above. End with a single final line exactly: `VERDICT: <n> CRITICAL, <n> HIGH, <n> MEDIUM, <n> LOW`.

Focus for this lane:
- Swift bench validateMatrix vs Python analyzer _matrix_violations: identical acceptance of the mandatory matrix (slots exactly 1..bound, capped prompt strata incl. cap, outputs, exact gated_cells, sustained_cell_id, sustained_seconds >= 1800, staggered arrivals, duplicate cells); any policy one accepts and the other rejects.
- --phase sustained: refusal/resume logic in NativeMTPBenchRunner.run and NativeMTPExistingEvidence; can a sustained phase re-run, skip, or double-count matrix blocks, or append under a different policy digest; alternating order preserved across a resumed window.
- Served-prompt strata realization (makePrompts): termination, ±2% bounds, cap handling, determinism across ordinary/native paths of a block.
- ModelRuntime.recordNativeMTPTokenBoundDowngrade: double-counting of status reasons, observer semantics, any production behavior change beyond recording.
- Analyzer sustained memory check change: can a required sustained window now pass without being judged.
- NativeMTPJourneyE2ECommand: any check that passes vacuously (e.g. empty comparisons, wrong request id, last-admission lookups), or steps reported pass without exercising the claimed behavior.
- scripts/native_mtp_admission_sidecar.py vs the Swift R024 consumer: field set, ranges, canonical bytes, tuple identity.
