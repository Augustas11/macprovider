# BUILD_SPEC — RESEARCH_233 KV survival across provider restarts → SPEC + IMPL to full

You are a senior protocol/systems engineer on the macprovider repo (P2P Mac LLM
inference marketplace). Drive RESEARCH_233's landed decision from memo to a
merged, LOCK-ready normative SPEC **and** its implementation. Work autonomously
to completion; never end on a "proceed or hold" — default is full scope in
priority order. Make design calls, record them, keep going.

## 0. What you are building (self-contained)

**Goal:** a provider-local cold KV tier that survives deploy / crash / supervisor
relaunch / reboot re-prefill, cutting the buyer-TTFT restart tail. Pure
provider-local performance optimization — **no buyer-visible change, no receipt
change.**

**Source of truth:** `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md`
(landed, commit `d6881b14`). Read it fully first. The decision is made — do not
re-open it; implement it.

**Chosen approach — Approach A:** an **encrypted, provider-namespaced disk tier
behind the existing `ConversationCache`**, using versioned append-only blocks,
atomic manifests, strict metadata validation, and bounded streaming promotion
into the current RAM cache. Fallback is **Approach C** (upstream portable
`mlx-swift-lm` save/load wrapped in the same policy envelope) only if A fails its
gate. Explicitly rejected: external sidecar, global cross-tenant dedup, plaintext
token replay as production cache, oMLX as inference engine.

### Hard constraints the SPEC and IMPL MUST honor (from the memo)

1. **Preserve hot-cache semantics exactly.** `conversation_key` selects one
   candidate; token-level LCP determines reusable prefix; **every layer trims
   exactly to the LCP**; the incoming request still reports its full prompt
   length; speculative decoding stays outside this cache path. (Brownfield proof:
   commit `84e50c92` validated exact-LCP + `KVCache.trim()` and exposed the
   tokenizer / token-accounting / `cache_offset` traps — preserve them.)
2. **Safety envelope stricter than local single-user tools.** A hit requires exact
   match on: `model_sha256`, model/catalog revision, tokenizer/template identity,
   `kvBits`, quantization metadata, cache class/layout, ABI compatibility. Any
   ambiguity, corruption, expiry, or incomplete write = **miss** (fail safe to
   re-prefill), never a wrong reuse.
3. **Cross-account isolation is security-critical.** Isolation rests on SPEC-024
   FR-CI5/CI6's account-scoped unforgeable `conv:` key. Persistence widens the
   blast radius from one process lifetime to restarts + peer processes and turns
   the global-capacity channel into a possible cross-process DoS vector — so disk
   **namespaces and quotas MUST be per provider**.
4. **Purge primitive is a ship-blocker.** Do **not** ship the disk tier until a
   provider-side conversation-key purge primitive exists. `DELETE /v1/sticky`
   today removes only coordinator state; a restart-durable provider entry would
   otherwise be buyer-unpurgeable. Spec + build this purge path.
5. **No receipt/billing change.** Introduces no new receipt field; must not change
   LOCKED SPEC-015 v0.4.2 receipts; does not change cache eligibility, billing, or
   buyer-visible semantics — it changes **residency only**. Buyer-facing cache
   binding, if ever needed, is a named future SPEC-015 v0.5 question, out of scope.
6. **Keep the first disk format independent of RESEARCH_232's future paged-KV
   allocator.** Serialize the current per-conversation layer state opaquely.
7. **Stop condition (KVS-01 gate).** If Approach A cannot approach the in-RAM warm
   baseline **without** replacing the current KV layout with a shared paged
   allocator, PAUSE Approach A and escalate the Approach C / RESEARCH_232 layout
   sequencing decision (record it) before more persistence engineering.

## 1. House rules — non-negotiable

- **Fresh worktree off `origin/main`** (`git worktree add ../macprovider-233 -b spec/233-kv-survival origin/main`); never edit the canonical checkout.
- **Number reservation:** claim **SPEC-037** for this spec (SPEC-036 is in flight
  in a parallel session; SPEC-038 is reserved for RESEARCH_232, running in
  parallel — do NOT take it). Verify at runtime (`ls specs/SPEC-*.md`) and bump to
  the next free number only if 037 is already taken; if you must bump, avoid the
  232 session's number.
- **Sensitive path → PR, not direct push.** This touches SPEC-024 billing/cache
  isolation and cross-account security; treat as sensitive. Full **three-lane
  codex audit** (code / security / architect) via `omc ask codex --prompt "$(cat
  <file>)"`, bar **0 C/H/M**, for both the SPEC and the IMPL. Lane prompts go
  under `audits/<YYYY-MM-DD>/` (never `specs/` — CI gate). LOW/INFO ship documented
  in the PR body. Don't re-fire a lane that already returned 0/0/0.
- **Git identity is automatic** (`git push` routes to `Augustas11`). Merge pattern:
  `antfleet-ops` approves → `Augustas11` squash-merges
  (`GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge --squash`). Re-approve if a
  post-approval push dismisses the approval. The auto-mode classifier may block
  review/merge — surface the exact commands for the user to run if so.
- **Governance:** spec-bearing PRs need a `SPEC-GOVERNANCE-DECLARATION`
  (`spec-pr-governance-v1`) validating against `specs/CONFORMANCE.json` /
  `specs/AUTHORITY.json`. Body edits don't re-trigger `check` — close+reopen or
  push. Verify the latest run per context (`group_by(.name)|map(sort_by(.started)|last)`).
- **Decision log:** append an entry to `beta/DECISION_CRITERIA.md` (latest is 180
  → yours is next free), merged **last**, reflecting shipped state.
- **No GitHub issues from audit findings.** Verify commit content (`git show
  --stat HEAD` + grep load-bearing lines) before push. Backtick-heavy prompts →
  write to file and `cat`, never inline double-quoted.

## 1b. Parallelism / collision (SPEC-036 and SPEC-038 run alongside you)

- **SPEC-036** (compute-integrity) is Go coordinator code — no file overlap with
  you. Ignore it except for the shared manifests below.
- **SPEC-038** (RESEARCH_232 continuous batching) edits the **same provider files
  you do** — `phase3-binary/.../ModelRuntime.swift` and the KV-cache classes. The
  two SPECs are architecturally independent (no shared paged allocator), but the
  provider IMPL is **not** conflict-free. **You (037) land the provider IMPL
  first**; 038 rebases onto your merged changes. Serialize the *current* opaque
  per-conversation KV layout — do not introduce a batch-aware/paged layout (that is
  038's job, and your KVS-01 stop-condition fires if persistence needs it).
- **Shared files across all three** — `specs/CONFORMANCE.json`,
  `specs/AUTHORITY.json`, `beta/DECISION_CRITERIA.md`: additive edits. Rebase on
  latest `origin/main` before each PR and re-add your entries; keep the
  decision-log entry for a final PR that merges last.

## 2. Phases

- **A — SPEC.** Write `specs/SPEC-037-kv-survival-restart.md` (house style
  `SPEC-NNN-*.md`) as the normative Approach-A design: the disk-tier format
  (versioned append-only blocks + atomic manifest), the strict metadata/safety
  envelope (constraint 2), per-provider namespace + quota model (constraint 3),
  the purge primitive (constraint 4), the LCP/trim/no-receipt invariants
  (constraints 1 + 5), format-independence from paged-KV (constraint 6), and the
  KVS-01 benchmark gate + stop condition (constraint 7). Include Acceptance
  Criteria (fixtures) and an explicit "not-a-hit" table.
- **B — SPEC audit loop** to 0 C/H/M (3 lanes); open + merge the SPEC PR through
  the governance gate.
- **C — IMPL.** Build the disk tier behind `ConversationCache` in the provider
  binary (`phase3-binary/`), the per-provider namespace/quota, the encryption at
  rest, the strict-validation load path (fail-safe to miss), the streaming
  promotion into RAM, and the provider-side purge primitive. Add the KVS-01
  benchmark harness and the acceptance-criteria tests. Build + test green.
- **D — BUILD audit loop** to 0 C/H/M (3 lanes; security lane weighted on
  cross-account isolation, fail-safe-on-corruption, quota DoS, and
  no-receipt-drift). Open + merge the IMPL PR.
- **E — Decision-log entry** merged last; close-out report to the user with links,
  audit convergence, the KVS-01 result vs the in-RAM warm baseline, and any carried
  residuals. No open loops.

## 3. Definition of done
- [ ] SPEC-037 written (Approach A), all 7 constraints normative, KVS-01 gate + stop condition specified; SPEC audit 0 C/H/M; SPEC PR merged via governance gate.
- [ ] IMPL: encrypted per-provider disk tier behind `ConversationCache`, strict-validation fail-safe load, streaming promotion, **provider-side purge primitive**, KVS-01 harness + acceptance tests; build/test green.
- [ ] No new SPEC-015 v0.4.2 receipt field; hot-cache LCP/trim/full-prompt-length semantics unchanged; spec-decode path untouched.
- [ ] Cross-account isolation preserved (SPEC-024 FR-CI5/CI6); per-provider namespace + quota enforced; corruption/expiry/incomplete-write all resolve to miss.
- [ ] KVS-01 measured vs in-RAM warm baseline; if the stop condition trips, Approach A paused + 232/paged-KV sequencing decision recorded instead.
- [ ] BUILD audit 0 C/H/M; IMPL PR merged; decision-log entry merged last; worktree/branch cleaned; user briefed.
