## Lane: SECURITY — Round 1

## Context

Issue #291: extract TLS state machine from
`phase4-coordinator/dist/deploy-pearl-vps.sh` into
`phase4-coordinator/dist/lib/pearl_tls.sh` + add fixture tests.

Fix in commit `871dd31`. Pure refactor — no new features. The
extracted functions run entirely on the operator's Mac (LOCAL), not
on Pearl. The remote probe script is generated locally via
`pearl_tls_remote_probe_script` then fed via `ssh $VPS bash -s -- $D1 $D2 ...`.

## Your job

SECURITY LANE round 1. This is deploy-code — the only path to shipping
new binaries to a production coordinator that handles money-path
traffic. Standard severity-graded findings.

Focus areas:
- Does the extracted `pearl_tls_remote_probe_script` still produce
  the exact same shell script that was previously inline heredoc?
  Any character-set drift (quoting, escapes, newlines) that would
  allow shell metacharacter injection under a malicious DOMAIN /
  STATS_DOMAIN?
- Does the `. $_PEARL_TLS_SCRIPT_DIR/lib/pearl_tls.sh` sourcing pattern
  open a path-traversal / library-hijack vector? (BASH_SOURCE
  resolution + `cd` + `pwd`.)
- Do the fixture tests introduce any local-path race (`mktemp -d -t`
  is used — is that adequate on macOS 3.2 bash?)
- Does the `PATH="$_empty_dir" "$_bash_exe" -c ...` test invocation
  in T24 open a path-hijack surface if run under CI?

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh` (NEW)
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh` (NEW)
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh` (MODIFIED)

Diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`
