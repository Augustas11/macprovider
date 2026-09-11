# BYOM v0.2 slice 5 SPEC closure — pass 2 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `20b1a21a`. Three codex lanes over `AUDIT_BYOM_V02_SLICE5_SPEC_CLOSURE_2_PROMPT.md`.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 1 | 1 | 1 | 0 |
| security-reviewer | 0 | 0 | 3 | 1 | 0 |
| architect | 0 | 0 | 2 | 0 | 0 |

Fixed in the R3 fix commit:

- **Generic `OPTIONS`/CORS text (§4.3, §5.7, §5.9, AC-21) still covered intake** (code H, sec M3, arch M): explicit `/v1/stats/intake` carve-outs — enabled OPTIONS is 405 `Allow: GET, HEAD`, no CORS header; disabled 404.
- **Key-less intake refusals had no rate-limit bucket** (sec M1): every intake 401, absent `Authorization` included, debits the auth-failure tier (300/min per IP per endpoint) and keeps its slot; §5.6 v0.2.1 note; mux + test (301st key-less request → 429).
- **Redaction stated only for unserved requests** (sec M2): §5.2b.2 states the served case — the model column records the pool-advertised served model identity (SPEC-005 settlement evidence), never a string the pool did not recognize.
- **Canonical `fleet_ram` example violated complementary suppression** (arch M): example is now 15 = 4 (16 GB) + 5 (32 GB) + 6 suppressed, with the distribution spelled out; handler fixture aligned.
- **R009 negation wording** (code M): "not sanctioned by `provider_intake_sanctioned`, and holding an active hardware-trust root".
- **Salt rule length-based** (sec L): at least 128 bits of CSPRNG material; the 16-character check is a floor.
- **Duplicate "Retention lifecycle" label** (code L): "Permissions and retention".
