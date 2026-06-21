# Implementation BUILD prompt — SPEC-014 Phase 1C (Earn + Monitoring placeholder + Identity + sidebar polish + build-time grep guard)

Operator-paste prompt for Codex GPT-5 to land the **third and final**
implementation sub-phase of SPEC-014 v0.8. Phase 1C extends the
single-file bundle with Surfaces C / D / E, finalizes sidebar
polish (sign-out / external API Docs / mobile collapse), and adds
the build-time grep guard `check-bundle.sh` that AC 8(b) + 8(f)
require to be wired into CI before merge.

**Prerequisite:** Phase 1B merged to `main`. Branch off `main` into
`feat/spec-014-portal-phase-1c`. The bundle at
`frontdoor/provider-portal/index.html` already contains AUTH-3 +
sign-in + AUTH-2 + Surface A (Phase 1A) and Surface B (Phase 1B).
Phase 1C replaces the C/D/E stubs with real surfaces and adds one
new file.

**Scope: SPEC-014 §11 Phase 1C only.** Concretely:
- §4.3 Surface C (Earn): C.1 credit totals row (3 cards) +
  C.2 payout-ready status card. C.3 / C.4 NOT rendered.
- §4.4 Surface D (Monitoring): single placeholder card with three
  bullets. **ZERO network requests** (binding AC).
- §4.5 Surface E (Identity): read-only identity card with
  provider_id / tier / state / coordinator base URL only. NO
  hardware / runtime fields. NO rotation, NO removal, NO
  notification toggles.
- §3 sidebar polish: sign-out clears in-memory session and stops
  pollers; "API Docs" link to `https://api.streamvc.live/docs`
  with `target="_blank" rel="noopener noreferrer"`; mobile (<720
  px) hamburger / hide behavior already from Phase 1A, verified.
- NEW `frontdoor/provider-portal/check-bundle.sh` — build-time
  grep guard for AC 8(b) (operator-keyed routes) + AC 8(f)
  (single-machine copy hygiene). Exits non-zero on any match.

OUT OF SCOPE for Phase 1C: any v0.2 feature (Surface D real
sub-cards, C.3/C.4 earnings breakdown, identity rotation /
removal, etc.). v0.2 reopens AFTER the Open Qs land their owning-
spec amendments.

**One-line summary.** Wire the final three surfaces (C/D/E) into the
existing bundle, polish the sidebar's sign-out / API-Docs / mobile
behavior, add `check-bundle.sh` as the AC 8(b) + 8(f) build-time
grep guard, and update the README + a CI hook (if the repo has one
under `frontdoor/`).

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-014 v0.8 (§3 sidebar + topology, §4.3 Surface C, §4.4
  Surface D, §4.5 Surface E, §5.1 table (a) C.1/E.1 rows, §5.2
  table (b) C.2/D/E.1 rows, §5.3 table (c) C.3/C.4/D.1/D.2/D.3/
  E.1-deferrals/E-notifications, §7 non-goals, §8(a) C/D/E ACs,
  §8(b) operator-key isolation, §8(d) privacy ACs, §8(e)
  Q3/Q4/Q5/Q6/Q11 ACs, §8(f) single-machine ACs).
- SPEC-005 v0.3 (§11.4 earnings JSON shape — already used in
  Phase 1A's A.2 row; C.1 reuses the same `state.earn.data`).
- SPEC-002 v1.3.5 (§7.4 `/v1/pool/check` — E.1 reuses the same
  `state.pool.data`).

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~45-75 min
(append ~150-250 lines to `index.html`; one new ~50-line shell
script).

Branch: `feat/spec-014-portal-phase-1c` (operator creates + checks
out before pasting). Codex MUST NOT create a new branch.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1C of SPEC-014 v0.8 in the single-file
web bundle at /Users/augstar/macprovider-poc/frontdoor/provider-portal/.
SPEC-014 v0.8 is LOCKED. Phases 1A and 1B are on `main` (read
their commits to understand the existing bundle before you start).

You will create/edit ONLY these files:

  frontdoor/provider-portal/index.html      (extend)
  frontdoor/provider-portal/check-bundle.sh (NEW, executable)
  frontdoor/provider-portal/README.md       (extend)

You will NOT edit any other file. Verify with
`git diff specs/ phase3-binary/ phase4-coordinator/ phase5-gateway/
frontdoor/console/` — must be empty before you finish.

## Critical constraints

**1. Keep all Phase 1A + 1B guarantees intact.** Re-read the
constraint sections of `specs/BUILD_SPEC_014_IMPL_PHASE_1A_PROMPT.md`
and `specs/BUILD_SPEC_014_IMPL_PHASE_1B_PROMPT.md`. Every one of
them still binds.

**2. Surface C — Earn (§4.3).**

  - **C.1 credit totals row (3 cards)** — same source as
    Phase 1A's A.2 (`/providers/{id}/earnings`). Reuse the
    existing `state.earn.data` and `earnFetch()`. Render in a
    `<div class="row row-3">`:
    - "Lifetime credits" ← `total_credits` (integer; en-US
      thousands separator OK).
    - "Current window" ← `current_window_credits` (integer).
    - "Last payout-ready window" ← `last_payout_ready.
      provider_credits` (integer) PLUS `window_start_utc` /
      `window_end_utc` in the card footer.
    - NO fiat conversion. NO "$" symbol. NO "withdrawable
      balance" label.
  - **C.2 payout-ready status card (single card)**. The card
    title is "Fiat payout rail". The body MUST be the LITERAL
    text `"Fiat payout rail not yet specified — future spec."`
    with a one-line footnote citing SPEC-005 §1.3 / §2.1 D1
    and Open Q3.
    The card MUST NOT include:
    - any country selector
    - any "Link bank via Stripe" button (or any Stripe
      reference at all)
    - any account-type picker
    - any "withdraw now" / "payout now" CTA
    - any USD / EUR / fiat amount
  - **C.3 + C.4 NOT RENDERED** — both deferred (§4.3 + §5
    table (c) + Open Q4).
  - On mount of `route === "earn"`, call `earnFetch()` to warm
    the cache (same as `route === "machine"`).
  - On 401/403/404 the surface follows AUTH-2 + the stale-config
    guard already wired in Phase 1A.

**3. Surface D — Monitoring (§4.4).**

  - Render ONE single placeholder card titled
    `"Monitoring — coming after SPEC-002 amendment"` with three
    static bullets:
    - "Uptime history (24 h / 7 d / 30 d) — needs Open Q5
       (SPEC-002 amendment)."
    - "Current routing weight — needs Open Q5 (SPEC-002
       amendment)."
    - "Live request tail — needs Open Q5 AND a privacy-
       redaction policy decision (which fields a provider may
       see; what redaction applies to buyer prompts, completions,
       identity, API keys, and IPs)."
  - **ZERO network requests** on this surface (AC 8(a) +
    §4.4). Mounting the route MUST NOT trigger any fetch. The
    background pollers from Phase 1A (`poolCheck`, `earnFetch`)
    continue to tick — that's expected; "zero network requests"
    means the Monitoring SURFACE specifically issues none. To
    make this verifiable, do NOT call `earnFetch()` /
    `poolCheck()` / `releasesFetch()` from inside
    `renderMonitoring()` and do NOT have the renderer mount any
    `<img>` / `<iframe>` / `<link>` with a remote URL.
  - The card body MUST cite SPEC-014 §4.4 as the source of the
    rendered text.

**4. Surface E — Identity (§4.5).**

  - Render ONE card with EXACTLY these four fields in a
    label/value grid:
    - `provider_id` ← pasted session value (mono font; do NOT
      call `/v1/pool/check` for it).
    - Tier ← `state.pool.data.tier` if present, else `"—"`,
      rendered as a small pill.
    - State ← `state.pool.data.state` if present, else `"—"`
      (mono font).
    - Coordinator base URL ← `state.cfg.coordinator_base_url`
      (mono font).
  - The card MUST include a footer line noting that hardware /
    runtime fields (model, RAM, capacity, binary_version,
    attestation, endpoint_url, …) are DEFERRED behind Open Q5.
  - The card MUST NOT include:
    - any "rotate token" button
    - any "remove this machine" button
    - any notification opt-in toggle (email / Slack / push / SMS)
    - any hostname / model_id / model_params_b / ram_gb /
      max_context_tokens / max_concurrency /
      throughput_tps_estimate / binary_version / attestation /
      endpoint_url field
  - Mounting the route does NOT issue any new fetch; it reads
    `state.pool.data` lazily (the pool poller is already running
    from Phase 1A).

**5. Sidebar polish (§3).**

  - The sidebar already exists from Phase 1A; verify the
    following are wired:
    - "Sign out" footer button: stops `poolTimer`, `earnTimer`,
      `stampTimer`; clears `state.session`, `state.pool`,
      `state.earn`, `state.releases` (this last one prevents
      cross-session leakage of cached release data), and
      `state.authFailBySurface`; sets `state.route = "machine"`;
      re-renders to the sign-in screen.
    - "API Docs" footer link: `href="https://api.streamvc.live/docs"`,
      `target="_blank"`, `rel="noopener noreferrer"` (the rel
      attribute is mandatory to prevent reverse-tabnabbing).
    - Mobile (<720 px) hamburger: tapping it toggles
      `state.sidebarOpen`; tapping the scrim closes it; tapping
      a nav item closes it.
  - If any of those are missing or incorrect, add/correct them
    in this phase.

**6. NEW `frontdoor/provider-portal/check-bundle.sh`**

  - Executable (`chmod +x`).
  - Bash with `set -euo pipefail`.
  - Run from anywhere; resolves its own dir via `BASH_SOURCE[0]`.
  - Greps the rendered bundle (`frontdoor/provider-portal/index.html`)
    for prohibited strings. Exits non-zero on any match.
  - Patterns checked:
    - AC 8(b) operator-keyed routes:
      `/poolz`, `/admin/blacklist`, `/admin/provisional`,
      `/admin/promote`, `/admin/reject`, `/admin/ledger`.
      (Concatenate these literals INSIDE the script so the
      script's own source does NOT match itself — e.g.
      `"/po""olz"`. This is how the project's other guard
      scripts avoid self-matching.)
    - AC 8(b) operator-key reference: case-insensitive
      `operator[_-]?key`.
    - AC 8(f) single-machine copy hygiene: case-insensitive
      `"your fleet"`, `"your machines"`, `"across machines"`,
      `"all machines"`, `"N machines"`, `"N/M"`, `"x3"`,
      `"machine grid"`.
  - Prints `check-bundle: OK` on clean exit.
  - Prints `FAIL [8(b)]: ...` / `FAIL [8(f)]: ...` per match.
  - Exit codes: 0 clean, 1 found prohibited strings, 2
    `index.html` missing.

**7. README extension.** Update the bundle README to:
  - Note Phase 1C is now landed.
  - Document `check-bundle.sh` and call out that CI MUST run
    it before serving the file.
  - Document the deploy steps:
    1. Copy `portal-config.json.example` → `portal-config.json`
       and edit.
    2. Host alongside an operator-owned reverse proxy on the
       same origin that forwards `/v1/pool/check` and
       `/providers/{id}/earnings` to the coordinator (§3 +
       Open Q9).
    3. Run `./check-bundle.sh` in CI.

**8. Privacy ACs (§8(d)).** Verify the bundle ONLY displays
fields from upstream endpoints that are provider-owned:
  - `provider_id` (path subject; provider-owned identity).
  - `tier` (provider's pool tier).
  - `state` (provider's pool state).
  - `total_credits`, `current_window_credits`,
    `last_payout_ready.*` (provider's earnings rollups; no
    per-request data; no buyer attribution).
  - GitHub Releases `tag_name` / `published_at` / `body` (public
    artifact; no buyer data).

The bundle MUST NOT render any buyer field (buyer `request_id`,
buyer account id, buyer prompt text, buyer completion text,
buyer IP, buyer API key). This is binding for ALL phases but
explicitly re-checked in Phase 1C.

**9. Re-confirm grep cleanliness AFTER your edit, then run
`check-bundle.sh` as the final guard.** Both MUST be clean.

## Required reading (in this order — read fully before writing)

1. The current `frontdoor/provider-portal/index.html` (Phases 1A
   + 1B). Understand the existing `state` shape, `earnFetch()`,
   `poolCheck()`, `renderShell()` / nav switch.

2. `/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md`
   §3 (sidebar + mobile), §4.3 (Surface C), §4.4 (Surface D),
   §4.5 (Surface E), §5.1 table (a) C.1 + E.1 rows, §5.2 table
   (b) C.2 + D + E.1 rows, §5.3 table (c) — every row in (c)
   maps a UI element that MUST NOT be rendered, §7 non-goals,
   §8(a) C/D/E ACs, §8(b), §8(d), §8(e Q3/Q4/Q5/Q6/Q11), §8(f).

3. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md`
   §1.3 + §2.1 D1 (fiat / Stripe out of scope) — drives C.2 copy.

4. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

5. (Optional model) any existing repo script under `dist/`,
   `tools/`, or `phase4-coordinator/scripts/` whose style you
   want to mirror for `check-bundle.sh`.

## Required edits — exact shape

### A. `frontdoor/provider-portal/index.html` — extend

- Replace `renderStub("...")` (or the equivalent placeholder)
  for routes `earn`, `monitor`, `identity` with three real
  renderers: `renderEarn()`, `renderMonitoring()`,
  `renderIdentity()`.
- Verify / add the sidebar "Sign out" behavior per constraint 5.
- Verify / add the "API Docs" link per constraint 5.
- The mobile breakpoint CSS + `state.sidebarOpen` plumbing
  already exists from Phase 1A; do NOT regress it.
- DO NOT add any new fetch helper; C.1 reuses `earnFetch()`,
  E.1 reuses `poolCheck()`'s data, D issues nothing.

### B. `frontdoor/provider-portal/check-bundle.sh` — NEW

Sketch:

```bash
#!/usr/bin/env bash
# SPEC-014 §8(b) + §8(f) build-time grep guard.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$HERE/index.html"

if [[ ! -f "$BUNDLE" ]]; then
  echo "check-bundle: $BUNDLE not found" >&2
  exit 2
fi

fail=0

op_routes=(
  "/po""olz"
  "/adm""in/blacklist"
  "/adm""in/provisional"
  "/adm""in/promote"
  "/adm""in/reject"
  "/adm""in/ledger"
)
for p in "${op_routes[@]}"; do
  if grep -Fq "$p" "$BUNDLE"; then
    echo "FAIL [8(b)]: bundle references operator-keyed route: $p" >&2
    fail=1
  fi
done

multi_machine=(
  "your fleet"
  "your machines"
  "across machines"
  "all machines"
  "N machines"
  "N/M"
  "x3"
  "machine grid"
)
for p in "${multi_machine[@]}"; do
  if grep -Fiq "$p" "$BUNDLE"; then
    echo "FAIL [8(f)]: bundle contains prohibited multi-machine string: $p" >&2
    fail=1
  fi
done

if grep -Eiq "operator[_-]?key" "$BUNDLE"; then
  echo "FAIL [8(b)]: bundle references operator_key — the portal must never prompt for or transmit it" >&2
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "check-bundle: OK"
fi
exit $fail
```

`chmod +x frontdoor/provider-portal/check-bundle.sh` after writing.

### C. `frontdoor/provider-portal/README.md` — extend

Add (or update if Phase 1B added a draft) a section enumerating:
- the file inventory (index.html, portal-config.json.example,
  check-bundle.sh, README.md)
- the deploy steps (copy + edit config, host with reverse proxy,
  run check-bundle.sh)
- the auth model summary (AUTH-1 paste, in-memory only;
  AUTH-2 bearer + path subject; AUTH-3 fail-CLOSED loader)

## Done criteria

You are done when:

- `git status --porcelain frontdoor/provider-portal/` lists only
  `index.html`, `check-bundle.sh` (new), and `README.md`
  modified.
- `git diff specs/ phase3-binary/ phase4-coordinator/
  phase5-gateway/ frontdoor/console/` is empty.
- `./frontdoor/provider-portal/check-bundle.sh` prints
  `check-bundle: OK` and exits 0.
- Manual smoke (with `python3 -m http.server 8788 --directory
  frontdoor/provider-portal` + dev fixture `portal-config.json`):
  - Sign in → navigate to Earn → see 3 credit cards + the
    fiat-not-specified card. Confirm DevTools network shows ONE
    earnings call (cache reuse from Phase 1A is fine; no
    duplicate).
  - Navigate to Monitoring → see the placeholder card with three
    bullets. Confirm DevTools network shows NO new requests
    triggered by this navigation (background pool/earn pollers
    may continue, that's expected).
  - Navigate to Identity → see the read-only identity card with
    `provider_id` / tier / state / coordinator base URL. Confirm
    no new fetch.
  - Click "Sign out" → returns to sign-in screen; in-memory
    session cleared (typing the same credentials again shows
    fresh state).
  - Resize browser <720 px wide → sidebar hides; hamburger
    appears; tapping it opens the sidebar over a scrim.
- Re-confirm Phase-1A + 1B grep checks all return ZERO matches:
  - browser-storage: 0
  - operator-keyed routes / operator_key: 0
  - multi-machine copy: 0
  - autotune banner / fiat UX: 0
  - `Access-Control-Allow-Origin`: 0
- The page parses with no `console.error` on first paint in any
  of the five surfaces.

## Out of scope (do NOT do these in Phase 1C — they are v0.2)

- Surface D real sub-cards (D.1 uptime, D.2 routing weight,
  D.3 request tail) — DEFERRED (Open Q5 + privacy policy).
- Surface C earnings breakdown (C.3 day/week/month bucketing,
  per-model decomposition, per-job feed) — DEFERRED (Open Q4).
- Surface E rotation / removal — DEFERRED (Open Q6).
- Notification opt-in toggles of any channel — DEFERRED (Open
  Q11).
- A.1 update pill / heartbeat-current label / hardware fields —
  DEFERRED (Open Q5).
- A.3 update-available row / self-signed binary row / model-
  load-failed row — DEFERRED (Open Q5 + Q10).
- Any CI workflow file under `.github/workflows/` — that is an
  operator step; the build prompt's responsibility ends with
  the script + README documentation.

## Self-check before reporting done

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat specs/ phase3-binary/ phase4-coordinator/ phase5-gateway/ frontdoor/console/ && \
  echo "----" && \
  git status --porcelain frontdoor/provider-portal/ && \
  echo "----" && \
  ./frontdoor/provider-portal/check-bundle.sh && \
  echo "----" && \
  grep -En 'localStorage|sessionStorage|document\.cookie|window\.indexedDB|indexedDB' frontdoor/provider-portal/index.html || echo "OK: no browser-storage" && \
  echo "----" && \
  grep -iE 'your latest autotune|autotune result|tuning complete|withdrawable|withdraw now|link bank|stripe' frontdoor/provider-portal/index.html || echo "OK: no autotune banner / no fiat UX" && \
  echo "----" && \
  grep -E 'Access-Control-Allow-Origin' frontdoor/provider-portal/index.html || echo "OK: ACAO never read"
```

Return:
- A brief diff summary (lines added/removed in `index.html`;
  new file size for `check-bundle.sh`).
- Confirmation each self-check returned "OK" or zero.
- Any spec clause you were unable to satisfy exactly, with the
  binding clause number and your interpretation.

Do NOT commit. Do NOT push. The operator audits the working tree
via `omc ask codex` IMPL audit (separate prompt) before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 45-75 min for Codex GPT-5 on a fresh
  context. Phase 1C is a slightly smaller append than Phase 1B.
- After Phase 1C LOCKs (IMPL audit returns 0 CRITICAL / 0 HIGH /
  0 MEDIUM), commit on the feature branch, open the PR, and on
  squash-merge add a `.github/workflows/` (or equivalent CI hook)
  that runs `frontdoor/provider-portal/check-bundle.sh` on PRs
  touching `frontdoor/provider-portal/**`. AC 8(b) + 8(f) call
  for a CI step; without it the guard is not enforced.
- v0.2 reopens after Open Qs land their owning-spec amendments;
  do NOT cascade into v0.2 work from a Phase 1C PR.
