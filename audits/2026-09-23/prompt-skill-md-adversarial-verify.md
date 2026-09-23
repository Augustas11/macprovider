# Adversarial verification: `get.malibu.tech/skill.md`

You are an adversarial verifier. You did not write this skill. Your job is to
find every place where an agent that follows it would fail, be misled, do
something unsafe, or leak internal names. Assume it is wrong until code, a
live endpoint, or an executed command proves otherwise.

Do not edit the skill, the publication scripts, or any production system.
Your output is a report (format at the end).

## What the skill is for

The skill has exactly two goals. Judge every line against them.

- **G1: Onboard a new provider.** A coding agent on a fresh Apple Silicon Mac,
  holding only an invite link, gets the Mac installed, admitted, serving a paid
  catalog model, and verified as serving. It can also check status, recover a
  broken install, update, and uninstall safely.
- **G2: Use the Malibu API from any coding-agent harness.** A coding agent
  (or a human it assists) gets a buyer API key and configures any common
  harness to use Malibu as its model backend, with working model IDs, tool
  calling where supported, and correct expectations about limits.

Anything in the skill that serves neither goal is noise. Anything either goal
needs that the skill lacks is a gap.

## Targets

1. Live skill: `https://get.malibu.tech/skill.md`
2. Live discovery index: `https://get.malibu.tech/.well-known/skills/index.json`
3. Repo source: `docs/agent-onboarding/SKILL.md` and
   `docs/agent-onboarding/.well-known/skills/index.json` on `origin/main`
4. Publication and verification tooling:
   - `scripts/publish-agent-onboarding-skill.sh`
   - `scripts/install-agent-onboarding-publication.sh`
   - `scripts/verify-agent-onboarding-hosted.sh`
   - `scripts/verify-agent-onboarding-skill.py`
   - `scripts/test-agent-onboarding-*.sh`

Save the live files with a UTC timestamp before you start. Everything below
is judged against that snapshot.

## Ground truth (in priority order)

1. **Live behavior:**
   - `https://get.malibu.tech/install.sh` and `uninstall.sh` (read them; do
     not run them outside `--dry-run`)
   - `https://api.malibu.tech/v1/*`. These are public: `rate-card`,
     `stats/overview`, `stats/models`, `status`, `openrouter/models`.
   - For authed probes, read the key with `K=$(cat ~/.config/macprovider/buyer-api-key)`.
     Never print it. Make at most 15 tiny requests, with `max_tokens` ≤ 16,
     using a model that `/v1/status` shows as served.
2. **The stable provider CLI:** resolve the current GitHub Latest release of
   `Augustas11/macprovider` with `gh release list --exclude-pre-releases`. Do
   not assume a version. Read its source at that tag, and read `--help` output
   from its release binary. A CLI claim is true only if it holds for stable
   Latest.
3. **The server side:** `origin/main`, only when it matches the deployed
   runtime. Check the deployed version via the gateway/coordinator `healthz`
   or the operator's read-only host checks. Code that is merged but not
   deployed or default-off is not live.
4. **Public docs:** `https://malibu.tech/docs`. These were refreshed and
   independently claim-checked on 2026-09-23 (MalibuAI/malibu PR #125). Treat
   them as a strong cross-check, not as proof.

Where sources disagree, report the disagreement with evidence from both sides.

## Hard safety limits for you

- Never print secrets: API keys, provider tokens, Keychain values, signing
  keys, env files, or SSH material.
- Never run a real install, `update`, `uninstall`, `recover-update`,
  `autotune --apply`, `models switch`, or credential rotation on this
  machine. You may run:
  - `--help`
  - `--dry-run`
  - `malibu-cli status`/`doctor --offline`, or the canonical
    `macprovider-cli` equivalents, all read-only
  - `curl` of public files
- Do not inspect `d-inference` source.

## Part A: Claim-by-claim verification

For every command, flag, env var, path, URL, header, endpoint, status code,
model ID, config key, version, and behavioral claim in the live skill:

1. **Classify it.** Mark it CORRECT, WRONG, STALE (was true, no longer), or
   UNVERIFIABLE.
2. **Cite evidence.** Give `path:line` at the resolved tag or commit, the
   command and its output, or a live response. Redact secrets.
3. **Check every fenced shell block**, run in its intended context. Does it
   parse (`bash -n`)? Is it safe to copy-paste? Does it quote correctly? Does
   it fail closed? Does it depend on tools a fresh Mac lacks, such as `jq`,
   `gh`, or an Xcode CLT `python3`?
4. **Separate the two naming layers.** Check where the skill uses the user
   command (`malibu-cli`) and where it uses the canonical on-disk name
   (`macprovider-cli`: binary, LaunchAgent, paths). Flag any command that
   fails on a fresh install.

## Part B: Fitness for goal G1 (provider onboarding)

Walk the full journey as a cold agent would, from the skill text alone, and
mark where it succeeds, stalls, or goes wrong.

1. **Prerequisites:**
   - Apple Silicon and minimum macOS
   - RAM tiers and what each tier can earn
   - disk space
   - network
   - the invite requirement: what an invite link looks like and what happens
     without one
2. **Channel choice:** the Malibu.app DMG from `malibu.tech/host`, or the
   `curl` installer. Does the skill tell an agent which one to use, and when?
   Does it cover SSH/headless installs and their Keychain limits?
3. **The install itself:**
   - inspecting the installer before running it
   - signature and checksum verification
   - the invite prompt
   - autotune recommendation
   - donor-mode fallback
   - admission wait
   - rollback on failure
   - exit codes an agent will see, and what each one means
4. **Verifying that it serves:**
   - which status fields prove the Mac is admitted, serving a catalog model
     that is hash-verified against the signed catalog, and routable
   - how to confirm from outside, via public `/v1/stats/models` or `/v1/status`
5. **Operating it:**
   - status and doctor diagnostics
   - log locations
   - restarting the service
   - update and autoupdate behavior
   - recovery (`recover-update` and the repair paths)
   - uninstall, including what it deletes (weights?), what it keeps
     (identity), and headless caveats
6. **Earnings expectations:**
   - pre-beta credits
   - that USDC payouts are currently off
   - no projected-earnings, ROI, yield, or passive-income framing
7. **Failure modes a new provider actually hits:**
   - no paid model fits
   - `waiting_trust` / 429
   - quarantine
   - CLT `python3` stub
   - Gatekeeper
   - Keychain over SSH
   - coordinator restart churn

   Is each one covered, with an action?

For G1, report a stage-by-stage matrix with PASS / GAP / WRONG and one line of
evidence each.

## Part C: Fitness for goal G2 (Malibu API in coding-agent harnesses)

1. **Buyer key:** how to get one (console flow), the key format, where to
   store it, and quota semantics (daily token quota, `429 quota_exhausted`,
   `X-RateLimit-*`).
2. **API contract a harness needs:**
   - base URL: `https://api.malibu.tech/v1`, and the Anthropic facade base
     `https://api.malibu.tech` for `/v1/messages`
   - how to discover served model IDs; flag any model ID in the skill that
     returns 404 today
   - `max_tokens` cap
   - context limits
   - streaming
   - `n=1`
   - `tool_choice` semantics
   - which model families produce `tool_calls`, and multi-turn tool support
   - structured-output subset
   - sticky conversation header and cache pricing
3. **Per-harness setup.** For each harness below, check whether the skill (or
   a doc it links to) gives a working configuration: the exact env vars,
   config file, or flags.
   - Claude Code, via `ANTHROPIC_BASE_URL` and the `/v1/messages` facade.
     Is the facade labeled experimental? Do tool use and streaming work well
     enough for Claude Code? Probe it.
   - Codex CLI (OpenAI-compatible provider config)
   - Cursor (custom OpenAI base URL)
   - Cline
   - Continue
   - Aider
   - OpenCode
   - Pi
   - Zed
   - Goose
   - generic OpenAI SDK (Python/Node)
   - generic Anthropic SDK

   For each, run the smallest real probe you can without installing heavy
   software: a raw HTTP request shaped exactly as that harness sends it,
   covering tools, streaming, and a system prompt. Record pass or fail and
   the error.
4. **Known incompatibilities the skill must warn about:**
   - the stable CLI's 256-message cap
   - tool calls on gpt-oss working only on the first turn
   - non-Qwen models returning plain text with tools
   - rejected JSON-schema keywords (`$ref`/`anyOf`/`pattern`/`format`)
   - receipts missing from streams
   - no buyer pinning

For G2, report a harness × capability matrix. The capabilities are basic
chat, streaming, tools single-turn, tools multi-turn, and long sessions. Mark
each cell WORKS / BROKEN / UNTESTED, with evidence.

## Part D: Cold-agent simulation (required)

Spawn two fresh sub-agents with no repo access and no conversation context.
Give each only the live `skill.md` text and one task:

- **Sub-agent 1:** "Plan, step by step, how you would onboard this fresh
  M-series Mac as a Malibu provider with invite link `<placeholder>`. List
  every command you would run and what you expect to see." Do not let it
  execute anything.
- **Sub-agent 2:** "Configure Claude Code and Cline to use Malibu as the
  model backend. Give the exact config." It may run only the tiny authed
  probes above.

Diff their plans against ground truth. Each point where a sub-agent guessed,
invented a flag or path, stalled, or did something unsafe is a finding
against the skill.

## Part E: Format, publication, and brand integrity

1. **Frontmatter:** does it follow agent-skill conventions? Check `name`, a
   `description` that triggers on the right intents for G1 and G2, a sensible
   size, and progressive disclosure (links, not walls of text).
2. **Discovery index:**
   - Does `sha256` in `index.json` equal the sha256 of the live `skill.md`
     bytes?
   - Does `updated_at` match the file's "Last updated" date?
   - Does `content_type` match the served header?
   - Do the `.well-known` and `malibu.tech/skill.md` aliases redirect
     correctly (308)?
3. **Drift:**
   - diff the live file against repo `docs/agent-onboarding/SKILL.md` on
     `origin/main`
   - say whether the publish script would reproduce the live bytes
   - say whether a CI or cron gate detects drift, or whether a stale
     publication can persist unnoticed
4. **Brand and public-copy boundary.** Malibu is the public product name.
   Flag:
   - "MacProvider" used as a product or skill name (the title, `name`,
     index `name`/`id`)
   - internal hostnames: `coordinator.malibu.tech`, anything under
     `*.streamvc.live`, Pearl
   - internal repo paths (`specs/`, `ops/runbooks/`, `audits/`)
   - SPEC, PR, or issue numbers
   - operator-only procedures
   - `d-inference` mentions

   Wire names a user must type are allowed: `macprovider-cli`,
   `X-MacProvider-*`, `~/.config/macprovider`.
5. **Safety rules:** do the skill's rules stop an agent from running
   destructive commands without explicit user consent, printing secrets,
   touching production, or piping unsigned scripts to a shell? Are any of the
   rules unworkable?

## Output format

Write the report to `audits/<UTC-date>/skill-md-verify-report.md` and keep it
untracked. The operator commits it.

1. `VERDICT: G1 <PASS|FAIL>, G2 <PASS|FAIL>, OVERALL <APPROVE|REQUEST_CHANGES>`
   Approval requires 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
2. Snapshot metadata:
   - live skill sha256 and fetch time
   - resolved stable CLI tag
   - deployed server version
   - `origin/main` commit
3. Findings table, most severe first:
   `ID | severity | goal (G1/G2/format/brand/safety) | skill line | claim | truth | evidence | fix`
4. G1 journey matrix (Part B) and G2 harness × capability matrix (Part C).
5. Cold-agent simulation results (Part D): the failure points.
6. Drift and publication findings (Part E).
7. A recommended skill structure: a section outline covering G1 and G2, what
   to cut, and what to add. Give an outline only; do not write the full
   rewrite.

Severity guide:
- **CRITICAL:** the skill causes an unsafe action, a secret leak, or trust in
  forged data.
- **HIGH:** a goal cannot be completed by following the skill, or a copy-paste
  command fails on a fresh Mac.
- **MEDIUM:** wrong or stale fact, missing warning that causes real failures,
  or a brand leak on the public URL.
- **LOW:** clarity or completeness issues.

Never claim that a probe, sub-agent run, or command passed if it was skipped,
interrupted, or timed out. Record the exact command and the result.
