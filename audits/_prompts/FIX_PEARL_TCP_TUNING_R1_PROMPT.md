# FIX_PEARL_TCP_TUNING_R1 — apply R1 MEDIUM findings

Round 1 audit MEDIUM findings that MUST be fixed before ship. All
LOW / INFO findings ship as-is with PR-body documentation.

## ARCHITECT MEDIUM #1 — verification enumerates keys inline

**File:** `phase4-coordinator/dist/deploy-pearl-vps.sh` around
line 546 (the per-key `sysctl -n` verification block).

**Defect:** the verification loop hardcodes the four sysctl keys in
the shell script. Adding a fifth key requires editing deploy logic,
not just the `.conf` file, which contradicts the BUILD prompt § 5
"Extensibility" requirement that the file should be the source of
truth.

**Fix:**

1. Parse expected `key=value` pairs from `$tmp_conf` at deploy time.
   Use a small awk/sed loop that skips blank lines and `#` comments.
2. Iterate over the parsed pairs; for each, `sysctl -n "$key"` on
   Pearl and compare against the expected value.
3. On mismatch, emit the same fail-loud message shape as today
   (name the key, name expected, name actual).
4. The four current keys should produce byte-identical behaviour to
   the pre-fix code. Verify by re-running
   `bash phase4-coordinator/dist/test/check_pearl_tcp_test.sh`.

Idiomatic shell for the parse (adjust to match repo style):

```bash
while IFS='=' read -r key expected_value; do
    [ -z "$key" ] || [ "${key:0:1}" = "#" ] && continue
    key="$(echo "$key" | sed -E 's/^ +| +$//g')"
    expected_value="$(echo "$expected_value" | sed -E 's/^ +| +$//g')"
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    if [ "$actual" != "$expected_value" ]; then
        die "sysctl mismatch: $key expected=$expected_value actual=$actual"
    fi
done < "$tmp_conf"
```

## ARCHITECT MEDIUM #2 — BBR boot persistence

**File:** `phase4-coordinator/dist/deploy-pearl-vps.sh` around
line 524 (the `modprobe tcp_bbr` load site).

**Defect:** `modprobe tcp_bbr` loads the module NOW, but does not
guarantee it is loaded on future reboots BEFORE `systemd-sysctl.service`
applies `/etc/sysctl.d/99-macprovider-tcp.conf`. If BBR isn't loaded
when the sysctl runs, the kernel may silently fall back to cubic or
fail to apply.

**Fix:**

1. Add a companion `phase4-coordinator/dist/modules-load.d/tcp_bbr.conf`
   file with a single line `tcp_bbr` and a top-of-file comment
   explaining what it does (mirror the sysctl.conf's comment style).
2. In step 3b/9, `scp` and `install -m 0644 -o root -g root` this
   file to `/etc/modules-load.d/tcp_bbr.conf` alongside the sysctl
   file.
3. Extend the test file
   `phase4-coordinator/dist/test/check_pearl_tcp_test.sh` to assert:
   a. the new artifact exists at the expected repo path
   b. it contains exactly `tcp_bbr` as its non-comment content
   c. the deploy script installs it with the same install invocation
      style as the sysctl file
4. Idempotency: same `cmp -s` check as the sysctl file.
5. Comment placement in the deploy script step: "modules-load.d
   ensures tcp_bbr is loaded before systemd-sysctl at boot".

## ARCHITECT MEDIUM #3 — historical macprovider sysctl detection

**File:** `phase4-coordinator/dist/deploy-pearl-vps.sh` around
line 521 (before the install step).

**Defect:** the step installs
`/etc/sysctl.d/99-macprovider-tcp.conf` but does not detect other
`/etc/sysctl.d/*macprovider*` files that may exist from a previous
deploy or a historical experiment. This creates ambiguous ownership.

**Fix:**

1. Before install, list any `/etc/sysctl.d/*macprovider*` files
   whose basename is NOT `99-macprovider-tcp.conf`.
2. If any are found, log a WARN line naming each one, and continue
   the deploy (do not fail-loud — this is a hygiene concern, not
   a correctness gate).
3. WARN message shape:
   `log "  WARN: found unexpected macprovider sysctl artifacts on Pearl:"`
   followed by one indented line per file, then
   `log "  These are not managed by this deploy; consider removing after verifying they are stale."`
4. Extend the test file to assert the deploy script contains the
   detection loop (grep for the `WARN` message shape).

## SECURITY MEDIUM — rollback command on partial-apply failure

**File:** `phase4-coordinator/dist/deploy-pearl-vps.sh` around
line 561 (the failure branch after `sysctl -p "$dst"` or
verification).

**Defect:** the failure messages after step 3b/9 partial-apply do
not tell the operator how to roll back. Kernel TCP state may have
been mutated between `sysctl -p` succeeding and verification
failing.

**Fix:**

1. Add a helper function OR inline the rollback text at every step
   3b/9 failure site:
   ```
   die "  step 3b/9 failure — kernel TCP state may be partially mutated.
     Rollback: sudo rm /etc/sysctl.d/99-macprovider-tcp.conf /etc/modules-load.d/tcp_bbr.conf && sudo sysctl --system
     Then investigate the failure above before re-running the deploy."
   ```
2. The failure sites to cover:
   a. `sysctl -p "$dst"` non-zero exit
   b. Per-key verification mismatch
   c. Post-apply `net.ipv4.tcp_congestion_control` != `bbr`
3. The rollback message should NOT print on:
   a. BBR module missing (nothing mutated yet)
   b. `SKIP_TCP_TUNING=1` skip path
   c. `install` failure (file wasn't in place yet)

## What NOT to fix in this round

Per repo convention (stop-iterating-on-LOWs), all R1 LOWs ship
with PR-body documentation and are NOT fixed in this round:

- CODE LOW — `SKIP_TCP_TUNING=1` log message wording mismatch
  (current: `... set — skipping TCP sysctl overrides`; requested by
  auditor: `... bypassing TCP kernel tuning`). Log-message taste.
- SECURITY LOW — precedence collision check against
  `/etc/sysctl.d/99-sysctl.conf` and later files. Reasonable
  hygiene concern, deferred as follow-up.
- ARCHITECT LOW — Makefile is out-of-scope for this lane but is
  intentional (wires the new test into `test-dist`). No fix
  required.

## Deliverables

- `phase4-coordinator/dist/deploy-pearl-vps.sh` updated with the
  four fixes above.
- New file `phase4-coordinator/dist/modules-load.d/tcp_bbr.conf`.
- `phase4-coordinator/dist/test/check_pearl_tcp_test.sh` extended
  with new assertions.
- No changes outside R1 scope.

## After finishing

1. `bash phase4-coordinator/dist/test/check_pearl_tcp_test.sh` must
   pass.
2. `bash phase4-coordinator/dist/test/check_deploy_config_test.sh`
   and all other existing dist/test/ files must still pass.
3. `make test-dist` must complete without regression.
4. Print a short summary of applied fixes ordered
   (ARCH-M1, ARCH-M2, ARCH-M3, SEC-M).
