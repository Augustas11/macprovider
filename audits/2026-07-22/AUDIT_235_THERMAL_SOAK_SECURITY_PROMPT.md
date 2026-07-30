# AUDIT_235 — thermal-soak instrument — SECURITY lane

You are auditing a **test-harness change** on branch `research/235-thermal-soak`
in the macprovider repo. Review the diff vs `origin/main` for SECURITY issues
only (this lane). Report findings CRITICAL / HIGH / MEDIUM / LOW / INFO with
file:line and a concrete fix. Bar for merge: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

## What the change is

RESEARCH_235 builds the *instrument* for a thermal/sustained-load soak (issue
#584). It adds a Go benchmark invariant (B10), a scenario YAML, and two
provider-side capture scripts that run on a LAB Mac. No soak has run.

## Focus for THIS lane (security)

1. **Prod-safety / blast radius** — the single most important property. The
   soak MUST NOT be runnable against production, because a sustained load
   degrades and disconnects the prod mac (that IS #584). Verify:
   - `test/network-harness/scenarios/15_thermal_soak.yaml` targets
     `${LAB_GATEWAY_URL}` / `${LAB_COORDINATOR_URL}`, which are unset by
     default. Confirm the harness env-expansion + `Validate()` behavior means
     an unset lab URL → empty gateway_url → validation ERROR (fail-closed), so
     you cannot accidentally fire at a baked-in prod default. Is there ANY
     path (default value, fallback, other scenario field) by which this
     scenario could hit `streamvc.live`?
   - The committed-scenarios test (`schema_test.go`) seeds
     `LAB_GATEWAY_URL`/`LAB_COORDINATOR_URL` placeholders so the structural
     test passes. Confirm that seeding is test-scoped (`t.Setenv`) and does
     NOT leak a usable default into the runtime path.

2. **Secret handling** — the buyer token (`~/.config/macprovider/buyer-api-key`)
   must never be committed or echoed. Check the scripts and YAML:
   - `test/e2e/thermal-soak/thermal-collector.sh`
   - `test/e2e/thermal-soak/join-thermal.py`
   - `test/e2e/thermal-soak/README.md`
   - scenario 15 YAML (uses `${BUYER_TOKEN}`).
   Any place a token, DSN, or credential could be logged, embedded, or written
   to the NDJSON output?

3. **Shell-injection / command-exec in `thermal-collector.sh`** — it runs
   `sudo powermetrics ...`, `pmset -g therm`, pipes tool output through
   `awk`/`python3 -c` (`json_str`), and writes to a `--out` path. Check:
   - Are any argument values (`--out`, `--interval`, `--duration`) used
     unsafely (unquoted expansion, path traversal, arithmetic injection in
     `$((...))`)?
   - `powermetrics` raw output is passed to `python3 -c 'json.dumps(...)'` via
     stdin — confirm the raw device text can't break out of JSON or inject
     into the shell. Is the `sudo` usage minimal and scoped?
   - Does the script fail safely on a non-macOS host (it checks `uname`)?

4. **`join-thermal.py`** — parses two untrusted-ish NDJSON/JSONL files. Any
   unsafe eval, path handling, or resource-exhaustion (unbounded memory on a
   huge file)? It's stdlib-only; confirm no `eval`/`exec`/`pickle`/`os.system`.

5. **Data exposure in artifacts** — the NDJSON thermal log preserves raw tool
   output under a `"raw"` field. Could that raw text contain anything sensitive
   (hostnames, serials, user paths) that shouldn't land in a committed or
   shared artifact? Flag if the README implies committing raw logs.

## How to review

The branch is checked out at the repo root. Read the full files. The threat
model is: an operator runs these on a lab Mac they control; the main risk is
(a) accidentally hitting prod, (b) leaking the buyer token, (c) shell/JSON
injection from device tool output. Do NOT flag the provisional B10 thresholds
(that's a calibration matter, not security).
