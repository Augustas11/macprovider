# BUILD_PEARL_TCP_TUNING_IMPL — Pearl VPS TCP kernel tuning for streaming SSE

## Motivation (measured, 2026-07-04)

Cold-start / inter-token bisection against `mac` (M5 32GB, v1.8.0) via
`api.streamvc.live` measured this inter-token latency distribution
for a 500-token buyer stream:

| Bench | median | p95 | p99 | max |
|---|---:|---:|---:|---:|
| M5 → api.streamvc.live (WAN + nginx + coord + provider) | 22.6 ms | 90.4 ms | 131.9 ms | **364.0 ms** |
| Pearl → localhost:9443 gateway (no nginx, no TLS, no WAN) | 25.7 ms | 75.2 ms | 100.2 ms | **122.5 ms** |

The tail delta (~50-240 ms extra on WAN) is TCP-level jitter on the
M5 → Pearl link. Pearl is a 2vcpu 4GB DigitalOcean NYC1 droplet
running Ubuntu. Two kernel-level defaults hurt streaming SSE
specifically:

1. **`net.ipv4.tcp_slow_start_after_idle=1`** (default). WSS
   provider ↔ coord tunnel goes tens of seconds idle between token
   bursts. Default kernel resets the congestion window every idle
   period, so each new burst spends the first several RTTs in
   slow-start. For a chat-completion stream, that's noticeable.
2. **`net.ipv4.tcp_congestion_control=cubic`** (Ubuntu default).
   BBR handles jitter under bufferbloat much better than cubic —
   the classic "Google BBR paper" result. Every modern Ubuntu kernel
   (5.15+) ships the `tcp_bbr` module; enabling BBR is a two-line
   sysctl change and applies to all outbound sockets, including
   WSS + gateway → buyer.

Additionally, socket buffer defaults on 4GB VPS are conservative
(~416 KB max). For streaming responses that fill the receive window
during buffering, bumping `rmem_max` / `wmem_max` to 16 MB removes a
soft cap without meaningfully changing memory usage at current load
(current coord memory footprint is 22 MB).

## Goal (this PR)

Ship a sysctl.d file + a deploy step that:

1. Installs `/etc/sysctl.d/99-macprovider-tcp.conf` on Pearl with
   four kernel parameter overrides (see § "Sysctl file contents").
2. Applies the file at deploy time.
3. Verifies BBR is active as the actual congestion control.
4. Fails the deploy if the kernel lacks the `tcp_bbr` module.

The change is idempotent — re-running `deploy-pearl-vps.sh` produces
no drift, no restart, no reload. The sysctl values are re-verified
each run.

## Non-goals

- No change to nginx, gateway, or coord runtime code.
- No new sysctl scope beyond the 4 knobs listed below. No fq /
  fq_codel qdisc changes. No `tcp_notsent_lowat`. No IPv6 knobs.
- No changes to firewall / ufw / iptables.
- No kernel package upgrade (rely on the shipped `tcp_bbr` module).
- No systemd-networkd changes.
- Not deployed by this PR — merging just lands the artifact + deploy
  hook. Actually applying on Pearl is a follow-up operator step.

## Sysctl file contents

Exactly this file, at
`phase4-coordinator/dist/sysctl.d/99-macprovider-tcp.conf`:

```
# 99-macprovider-tcp.conf — Pearl VPS TCP tuning for streaming SSE.
# Managed by phase4-coordinator/dist/deploy-pearl-vps.sh; do not
# edit by hand.
#
# Applies to all outbound sockets on this host: nginx → buyer,
# gateway → coord, coord → provider WSS. See PR #<PR> and the
# 2026-07-04 inter-token latency bisection for the measurement
# that motivated each knob.

# BBR handles jitter / bufferbloat better than cubic. Requires the
# tcp_bbr kernel module; deploy-pearl-vps.sh verifies availability.
net.ipv4.tcp_congestion_control=bbr

# Do NOT reset the congestion window after an idle period. WSS
# provider tunnels spend tens of seconds idle between token bursts;
# without this each burst restarts slow-start and eats several RTTs.
net.ipv4.tcp_slow_start_after_idle=0

# Raise socket send/receive buffer ceilings from the Ubuntu default
# (~416 KB) to 16 MB. Removes a soft cap on streaming responses on
# high-BDP paths. Actual per-socket allocation grows only under load.
net.core.rmem_max=16777216
net.core.wmem_max=16777216
```

Exact file contents — no additional keys, no blank lines beyond the
ones shown, no trailing whitespace on non-blank lines. The file's
permissions must be `0644 root:root` when installed on Pearl.

## Deploy hook

Add a new step to
`phase4-coordinator/dist/deploy-pearl-vps.sh` immediately after the
existing "step 3/9: create macprovider system user + dirs" block
and before the existing nginx-install step. Numbering: promote it
to a sub-step like "step 3b/9: install TCP sysctl overrides" so the
existing 4-9 numbering stays stable (renumbering would break
operator muscle memory).

### Step 3b/9 behaviour

1. `scp` the local
   `phase4-coordinator/dist/sysctl.d/99-macprovider-tcp.conf` to a
   temp path on Pearl (e.g. `/tmp/macprovider-tcp.conf`).
2. Over SSH:
   a. Detect BBR module availability: `modprobe -n -v tcp_bbr`
      (dry-run resolution). If the module is not present in the
      kernel image, **fail the deploy** with a clear message that
      names the machine's `uname -r` and asks the operator to
      either install `linux-modules-extra-$(uname -r)` or upgrade
      the kernel.
   b. Load the module: `modprobe tcp_bbr`. If load fails, fail the
      deploy.
   c. `install -m 0644 -o root -g root /tmp/macprovider-tcp.conf
      /etc/sysctl.d/99-macprovider-tcp.conf`.
   d. Apply: `sysctl -p /etc/sysctl.d/99-macprovider-tcp.conf`. On
      failure, fail the deploy.
   e. Verify: query each of the 4 sysctl keys and assert its value
      is the expected one. On mismatch, print the actual value and
      fail the deploy.
   f. Verify BBR is the actual active congestion control globally:
      `sysctl -n net.ipv4.tcp_congestion_control` must return `bbr`.
   g. Clean up `/tmp/macprovider-tcp.conf`.
3. Idempotency: re-running produces no output beyond "step 3b/9:
   TCP sysctl overrides — already applied". Detect via
   `cmp -s` against the on-disk copy before re-installing, or by
   comparing the currently-applied sysctl values against expected.

### Log line style

Match existing steps' log style:
```
log "step 3b/9: install TCP sysctl overrides"
```
and
```
log "  TCP sysctl overrides applied: bbr + slow_start_after_idle=0 + 16MB buffers"
```
for the success line.

## Test artifact

New file
`phase4-coordinator/dist/test/check_pearl_tcp_test.sh` that:

1. Asserts the sysctl file exists at the expected repo path.
2. Asserts each of the 4 expected keys is present with the exact
   expected value.
3. Asserts no additional sysctl keys are present in the file.
4. Asserts the file has no trailing whitespace on non-blank lines,
   no CRLF line endings, and ends with a single newline.
5. Asserts the deploy script contains an install invocation for the
   file at `/etc/sysctl.d/99-macprovider-tcp.conf` with mode `0644`
   and owner `root:root`.
6. Asserts the deploy script contains a `modprobe -n -v tcp_bbr`
   presence check and a `modprobe tcp_bbr` load step.
7. Asserts the deploy script contains a post-apply verification
   step that reads `net.ipv4.tcp_congestion_control` and matches
   against `bbr`.

The test file must be executable, use `bash -euo pipefail`, and
follow the shape of existing tests in the same directory (e.g.
`check_deploy_config_test.sh`). Exit 0 on success, non-zero on any
failure with a short description of what failed.

Add the test to the existing test-runner if one exists (grep the
`Makefile` or `.github/workflows/` for a test-invocation pattern);
if the convention is per-test explicit invocation, follow that.

## Acceptance criteria

**AC1** — File
`phase4-coordinator/dist/sysctl.d/99-macprovider-tcp.conf` exists
and matches § "Sysctl file contents" byte-for-byte.

**AC2** — `bash phase4-coordinator/dist/test/check_pearl_tcp_test.sh`
exits 0 in a clean repo checkout.

**AC3** — `deploy-pearl-vps.sh` executes step 3b/9 in a dry-run mode
(if one exists) or with `set -x` shows the exact commands:
`scp … tcp.conf`, `modprobe -n -v tcp_bbr`, `modprobe tcp_bbr`,
`install -m 0644 …`, `sysctl -p …`, `sysctl -n
net.ipv4.tcp_congestion_control`.

**AC4** — Deploy script step 3b/9 fails-loud with a targeted message
when the target kernel lacks the `tcp_bbr` module (simulated by
mocking `modprobe -n -v tcp_bbr` to return non-zero).

**AC5** — Idempotent re-run: second invocation produces
"already applied" without re-installing or restarting anything.

**AC6** — Existing test suite unchanged and passes:
- `bash phase4-coordinator/dist/test/check_deploy_config_test.sh`
- `bash phase4-coordinator/dist/test/check_pearl_tls_test.sh`
- and all other files under `phase4-coordinator/dist/test/`.

**AC7** — No changes to nginx configs, gateway configs, coord Go
code, provider Swift code, or systemd unit files.

## Prohibited implementation choices

- Do NOT `sysctl -w` individual keys at deploy time — apply from
  the file so persistence survives reboots.
- Do NOT run `sysctl --system` (that re-applies every conf in
  `/etc/sysctl.d/` and can perturb unrelated tuning). Only apply
  the specific file.
- Do NOT add new sysctl keys beyond the 4 listed. Extending scope
  is a follow-up PR, not this one.
- Do NOT touch `/etc/sysctl.conf` (deprecated in favour of
  `/etc/sysctl.d/`).
- Do NOT install the file if `SKIP_TCP_TUNING=1` env is set. This
  is a documented escape hatch for operators who need to test
  without the tuning. Log the skip clearly.
- Do NOT change existing step numbering. Sub-step "3b/9" only.

## Commit style

```
chore(pearl): TCP kernel tuning for streaming SSE (BBR + no-idle-reset + 16MB bufs)

Motivation: 2026-07-04 inter-token latency bisection measured 240ms
of tail latency on the M5→Pearl WAN path that's not present on
localhost. Root cause is TCP-level jitter under bufferbloat + cwnd
reset after WSS idle. Four sysctl overrides on Pearl close most of
this without any code change.

Change: new phase4-coordinator/dist/sysctl.d/99-macprovider-tcp.conf
+ deploy-pearl-vps.sh step 3b/9 that installs it, verifies
tcp_bbr module availability, applies the file, and post-verifies
active congestion control is bbr.

Tested: new check_pearl_tcp_test.sh (offline validation); existing
dist/test/ suite unchanged.

Not deployed: merging this lands the artifact. Actually applying on
Pearl is the next operator step (a single deploy-pearl-vps.sh run).
```

## Audit boundaries

Three lanes will fire against the diff:

- **CODE** — shell correctness: `set -euo pipefail`, no
  word-splitting bugs, no injection surfaces on the `install -m ...`
  args, `scp` uses `SSH_KEY` variable consistently with other scp
  invocations in the same script, idempotency logic is correct.
- **SECURITY** — no privilege escalation surface, no path
  traversal (temp path is a fixed literal), no config-drift
  bypass (SKIP_TCP_TUNING escape hatch clearly logs), no impact on
  existing nginx / gateway / coord auth paths.
- **ARCHITECT** — placement in deploy script, sub-step numbering
  choice, file naming (99- prefix appropriate for sysctl.d
  precedence), consistency with existing dist/ organisation, no
  scope creep beyond the 4 sysctl keys.

## References

- Inter-token latency bisection data: 2026-07-04 session.
- Deploy-script step-numbering convention:
  `phase4-coordinator/dist/deploy-pearl-vps.sh` lines 251-460.
- Existing test-file shape:
  `phase4-coordinator/dist/test/check_deploy_config_test.sh`.
- BBR module availability: Ubuntu 22.04+ kernels ship `tcp_bbr`
  under `linux-modules-$(uname -r)`; deploy verification checks
  this at run time rather than in this PR.
