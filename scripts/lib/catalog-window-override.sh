# shellcheck shell=bash
# Shared "append one catalog override/coverage record" primitive (#1688).
# Used by phase4-coordinator/dist/deploy-pearl-vps.sh and
# scripts/catalog-content-release.sh so both write
# /var/lib/macprovider/catalog-window-overrides.jsonl through the identical
# root-only 0600, O_APPEND|O_NOFOLLOW, regular-file-only, fsync contract, and
# add "ts" the same way. Sourced, never executed. bash 3.2.
#
# scripts/renew-autotune-static-feed.sh keeps its own copy of this append:
# its bytes are pinned by scripts/tests/fixtures/renew-remote-*.golden.sh and
# by literal substring pins in scripts/test-renew-autotune-static-feed-signed.sh,
# so it is not sourced from here (avoids a third copy for deploy+the content
# lane without disturbing renew's frozen bytes).
#
# deploy-pearl-vps.sh calls its Pearl commands through a $SSH VARIABLE;
# catalog-content-release.sh calls them through an SSH() FUNCTION. This lib
# only builds the remote command text, so each caller runs it through
# whichever convention it already uses:
#   deploy:  $SSH "$(cwo_override_remote_command "$1" "$2" macprovider-deploy)"
#   lane:    SSH "$(cwo_override_remote_command "$b64" "$msg" macprovider-catalog-content)"
#
# cwo_override_remote_command <base64 record JSON without "ts"> <logger message> <logger tag>
cwo_override_remote_command() {
  printf '%s' "set -e
    install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
    python3 -I - '$1' <<'PY'
import base64, datetime, json, os, stat, sys
record = json.loads(base64.b64decode(sys.argv[1], validate=True).decode('ascii'))
if not isinstance(record, dict) or 'ts' in record:
    raise SystemExit('override record must be a JSON object without ts')
record['ts'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
path = '/var/lib/macprovider/catalog-window-overrides.jsonl'
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise SystemExit(path + ' is not a regular file')
    os.fchown(fd, 0, 0)
    os.fchmod(fd, 0o600)
    os.write(fd, (json.dumps(record, sort_keys=True) + '\\n').encode('ascii'))
    os.fsync(fd)
finally:
    os.close(fd)
PY
    logger -t '$3' '$2'"
}
