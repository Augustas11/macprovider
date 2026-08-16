# AUDIT — Fix iss-191 (watchdog fleet-wide) — R1 SECURITY lane

## Scope

Same as CODE prompt — 8 files in
`/Users/augstar/macprovider-fix-191`. Read `git diff origin/main..HEAD`.

## Context

Same as CODE prompt.

## You are the SECURITY auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M**.

The watchdog runs as the operator's UID under launchd every 60s
and can call `launchctl kickstart` on the main provider
LaunchAgent. Anything that lets a non-operator surface trigger
arbitrary kickstarts, log injection, or write/delete in
operator-controlled paths is in scope.

Specifically check:

1. **Provider id supply chain.** `~/.config/macprovider/config.yaml`
   is operator-writable. A malicious value of `provider_id` flows
   into `log "...provider_id=${pid}..."`. Is there any path where
   the value reaches a shell-expansion or command-substitution
   context? (Watch for `eval`, `bash -c`, `system(awk)`, etc.)
2. **Inlined heredoc integrity.** The watchdog body is duplicated
   verbatim into `install.sh` as a here-doc. Confirm the heredoc
   quoting (`'WATCHDOG_EOF'`) actually disables expansion so a
   malicious env value at install time cannot inject into the
   committed-to-disk script. (Quoted heredocs `<<'EOF'` are the
   canonical pattern; verify it's the quoted form in the diff.)
3. **launchctl kickstart blast radius.** If an attacker can get the
   watchdog to fire kickstart on demand, they can repeatedly
   restart the provider — but this is the user's own UID and they
   could do that directly anyway. Confirm: no privilege escalation
   beyond the operator's existing capability.
4. **Plist render path.** `render_watchdog_plist` substitutes
   `coord_host` from the configured coordinator URL. Confirm:
   (a) `xml_escape` handles `&`, `<`, `>`, `"`, `'` so a malicious
   URL cannot break the plist out of its element;
   (b) The sed extraction `sed -E 's#^wss?://##; s#/.*##'` cannot be
   tricked into producing arbitrary plist content.
5. **Log injection.** Log lines include the provider_id and resolved
   IP. The IP is from dscacheutil/host output. The provider_id is
   from operator yaml. Both could contain ANSI escapes or newlines.
   Is the log file readable in a way that injection matters (e.g.
   a syslog forwarder ingesting it, a journald-style structured
   sink)? Minor concern but worth a one-line note.
6. **DNS resolution trust.** `resolve_coordinator_ip` uses
   dscacheutil → host. A poisoned DNS cache could resolve
   `coordinator.malibu.tech` to an attacker-controlled IP. Then
   netstat won't match (no ESTABLISHED to that IP) and the
   watchdog will kickstart every 60s. This is a DoS, not an auth
   bypass — but worth flagging as the failure mode of trusting
   resolver state.
7. **Install path safety.** The standalone uninstall.sh has a
   prefix guard:
   ```bash
   expected_prefix="$HOME/.local/share/macprovider-watchdog"
   case "$WATCHDOG_DIR" in
     "$expected_prefix"|"$expected_prefix"/*) ;;
     *) exit 1 ;;
   esac
   ```
   Confirm the guard catches obvious escapes (`/`, `$HOME`, empty,
   `..` segments).
8. **No auth bypass / token leakage.** The watchdog reads the
   yaml file but only the `provider_id` line. Confirm no other
   secret-bearing field (provider_token, etc.) is read or logged.

Out of scope: anything outside the 8 files in the diff.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
