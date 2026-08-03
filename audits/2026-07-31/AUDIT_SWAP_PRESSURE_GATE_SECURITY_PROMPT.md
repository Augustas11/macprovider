# Codex SECURITY audit — swap-gate → memory-pressure fix (branch fix/swap-pressure-gate)

You are a security/abuse auditor. Report vulnerabilities and abuse vectors only; DO NOT edit any files.

## What to read
- Full fix diff: `/Users/augstar/macprovider-poc/scratchpad/swap-pressure-fulldiff.patch`
- Source: `/Users/augstar/macprovider-swap-pressure-gate/phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`

## Context
Money-path provider admission. The change LOOSENS a paid-eligibility veto: swap used to block on any pageout; now it blocks only on sustained CRITICAL memory pressure (>=3 samples, >=50% `.critical`), with WARNING-majority downgraded to a non-blocking advisory. Buyer-facing quality is otherwise protected by the separate `buyerTTFTCeilingExceeded` hard veto — BUT that ceiling defaults to 0 (disabled) unless the operator sets `--buyer-ttft-ceiling-ms`. A new local telemetry log is written to `~/.cache/macprovider/autotune-logs/probe-safety.log`.

## Audit focus (rate CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line + concrete exploit/abuse scenario)
1. **Quality/DoS regression:** can a genuinely-thrashing node now pass the gate, get admitted, and serve buyers at unusable throughput — degrading the network — when the buyer TTFT ceiling is disabled (its default)? Is the sustained-CRITICAL threshold a real backstop, or does removing the pageout gate leave buyer UX unprotected in the default config? Quantify the exposure.
2. **Gameability:** can a provider deliberately suppress the CRITICAL signal during the probe (e.g. free memory only for the probe window, then thrash when serving real traffic) to get admitted while intending to serve badly? Is the pressure signal probe-time-only and therefore spoofable by transient environment control? Compare to the old pageout gate's gameability.
3. **Fail-open paths:** any input/timing where the new logic fails OPEN (admits) that the old one failed CLOSED — beyond the intended incidental-pressure case? e.g. probe shorter than 3 samples, sampler task starved/cancelled early, sysctl returning an unexpected value mapped to `.unknown` and then diluting the majority.
4. **sysctl usage:** `sysctlbyname("kern.memorystatus_vm_pressure_level", ...)` — any memory-safety issue (buffer/size), privilege assumption, or availability difference across supported macOS versions / VM hosts that could be abused or cause a wrong verdict.
5. **Telemetry log:** does `probe-safety.log` leak anything sensitive (identity, paths, tokens)? Path traversal / symlink / permissions concerns on `~/.cache/macprovider/autotune-logs/`? Unbounded growth / log-injection from model keys?
6. **Contract integrity:** confirm nothing changes the coordinator-facing `swap_detected` evidence semantics in a way a malicious provider could exploit (e.g. self-report a favorable value). Confirm the coordinator still independently rejects swapped evidence where it should.

## Output
Ranked, most-severe first: severity, file:line, one-sentence issue, concrete abuse scenario. If zero C/H/M, say so explicitly.
