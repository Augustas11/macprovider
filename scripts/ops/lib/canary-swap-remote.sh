#!/bin/bash
# Runs ON the canary Mac. scripts/ops/canary-swap.sh stages it next to the
# candidate tarball and starts it detached (nohup), so a dropped ssh session
# cannot interrupt a swap or a rollback; the operator side polls RESULT_FILE.
# bash 3.2 compatible (stock macOS /bin/bash).
#
# Payload swap of the live provider to a verified candidate tarball, or the
# narrowly-scoped Studio owner-pin transaction staged by studio-owner-pin.sh:
# pause and drain, back up the install dir, replace the payload, restart, then
# watch (the installed watchdog stays booted out until the candidate, or the
# restored version, is buyer_serving). A provider process restart (crash loop),
# a process that exits, or a /v1/status silence of STATUS_TIMEOUT_S once the
# candidate has reported its model loaded restores the backup, waits until the
# previous version is buyer_serving again, and resumes it. Before the model is
# loaded /v1/status may stay silent (a large model, such as GLM-5.3-Flash at
# about 175 GB, loads for 7-13 minutes): silence then is bounded only by
# READY_TIMEOUT_S while the provider pid stays the same and alive. The owner-
# pin mode changes only max_concurrency_override/max_concurrency_source under
# the provider config lock and restores only those fields on failure.
#
# Exit codes (also written to RESULT_FILE): 0 swapped and buyer-serving;
# 4 refused before the swap (payload untouched, provider resumed);
# 5 candidate failed, previous version restored and buyer-serving;
# 6 recovery needs the operator (the log says what is left).
set -euo pipefail
export PATH="${CANARY_REMOTE_PATH_PREFIX:+$CANARY_REMOTE_PATH_PREFIX:}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
umask 077

# Fixed transaction actor, dispatched only by the owning catalog controller.
if [ "${1:-}" = signed-pair-engine ]; then
  [ "$#" = 3 ] || exit 2
  python3 -I - "$2" "$3" "${BASH_SOURCE[0]:--}" <<'SIGNED_PAIR_PY'
"""Fixed Studio signed-pair actor. Embedded in the remote ops entry point.

The root controller owns the Pearl lease and runner guardian. An uncertain
cross-host commit isolates the provider; it never guesses which half won.
"""
import base64
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import time
import urllib.request


class Refused(RuntimeError):
    pass


def require(ok, reason):
    if not ok:
        raise Refused(reason)


def read_private(path):
    path = Path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and not info.st_mode & 0o077, 'unsafe private input')
        return source.read()


def put(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.next-' + str(os.getpid()))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as target:
        json.dump(value, target, sort_keys=True)
        target.flush()
        os.fsync(target.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sha(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        require(stat.S_ISREG(os.fstat(source.fileno()).st_mode), 'nonregular payload')
        result = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()


def field(body, key):
    for part in key.split('.'):
        body = body.get(part) if isinstance(body, dict) else None
    return body


def validate(j):
    require(j['schema_version'] == 'macprovider.signed_native_pair.v1', 'journal schema')
    require(re.fullmatch(r'[A-Za-z0-9_-]{1,80}', j['transaction_id']), 'transaction ID')
    require(j['coordinator_url'] == 'https://coordinator.malibu.tech', 'coordinator target')
    require(type(j['deadline_epoch']) is int and type(j['recovery_seconds']) is int
            and 0 < j['recovery_seconds'] <= 3600, 'recovery bounds')
    require(type(j['stable_seconds']) is int and j['stable_seconds'] >= 120, 'stable bound')
    require(j['prior']['version'] != j['target']['version'], 'unchanged binary version')
    require(j['prior']['request_feature_profile'] == 'native_mtp_greedy_text_v1'
            and j['target']['request_feature_profile'] == j['prior']['request_feature_profile'], 'greedy permission scope')
    require(re.fullmatch(r'[0-9a-f]{64}', j['target']['previous_window_sha256']), 'target compatibility window digest')
    require(type(j['prior']['ordinary_context_tokens']) is int
            and j['prior']['ordinary_context_tokens'] >= 4096
            and j['target']['ordinary_context_tokens'] == j['prior']['ordinary_context_tokens'], 'ordinary context must be preserved')
    for role in ('prior', 'target'):
        identity = j[role]
        provenance = identity['provenance']
        require(provenance == 'reviewed_published_signed_release' or
                (role == 'target' and provenance == 'reviewed_signed_acceptance_candidate'), 'unsigned or unauthorized payload')
        if provenance == 'reviewed_signed_acceptance_candidate':
            require(re.fullmatch(r'[1-9][0-9]*', str(identity['candidate_run_id'])), 'acceptance run identity')
            for key in ('acceptance_manifest_sha256', 'acceptance_signature_sha256', 'checksums_sha256'):
                require(re.fullmatch(r'[0-9a-f]{64}', identity[key]), 'acceptance evidence digest')
        require(re.fullmatch(r'[0-9a-f]{40}', identity['source_commit']), 'source identity')
        for key in ('binary_sha256', 'tarball_sha256', 'decode_path_digest', 'model_hash'):
            require(re.fullmatch(r'[0-9a-f]{64}', identity[key]), 'payload identity')
        require(re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', identity['cdhash']), 'CDHash')
        require(identity['team_id'] and identity['signing_identifier'], 'signature identity')
        required = {'/v1/native-mtp-admission', '/v1/native-mtp-admission.sig',
                    '/v1/native-mtp-selftest-bank', '/v1/native-mtp-selftest-bank.sig',
                    '/v1/native-mtp-artifact-manifest', '/v1/autotune-candidates',
                    '/v1/autotune-candidates.sig', '/v1/catalog-artifacts', '/v1/catalog-artifacts.sig', '/v1/continuous-batching-policy',
                    '/v1/continuous-batching-policy.sig'}
        require(required <= identity['feed_sha256'].keys(), 'incomplete signed policy identities')
        for endpoint, digest in identity['feed_sha256'].items():
            require(re.fullmatch(r'/v1/[a-z0-9.-]+', endpoint)
                    and re.fullmatch(r'[0-9a-f]{64}', digest), 'policy endpoint identity')
    studio = j['studio']
    require(studio['hardware_model'] == 'Mac15,14' and 'Studio' in studio['host_name'], 'designated Studio identity')
    require(type(studio['status_port']) is int and 0 < studio['status_port'] < 65536, 'status port')
    require(re.fullmatch(r'[A-Za-z0-9.-]+', studio['launchd_label']), 'launchd identity')
    for key in ('install_dir', 'config_path', 'launchd_plist', 'ctl_socket', 'capture_dir'):
        require(Path(studio[key]).is_absolute(), 'absolute Studio paths required')
    reader = j['receipt_reader']
    for key in ('host', 'user', 'server_host_key_alias'):
        require(re.fullmatch(r'[A-Za-z0-9_.-]+', reader[key]) and not reader[key].startswith('-'), 'receipt SSH identity')
    require(type(reader['port']) is int and 0 < reader['port'] < 65536, 'receipt SSH port')
    for key in ('private_key_path', 'known_hosts_path'):
        require(Path(reader[key]).is_absolute(), 'receipt SSH path')
    # A key is a path into the operator secret store, never journal material.
    require(Path(reader['private_key_path']).is_relative_to(Path.home() / '.config/macprovider/operator-secrets'),
            'receipt private key must be in operator secret store')


def receipt(j):
    reader = j['receipt_reader']
    key = Path(reader['private_key_path'])
    read_private(key)
    require(stat.S_IMODE(key.parent.stat().st_mode) == 0o700, 'receipt key directory permissions')
    require(sha(reader['known_hosts_path']) == reader['known_hosts_sha256'], 'receipt SSH host keys changed')
    result = run(['/usr/bin/ssh', '-F', '/dev/null', '-T', '-o', 'BatchMode=yes',
                  '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
                  '-o', 'ConnectTimeout=10', '-o', 'UserKnownHostsFile=' + reader['known_hosts_path'],
                  '-o', 'HostKeyAlias=' + reader['server_host_key_alias'], '-i', str(key),
                  '-p', str(reader['port']), reader['user'] + '@' + reader['host']])
    require(len(result.stdout) <= 65536, 'oversized recovery receipt')
    value = json.loads(result.stdout)
    require(value['transaction_id'] == j['transaction_id'], 'receipt transaction mismatch')
    return value


def committed_receipt(j, value):
    require(value['transaction_id'] == j['transaction_id'] and value['policy_phase'] == 'target_committed'
            and value['target_release_id'] == j['target']['catalog_release_id']
            and all(value['target_feed_sha256'].get(k) == v for k, v in j['target']['feed_sha256'].items()), 'Pearl commit receipt mismatch')


def run(args, check=True):
    return subprocess.run(args, check=check, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, timeout=30)


def host(j):
    require(sys.platform == 'darwin', 'Studio requires macOS')
    require(run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.strip()
            == j['studio']['hardware_model'], 'hardware mismatch')
    require(run(['/bin/hostname']).stdout.strip() == j['studio']['host_name'], 'host mismatch')


def signed_binary(path, identity):
    require(sha(path) == identity['binary_sha256'], 'binary bytes mismatch')
    run(['/usr/bin/codesign', '--verify', '--strict', str(path)])
    signature = run(['/usr/bin/codesign', '-d', '--verbose=4', str(path)])
    output = signature.stdout + signature.stderr
    for key, value in (('TeamIdentifier', identity['team_id']),
                       ('Identifier', identity['signing_identifier']),
                       ('CDHash', identity['cdhash'])):
        require(value in re.findall(r'^' + re.escape(key) + r'=(.*)$', output, re.M),
                'signed executable identity mismatch')
    with open(path, 'rb') as source:
        markers = set(re.findall(rb'macprovider\.decode-path-digest\.v1:([0-9a-f]{64})', source.read()))
    require(markers == {identity['decode_path_digest'].encode()}, 'embedded decode path mismatch')


def fetch(url):
    request = urllib.request.Request(url, headers={'Accept': 'application/json'})
    with urllib.request.urlopen(request, timeout=10) as response:
        require(response.geturl() == url, 'policy redirect')
        raw = response.read(16 * 1024 * 1024 + 1)
        require(len(raw) <= 16 * 1024 * 1024, 'oversized policy')
        return raw


def policy(j, identity):
    base = j['coordinator_url']
    metadata = json.loads(fetch(base + '/v1/autotune-release'))
    require(metadata.get('status') == 'live_verified'
            and metadata.get('release_id') == identity['catalog_release_id'], 'current release mismatch')
    for endpoint, expected in identity['feed_sha256'].items():
        require(hashlib.sha256(fetch(base + endpoint)).hexdigest() == expected,
                'public signed policy bytes mismatch')
    # Reading metadata again prevents accepting a torn publication snapshot.
    require(json.loads(fetch(base + '/v1/autotune-release')) == metadata, 'policy changed during proof')


def status(j):
    return json.loads(fetch('http://127.0.0.1:%d/v1/status' % j['studio']['status_port']))


def paused(body):
    return field(body, 'lifecycle.operator_paused') is True


def readiness(body, identity, provider_sha, must_pause):
    require(body.get('binary_version') == identity['version'] and body.get('model_loaded') is True,
            'target not loaded')
    require(hashlib.sha256(str(body.get('provider_id', '')).encode()).hexdigest() == provider_sha,
            'provider identity changed')
    require(body.get('model') == identity['model'] and body.get('model_hash') == identity['model_hash'], 'served model changed')
    require(field(body, 'native_mtp.enabled') is True
            and field(body, 'native_mtp.mode') in ('eligible', 'active'), 'native MTP not active')
    for key, value in {'capacity.max_concurrency': 4, 'capacity.max_context_tokens': identity['ordinary_context_tokens'], 'continuous_batching.active': True,
                       'continuous_batching.policy.load_status': 'live_verified',
                       'continuous_batching.policy.authorized': True,
                       'continuous_batching.policy.policy_sha256': identity['cb_policy_sha256'],
                       'continuous_batching.policy.release_id': identity['catalog_release_id'],
                       'continuous_batching.policy.tuple_sha256': identity['cb_tuple_sha256'],
                       'continuous_batching.self_check.served_slots': 4,
                       'continuous_batching.self_check_admission_hold.active': False,
                       'continuous_batching.scheduler.slots_total': 4}.items():
        require(field(body, key) == value, 'CB readiness mismatch: ' + key)
    require(paused(body) == must_pause, 'operator pause mismatch')
    require(body.get('requests_in_flight') == 0 if must_pause else
            body.get('network_state') == 'buyer_serving', 'admission state mismatch')


def control(j, frame):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(15)
        client.connect(j['studio']['ctl_socket'])
        client.sendall((json.dumps({'type': frame}) + '\n').encode())
        response = b''
        while b'\n' not in response and len(response) < 65536:
            block = client.recv(4096)
            if not block:
                break
            response += block
        # The fixed protocol acknowledges with accepted=true.
        body = json.loads(response.split(b'\n')[0])
        require(body.get('accepted') is True, 'control request refused')


def job(j, operation, watchdog=False):
    label = j['studio']['launchd_label'] + ('-watchdog' if watchdog else '')
    domain = 'gui/%d' % os.getuid()
    if operation == 'stop':
        run(['/bin/launchctl', 'bootout', domain + '/' + label], check=False)
        require(run(['/bin/launchctl', 'print', domain + '/' + label], check=False).returncode != 0,
                'launchd job still running')
    else:
        if watchdog and run(['/bin/launchctl', 'print', domain + '/' + label], check=False).returncode == 0:
            return
        plist = (str(Path(j['studio']['launchd_plist']).with_name(label + '.plist'))
                 if watchdog else j['studio']['launchd_plist'])
        run(['/bin/launchctl', 'bootstrap', domain, plist])


def process_id(j):
    output = run(['/bin/launchctl', 'print', 'gui/%d/%s' %
                  (os.getuid(), j['studio']['launchd_label'])]).stdout
    found = re.search(r'^\s*pid = ([0-9]+)$', output, re.M)
    require(found is not None, 'provider PID absent')
    pid = found.group(1)
    started = run(['/bin/ps', '-p', pid, '-o', 'lstart=']).stdout.strip()
    require(started, 'provider process absent')
    path = ctypes.create_string_buffer(4096)
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    require(libproc.proc_pidpath(int(pid), path, len(path)) > 0
            and os.path.realpath(os.fsdecode(path.value)) == os.path.realpath(str(Path(j['studio']['install_dir']) / 'macprovider-cli'))
            and run(['/bin/ps', '-p', pid, '-o', 'uid=']).stdout.strip() == str(os.getuid()), 'provider process identity mismatch')
    return (pid, started)


def capture(j, since, require_zero=False):
    directory = Path(j['studio']['capture_dir'])
    candidates = list(directory.glob('*.jsonl'))
    require(len(candidates) == 1, 'capture session must contain one fresh file')
    path = candidates[0]
    require(path.stat().st_mtime >= since, 'stale capture header')
    snapshot_path = Path(str(path) + '.status.json')
    require(snapshot_path.stat().st_mtime >= since, 'stale capture status')
    consistent = False
    for _ in range(10):
        status_bytes = read_private(snapshot_path)
        raw = read_private(path)
        if status_bytes == read_private(snapshot_path):
            snapshot = json.loads(status_bytes)
            if snapshot.get('jsonl_bytes_written') == len(raw):
                consistent = True
                break
        time.sleep(.02)
    require(consistent, 'capture snapshot is not consistent')
    lines = raw.splitlines()
    header_bytes = lines[0]
    header = json.loads(header_bytes)
    header_sha = hashlib.sha256(header_bytes).hexdigest()
    expected_header = j.get('capture_header_sha256')
    require(expected_header is None or expected_header == header_sha, 'capture header identity changed')
    identity = j['target']
    require(header.get('schema') == 'macprovider.native-mtp-request-shape-capture.v2'
            and header.get('record_type') == 'header'
            and header.get('capture_requires_native_mtp_off') is False
            and header.get('native_mtp_mode') == 'auto'
            and header.get('build_identity_complete') is True
            and header.get('build_source_commit') == identity['source_commit']
            and header.get('build_cdhash') == identity['cdhash']
            and header.get('cli_version') == identity['version']
            and header.get('max_records') == 1000 and header.get('max_bytes') == 10485760, 'capture v2 identity mismatch')
    require(snapshot.get('schema') == 'macprovider.native-mtp-request-shape-capture.v2'
            and snapshot.get('record_type') == 'status'
            and snapshot.get('build_identity_complete') is True
            and snapshot.get('jsonl_write_errors') == 0
            and snapshot.get('status_write_errors') == 0
            and snapshot.get('capture_file_name') == path.name
            and snapshot.get('max_records') == 1000 and snapshot.get('max_bytes') == 10485760, 'capture v2 initialization not proven')
    records = snapshot.get('successful_records')
    attempts = snapshot.get('attempts')
    written = snapshot.get('jsonl_bytes_written')
    require(type(records) is int and 0 <= records <= 1000
            and type(attempts) is int and attempts >= records
            and type(written) is int and len(header_bytes) < written <= 10485760
            and records == len(lines) - 1 and written == len(raw), 'capture counter/byte consistency')
    if require_zero:
        require(attempts == 0 and records == 0, 'fresh capture initialization proof is not zero')
    return {'header_sha256': header_sha, 'file_name': path.name}


def scoped_policy(j, role='target'):
    raw = fetch(j['coordinator_url'] + '/v1/native-mtp-admission')
    document = json.loads(raw)
    entries = [e for e in document['entries'] if e['model_key'] == j[role]['model_key']]
    require(len(entries) == 1, 'ambiguous model admission')
    entry = entries[0]
    require(entry['max_native_active_rows'] == 1 and entry['max_prompt_tokens'] == 4096
            and entry['qualified_slots'] == 4 and entry['proposal_depth'] == 1
            and entry['request_feature_profile'] == j['prior']['request_feature_profile']
            and entry['decode_path_digest'] == j[role]['decode_path_digest'], 'MTP scope changed')


def extract(j, directory):
    archive = Path(j['target']['tarball_path'])
    require(sha(archive) == j['target']['tarball_sha256'], 'released archive mismatch')
    directory.mkdir(mode=0o700)
    with tarfile.open(archive, 'r:gz') as source:
        seen = set()
        for member in source.getmembers():
            path = Path(member.name)
            normalized = os.path.normpath(member.name)
            require(not path.is_absolute() and '..' not in path.parts
                    and normalized not in seen and (member.isfile() or member.isdir()), 'unsafe archive')
            seen.add(normalized)
        for member in source.getmembers():
            # Existing ops uses this portable API; do not depend on a newer
            # Python extractall(filter=...) on the Studio. Never apply owner
            # or special permission bits from archive headers.
            source.extract(member, directory, set_attrs=False)
    os.chmod(directory / 'macprovider-cli', 0o755)
    signed_binary(directory / 'macprovider-cli', j['target'])
    baked = json.loads((directory / 'catalog-release/release.json').read_text())
    require(baked['release_id'] == j['target']['baked_catalog_release_id'], 'baked catalog identity mismatch')
    if baked['release_id'] != j['target']['catalog_release_id']:
        compatible_pair(j, baked['release_id'], baked)


def ledger_predecessor(j, baked_release, baked=None):
    """The baked catalog is an earlier, untombstoned release in the target's
    committed release ledger (staged beside the journal at arm), with the same
    policy version. The ledger's target row must carry the signed target
    admission feed digest; extracted baked bytes must match their row."""
    path = Path(j['studio']['journal_path']).parent / 'target-release-ledger.json'
    if not os.path.lexists(path):
        return False
    ledger = json.loads(read_private(path))
    target_id = j['target']['catalog_release_id']
    releases, tombstones = ledger.get('releases'), ledger.get('tombstones')
    if not (ledger.get('schema_version') == 'macprovider.autotune-release-ledger.v4'
            and isinstance(releases, dict) and isinstance(tombstones, dict)
            and baked_release == j['target']['baked_catalog_release_id'] and baked_release != target_id
            and baked_release not in tombstones and target_id not in tombstones):
        return False
    old, new = releases.get(baked_release), releases.get(target_id)
    stamp = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z')
    if not (isinstance(old, dict) and isinstance(new, dict)
            and new.get('native_mtp_admission_sha256') == j['target']['feed_sha256']['/v1/native-mtp-admission']
            and old.get('policy_version') == new.get('policy_version')
            and all(isinstance(row.get('generated_at'), str) and stamp.fullmatch(row['generated_at'])
                    for row in (old, new))
            and old['generated_at'] < new['generated_at']):
        return False
    return baked is None or (baked.get('release_id') == baked_release
                             and baked.get('generated_at') == old['generated_at']
                             and baked.get('policy_version') == old['policy_version'])


def compatible_pair(j, baked_release, baked=None):
    decision = receipt(j)
    require(decision.get('current_release_id') == j['target']['catalog_release_id']
            and decision.get('window_source') == 'retained_disk_under_lease'
            and decision.get('previous_window_sha256') == j['target']['previous_window_sha256']
            and (baked_release == j['target']['catalog_release_id'] or
                 (baked_release == j['prior']['catalog_release_id']
                  and baked_release in decision.get('compatible_previous_release_ids', []))
                 or ledger_predecessor(j, baked_release, baked))
            and decision.get('target_activation_verified') is True,
            'reviewed compatible-previous target pair not verified')
    for endpoint, digest in j['target']['feed_sha256'].items():
        require(decision.get('target_feed_sha256', {}).get(endpoint) == digest,
                'compatible target signed feed identity mismatch')
    # Parent's fixed activation receipt exists only after served-byte and HUP
    # journal gates. The reader separately reports the exact retained disk
    # window under lease; it is not mislabeled as a runtime window snapshot.
    policy(j, j['target'])


def stable(j, role, must_pause, deadline, with_capture=False):
    identity = j[role]
    began = None
    held_pid = None
    while time.time() < deadline:
        try:
            current = process_id(j)
            require(held_pid is None or current == held_pid, 'provider process restarted')
            held_pid = current
            readiness(status(j), identity, j['provider_id_sha256'], must_pause)
            signed_binary(Path(j['studio']['install_dir']) / 'macprovider-cli', identity)
            policy(j, identity)
            if with_capture:
                capture(j, j['capture_started_epoch'])
                scoped_policy(j)
            began = began or time.monotonic()
            if time.monotonic() - began >= j['stable_seconds']:
                return held_pid
        except (Refused, OSError, ValueError, subprocess.SubprocessError):
            # Losing an established identity/readiness proof is terminal.
            if began is not None:
                raise
        time.sleep(2)
    raise Refused('readiness deadline exceeded')



def watchdog_lock(j):
    directory = Path.home() / '.macprovider-canary-swap.lock'
    try:
        directory.mkdir(mode=0o700)
        (directory / 'signed-pair-owner').write_text(j['transaction_id'])
    except FileExistsError:
        require((directory / 'signed-pair-owner').is_file()
                and (directory / 'signed-pair-owner').read_text() == j['transaction_id'], 'foreign Studio swap lock')
        try:
            old = int((directory / 'pid').read_text())
            if old != os.getpid():
                os.kill(old, 0)
                raise Refused('another signed-pair watchdog is active')
        except ProcessLookupError:
            pass
    temporary = directory / ('pid.' + str(os.getpid()))
    temporary.write_text(str(os.getpid()))
    os.replace(temporary, directory / 'pid')
    return directory


def release_watchdog_lock(directory, tx):
    require((directory / 'signed-pair-owner').read_text() == tx
            and (directory / 'pid').read_text() == str(os.getpid()), 'watchdog lock owner changed')
    (directory / 'pid').unlink()
    (directory / 'signed-pair-owner').unlink()
    directory.rmdir()



def status_unstaged(encoded):
    j = json.loads(base64.b64decode(encoded, validate=True))
    validate(j)
    host(j)
    ready = False
    try:
        stage = Path(j['studio']['journal_path']).parent
        require(not stage.exists() and not Path(j['studio']['remote_actor_path']).exists()
                and not (Path.home() / '.macprovider-canary-swap.lock').exists(), 'partial or foreign Studio transaction')
        signed_binary(Path(j['studio']['install_dir']) / 'macprovider-cli', j['prior'])
        policy(j, j['prior'])
        readiness(status(j), j['prior'], j['provider_id_sha256'], False)
        process_id(j)
        scoped_policy(j, 'prior')
        ready = True
    except (Refused, KeyError, OSError, ValueError, subprocess.SubprocessError):
        pass
    binding = {k: j[k] for k in ('transaction_id', 'prior', 'target', 'coordinator_url')}
    print(json.dumps({'transaction_id': j['transaction_id'], 'target_release_id': j['target']['catalog_release_id'],
                      'phase': 'prior_unchanged' if ready else 'unstaged_unverified', 'terminal_ready': ready,
                      'identity_binding_sha256': hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}))


def fence_action(j, directory):
    owner_path = directory / 'studio-action-owner.json'
    if not owner_path.exists():
        return
    owner = json.loads(read_private(owner_path))
    require(owner['transaction_id'] == j['transaction_id'], 'action owner transaction mismatch')
    pid = owner['pid']
    if pid == os.getpid():
        return
    started = run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], check=False).stdout.strip()
    if not started:
        return
    command = run(['/bin/ps', '-p', str(pid), '-o', 'command='], check=False).stdout
    uid = run(['/bin/ps', '-p', str(pid), '-o', 'uid='], check=False).stdout.strip()
    if not (started == owner['start'] and uid == str(os.getuid())
            and 'python3' in command and j['studio']['journal_path'] in command):
        return  # Reused/unrelated PID is never a recovery kill target.
    os.kill(pid, 9)


def main(action, journal_path, script):
    if action == 'status-unstaged':
        return status_unstaged(journal_path)
    journal_path = Path(journal_path)
    raw = read_private(journal_path)
    j = json.loads(raw)
    validate(j)
    host(j)
    directory = journal_path.parent
    info = directory.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o077, 'journal directory must be private')
    state_path = directory / 'studio-state.json'
    lock = (os.open(os.devnull, os.O_RDONLY) if action == 'status' else
            os.open(directory / 'studio-action.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600))
    watchdog_directory = None
    if action == 'watchdog':
        watchdog_directory = watchdog_lock(j)
        put(directory / 'studio-watchdog-ready.json', {'transaction_id': j['transaction_id'], 'pid': os.getpid()})
        while time.time() < j['deadline_epoch']:
            if state_path.exists() and json.loads(read_private(state_path)).get('phase') in ('committed', 'restored'):
                release_watchdog_lock(watchdog_directory, j['transaction_id'])
                return
            time.sleep(1)
        fence_action(j, directory)
        action = 'rollback'
    with os.fdopen(lock, 'r' if action == 'status' else 'w') as guard:
        if action != 'status':
            fcntl.flock(guard, fcntl.LOCK_EX)
        if action != 'status':
            put(directory / 'studio-action-owner.json', {'transaction_id': j['transaction_id'], 'pid': os.getpid(),
                'start': run(['/bin/ps', '-p', str(os.getpid()), '-o', 'lstart=']).stdout.strip()})
        state = json.loads(read_private(state_path)) if state_path.exists() else {}
        if action not in ('status', 'rollback') and not (action == 'commit' and state.get('phase') == 'committed'):
            require(time.time() < j['deadline_epoch'], 'transaction work deadline expired')
        require(not state or state['journal_sha256'] == hashlib.sha256(raw).hexdigest(), 'journal changed after arm')
        def save(phase, **extra):
            state.update(extra)
            state.update(phase=phase, transaction_id=j['transaction_id'],
                         journal_sha256=hashlib.sha256(raw).hexdigest())
            put(state_path, state)
        if action == 'status':
            ready = False
            phase = state.get('phase', 'staged')
            try:
                role = 'target' if phase == 'committed' else 'prior'
                if phase == 'staged':
                    # Arm records 'armed' before its first Studio change, so a
                    # staged journal with no watchdog left the incumbent intact.
                    require(not (directory / 'studio-watchdog-ready.json').exists()
                            and run(['/bin/launchctl', 'print', 'gui/%d/tech.malibu.signed-pair.%s'
                                     % (os.getuid(), j['transaction_id'])], check=False).returncode != 0,
                            'staged transaction has a watchdog')
                    phase = 'prior_unchanged'
                require(phase in ('committed', 'restored', 'prior_unchanged'), 'transaction not terminal')
                identity = j[role]
                signed_binary(Path(j['studio']['install_dir']) / 'macprovider-cli', identity)
                policy(j, identity)
                readiness(status(j), identity, j['provider_id_sha256'], False)
                process_id(j)
                if role == 'target':
                    j['capture_started_epoch'] = state['capture_started_epoch']
                    j['capture_header_sha256'] = state['capture_header_sha256']
                    capture(j, j['capture_started_epoch'])
                    scoped_policy(j)
                ready = True
            except (Refused, KeyError, OSError, ValueError, subprocess.SubprocessError):
                pass
            binding = {k: j[k] for k in ('transaction_id', 'prior', 'target', 'coordinator_url')}
            print(json.dumps({'transaction_id': j['transaction_id'], 'target_release_id': j['target']['catalog_release_id'],
                              'phase': phase, 'terminal_ready': ready,
                              'identity_binding_sha256': hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}))
            return
        if action == 'commit' and state.get('phase') == 'committed':
            policy(j, j['target'])
            signed_binary(Path(j['studio']['install_dir']) / 'macprovider-cli', j['target'])
            readiness(status(j), j['target'], j['provider_id_sha256'], False)
            return
        if action == 'preflight':
            require(not state, 'transaction already exists')
            readiness(status(j), j['prior'], j['provider_id_sha256'], False)
            policy(j, j['prior'])
            require(not Path(j['studio']['capture_dir']).exists(), 'capture directory reused')
            return
        if action == 'arm':
            require(not state and time.time() < j['deadline_epoch'] <= time.time() + 3600, 'arm deadline')
            require(receipt(j)['policy_phase'] == 'armed', 'independent Pearl guardian not armed')
            launched = plistlib.loads(Path(j['studio']['launchd_plist']).read_bytes())
            args = launched.get('ProgramArguments', [])
            require(launched.get('Label') == j['studio']['launchd_label']
                    and args and os.path.realpath(args[0]) == os.path.realpath(str(Path(j['studio']['install_dir']) / 'macprovider-cli'))
                    and j['studio']['config_path'] in args, 'provider launch identity mismatch')
            process_id(j)
            shutil.copytree(j['studio']['install_dir'], directory / 'prior-payload', symlinks=True)
            shutil.copy2(j['studio']['config_path'], directory / 'prior-config')
            shutil.copy2(j['studio']['launchd_plist'], directory / 'prior-launchd.plist')
            signed_binary(directory / 'prior-payload/macprovider-cli', j['prior'])
            save('armed', prior_config_sha256=sha(directory / 'prior-config'),
                 prior_plist_sha256=sha(directory / 'prior-launchd.plist'))
            label = 'tech.malibu.signed-pair.' + j['transaction_id']
            plist = {'Label': label, 'ProgramArguments': ['/bin/bash', script, 'signed-pair-engine', 'watchdog', str(journal_path)],
                     'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False},
                     'StandardOutPath': str(directory / 'studio-watchdog.log'),
                     'StandardErrorPath': str(directory / 'studio-watchdog.log')}
            with open(directory / 'studio-watchdog.plist', 'wb') as target:
                plistlib.dump(plist, target)
            os.chmod(directory / 'studio-watchdog.plist', 0o600)
            run(['/bin/launchctl', 'bootstrap', 'gui/%d' % os.getuid(), str(directory / 'studio-watchdog.plist')])
            limit = time.monotonic() + 15
            while not (directory / 'studio-watchdog-ready.json').exists():
                require(time.monotonic() < limit, 'independent watchdog did not arm')
                time.sleep(.1)
            return
        require(state, 'transaction not armed')
        if action == 'prepare':
            require(state['phase'] == 'armed', 'prepare phase')
            policy(j, j['prior'])
            readiness(status(j), j['prior'], j['provider_id_sha256'], False)
            save('pausing')
            control(j, 'pause_request')
            while time.time() < j['deadline_epoch']:
                body = status(j)
                if paused(body) and body.get('requests_in_flight') == 0:
                    break
                time.sleep(1)
            else:
                raise Refused('drain deadline')
            job(j, 'stop', watchdog=True)
            job(j, 'stop')
            save('prepared', pause_proven=True)
        elif action == 'install':
            require(state['phase'] == 'prepared', 'install phase')
            policy(j, j['target'])
            scoped_policy(j)
            compatible_pair(j, j['target']['baked_catalog_release_id'])
            target = directory / 'target-payload'
            if not target.exists():
                extract(j, target)
            signed_binary(target / 'macprovider-cli', j['target'])
            save('installing')
            install = Path(j['studio']['install_dir'])
            for name in ('macprovider-cli', 'mlx.metallib', 'compatibility-set.json',
                         'THIRD-PARTY-NOTICES.txt', 'catalog-release', 'compatibility-set-local',
                         'mlx-swift_Cmlx.bundle', 'swift-nio_NIOPosix.bundle'):
                destination = install / name
                if destination.is_dir():
                    shutil.rmtree(destination)
                elif destination.exists() or destination.is_symlink():
                    destination.unlink()
                source = target / name
                if source.is_dir():
                    shutil.copytree(source, destination)
                elif source.exists():
                    shutil.copy2(source, destination)
            capture_dir = Path(j['studio']['capture_dir'])
            capture_dir.mkdir(mode=0o700)
            plist_path = Path(j['studio']['launchd_plist'])
            plist = plistlib.loads(plist_path.read_bytes())
            env = plist.setdefault('EnvironmentVariables', {})
            env.update(MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR=str(capture_dir),
                       MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_SCHEMA='v2',
                       MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_MAX_RECORDS='1000',
                       MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_MAX_BYTES='10485760')
            with open(plist_path, 'wb') as output:
                plistlib.dump(plist, output)
            require(sha(j['studio']['config_path']) == state['prior_config_sha256'], 'provider config drift')
            signed_binary(install / 'macprovider-cli', j['target'])
            # Native operator pause is persisted across provider restart.
            compatible_pair(j, j['target']['baked_catalog_release_id'])
            policy(j, j['target'])
            save('installed', capture_started_epoch=time.time())
            job(j, 'start')
        elif action in ('ready', 'resume', 'prepare-commit'):
            allowed = {'ready': 'installed', 'resume': 'ready', 'prepare-commit': 'resumed'}
            require(state['phase'] == allowed[action], 'readiness phase')
            j['capture_started_epoch'] = state['capture_started_epoch']
            if action != 'ready':
                j['capture_header_sha256'] = state['capture_header_sha256']
            if action == 'resume':
                readiness(status(j), j['target'], j['provider_id_sha256'], True)
                capture(j, j['capture_started_epoch'])
                policy(j, j['target'])
                control(j, 'resume_request')
            pid = stable(j, 'target', action == 'ready', j['deadline_epoch'], True)
            proof = capture(j, j['capture_started_epoch'], require_zero=action == 'ready')
            save({'ready': 'ready', 'resume': 'resumed', 'prepare-commit': 'commit_prepared'}[action], process_identity=pid,
                 capture_header_sha256=proof['header_sha256'], capture_file_name=proof['file_name'])
        elif action == 'commit':
            require(state['phase'] == 'commit_prepared', 'commit phase')
            committed_receipt(j, receipt(j))
            policy(j, j['target'])
            readiness(status(j), j['target'], j['provider_id_sha256'], False)
            require(tuple(state['process_identity']) == process_id(j), 'target process changed')
            job(j, 'start', watchdog=True)
            save('committed')
        elif action == 'rollback':
            if state['phase'] in ('committed', 'restored'):
                if watchdog_directory is not None:
                    release_watchdog_lock(watchdog_directory, j['transaction_id'])
                return
            recovery_deadline = time.time() + j['recovery_seconds']
            # An authoritative remote commit wins even when the controller
            # died before relaying it. No local file can invent this decision.
            try:
                decision = receipt(j)
            except (Refused, OSError, ValueError, subprocess.SubprocessError):
                decision = {}
            if decision.get('policy_phase') == 'target_committed':
                try:
                    committed_receipt(j, decision)
                    require(state['phase'] in ('ready', 'resumed', 'commit_prepared'), 'target was never qualified')
                    policy(j, j['target'])
                    j['capture_started_epoch'] = state['capture_started_epoch']
                    j['capture_header_sha256'] = state['capture_header_sha256']
                    is_paused = paused(status(j))
                    stable(j, 'target', is_paused, recovery_deadline, True)
                    if is_paused:
                        policy(j, j['target'])
                        control(j, 'resume_request')
                        stable(j, 'target', False, recovery_deadline, True)
                    job(j, 'start', watchdog=True)
                    save('committed', recovery='authoritative_remote_target_commit')
                    if watchdog_directory is not None:
                        release_watchdog_lock(watchdog_directory, j['transaction_id'])
                    return
                except (Refused, OSError, ValueError, subprocess.SubprocessError):
                    job(j, 'stop', watchdog=True)
                    job(j, 'stop')
                    save('blocked', reason='committed_target_unhealthy_provider_stopped')
                    raise
            # Fence all target work before waiting for Pearl recovery. Do not
            # start the old executable against CURRENT target policy.
            pause_proven = state.get('pause_proven', False)
            try:
                control(j, 'pause_request')
                pause_proven = pause_proven or paused(status(j))
            except (Refused, OSError, ValueError):
                pass
            job(j, 'stop', watchdog=True)
            job(j, 'stop')
            save('awaiting_prior_policy', pause_proven=pause_proven)
            require(pause_proven, 'persisted operator pause cannot be proven; provider remains stopped')
            end = recovery_deadline
            while True:
                try:
                    decision = receipt(j)
                    require(decision.get('policy_phase') == 'prior_restored'
                            and decision.get('prior_release_id') == j['prior']['catalog_release_id']
                            and all(decision.get('prior_feed_sha256', {}).get(k) == v for k, v in j['prior']['feed_sha256'].items()), 'prior restore receipt mismatch')
                    policy(j, j['prior'])
                    break
                except (Refused, OSError, ValueError, subprocess.SubprocessError):
                    if time.time() >= end:
                        save('blocked', reason='prior_public_policy_not_restored_provider_stopped')
                        raise Refused('prior policy not restored; provider isolated; journal retained')
                    time.sleep(2)
            signed_binary(directory / 'prior-payload/macprovider-cli', j['prior'])
            require(sha(directory / 'prior-config') == state['prior_config_sha256']
                    and sha(directory / 'prior-launchd.plist') == state['prior_plist_sha256'], 'prior config changed')
            install = Path(j['studio']['install_dir'])
            if install.exists():
                failed = directory / ('failed-payload-' + str(int(time.time())))
                shutil.move(str(install), failed)
            shutil.copytree(directory / 'prior-payload', install, symlinks=True)
            shutil.copy2(directory / 'prior-config', j['studio']['config_path'])
            shutil.copy2(directory / 'prior-launchd.plist', j['studio']['launchd_plist'])
            policy(j, j['prior'])
            job(j, 'start')
            # The incumbent pause survives restart; prove the whole old tuple
            # before resume, and retain identical PID throughout stable proof.
            stable(j, 'prior', True, recovery_deadline)
            policy(j, j['prior'])
            control(j, 'resume_request')
            stable(j, 'prior', False, recovery_deadline)
            job(j, 'start', watchdog=True)
            save('restored')
            if watchdog_directory is not None:
                release_watchdog_lock(watchdog_directory, j['transaction_id'])
        else:
            raise Refused('unknown signed-pair action')


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 4, 'signed-pair invocation')
        main(sys.argv[1], sys.argv[2], sys.argv[3])
    except (Refused, KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        # Do not print URLs, commands, configuration or arbitrary error strings.
        # Refused reasons are this actor's fixed literals, so they are printed.
        print('signed-pair refused: ' + type(error).__name__
              + (': ' + str(error) if type(error) is Refused else ''), file=sys.stderr)
        sys.exit(6)
SIGNED_PAIR_PY
  exit $?
fi

MODE=swap
case "${1:-}" in remove-owner-pin|restore-owner-pin) MODE="$1"; shift ;; esac
if [ "$MODE" = swap ]; then
  TARBALL="$1"
  TARBALL_SHA="$2"
  VERSION="$3"
  INSTALL_DIR="${4:-$HOME/macprovider}"
  LABEL="${5:-live.malibu.provider}"
  SOCKET="${6:-}"
  PORT="$7"
  STATUS_TIMEOUT_S="$8"
  READY_TIMEOUT_S="$9"
  DRAIN_TIMEOUT_S="${10}"
  STABLE_S="${11}"
  POLL_S="${12:-5}"
  RESULT_FILE="${13:-$(dirname "$TARBALL")/result}"
  AIR_PROVIDER_SHA="${14:-}"
  AIR_CONFIG="${15:-}"
  AIR_OLD_BINARY_SHA="${16:-}"
  AIR_ACTION="${17:-}"
  AIR_CONFIG_SHA="${18:-}"
  CONFIG="" JOURNAL="" HELPER="" EXPECTED_BINARY_SHA="" EXPECTED_PROVIDER_SHA="" EXPECTED_MODEL="" EXPECTED_POLICY_SHA=""
  EXPECTED_POLICY_RELEASE="" EXPECTED_POLICY_TUPLE="" EXPECTED_TEAM_ID="" EXPECTED_SIGNING_IDENTIFIER="" EXPECTED_CDHASH=""
else
  VERSION="$1"
  INSTALL_DIR="$2"
  LABEL="${3:-live.malibu.provider}"
  SOCKET="${4:-}"
  PORT="$5"
  STATUS_TIMEOUT_S="$6"
  READY_TIMEOUT_S="$7"
  DRAIN_TIMEOUT_S="$8"
  STABLE_S="$9"
  POLL_S="${10:-5}"
  RESULT_FILE="${11}"
  CONFIG="${12}"
  JOURNAL="${13}"
  HELPER="${14}"
  EXPECTED_BINARY_SHA="${15}"
  EXPECTED_PROVIDER_SHA="${16}"
  EXPECTED_MODEL="${17}"
  EXPECTED_POLICY_SHA="${18}"
  EXPECTED_POLICY_RELEASE="${19}"
  EXPECTED_POLICY_TUPLE="${20}"
  EXPECTED_TEAM_ID="${21}"
  EXPECTED_SIGNING_IDENTIFIER="${22}"
  EXPECTED_CDHASH="${23}"
  TARBALL="" TARBALL_SHA=""
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DOMAIN="gui/$(id -u)"
LA_DIR="${CANARY_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
WATCHDOG_LABEL="$LABEL-watchdog"
[ -n "$SOCKET" ] || SOCKET="$(getconf DARWIN_USER_TEMP_DIR)macprovider-cli/ctl.sock"
BACKUP="$INSTALL_DIR.pre-$VERSION-$TS"
[ "$MODE" = swap ] || BACKUP="$CONFIG.bak-owner-pin-$TS"
FAILED_DIR="$INSTALL_DIR.failed-$VERSION-$TS"
if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ]; then FAILED_DIR="$FAILED_DIR-$$"; fi
STAGE="$(dirname "$RESULT_FILE")/payload"
LOCK_DIR="$HOME/.macprovider-canary-swap.lock"
MANAGED_FILES="macprovider-cli mlx.metallib compatibility-set.json THIRD-PARTY-NOTICES.txt"
MANAGED_DIRS="catalog-release compatibility-set-local mlx-swift_Cmlx.bundle swift-nio_NIOPosix.bundle"

say() { printf 'canary-window[%s][%s]: %s\n' "$(date -u +%H:%M:%SZ)" "$MODE" "$*" >&2; }
now() { date +%s; }

status_json() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/v1/status" 2>/dev/null; }

# status_field BODY PATH: dotted path into the status JSON; empty when absent
# or when BODY is not a JSON object.
status_field() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    if not isinstance(v, dict):
        raise ValueError
    for part in sys.argv[1].split("."):
        v = v.get(part) if isinstance(v, dict) else None
except Exception:
    v = None
print("" if v is None else (json.dumps(v) if isinstance(v, bool) else v))' "$2"
}

status_field_sha() {
  printf '%s' "$(status_field "$1" "$2")" | shasum -a 256 | awk '{print $1}'
}

# serving BODY VERSION: the provider runs VERSION with its model loaded and
# serves buyers.
serving() {
  [ "$(status_field "$1" binary_version)" = "$2" ] &&
    [ "$(status_field "$1" model_loaded)" = true ] &&
    [ "$(status_field "$1" network_state)" = buyer_serving ]
}

paused() {
  [ "$(status_field "$1" lifecycle.state)" = paused_by_operator ] ||
    [ "$(status_field "$1" lifecycle.operator_paused)" = true ]
}

control() {
  python3 - "$SOCKET" "$1" <<'PY'
import json, socket, sys
path, frame = sys.argv[1], sys.argv[2]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(path)
    s.sendall((json.dumps({"type": frame}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    ack = json.loads(buf.split(b"\n", 1)[0] or b"{}")
except Exception as exc:
    print("control %s failed: %s" % (frame, exc), file=sys.stderr)
    sys.exit(1)
print(json.dumps(ack), file=sys.stderr)
sys.exit(0 if ack.get("accepted") is True else 1)
PY
}

job_pid() {
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

verify_binary_identity() {
  local binary="$INSTALL_DIR/macprovider-cli" details team identifier cdhash
  python3 - "$binary" <<'PY' || return 1
import os, stat, sys
path = sys.argv[1]
try:
    info = os.lstat(path)
except OSError:
    sys.exit(1)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.getuid()
    or info.st_nlink != 1
    or os.path.realpath(path) != path
):
    sys.exit(1)
PY
  [ "$(shasum -a 256 "$binary" | awk '{print $1}')" = "$EXPECTED_BINARY_SHA" ] || return 1
  codesign --verify --strict --verbose=2 "$binary" >/dev/null 2>&1 || return 1
  details="$(codesign -d --arch arm64 -vvv "$binary" 2>&1)" || return 1
  team="$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
  identifier="$(printf '%s\n' "$details" | awk -F= '$1 == "Identifier" {print $2; exit}')"
  cdhash="$(printf '%s\n' "$details" | awk -F= '$1 == "CDHash" {print tolower($2); exit}')"
  [ "$team" = "$EXPECTED_TEAM_ID" ] &&
    [ "$identifier" = "$EXPECTED_SIGNING_IDENTIFIER" ] &&
    [ "$cdhash" = "$EXPECTED_CDHASH" ]
}

verify_launch_plist() {
  python3 - "$LA_DIR/$LABEL.plist" "$INSTALL_DIR/macprovider-cli" "$CONFIG" "$LABEL" <<'PY'
import os, plistlib, stat, sys
path, binary, config, label = sys.argv[1:]
try:
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or before.st_size > 64*1024:
        sys.exit(1)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(fd)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        sys.exit(1)
    data = os.read(fd, 64*1024 + 1)
    os.close(fd)
    if len(data) != before.st_size or len(data) > 64*1024:
        sys.exit(1)
    value = plistlib.loads(data)
except Exception:
    sys.exit(1)
args, program = value.get("ProgramArguments"), value.get("Program")
expected = os.path.realpath(binary)
config_flags = [i for i, item in enumerate(args or []) if item == "--config"]
if (
    value.get("Label") != label
    or not isinstance(args, list)
    or len(args) != 4
    or not all(isinstance(item, str) for item in args)
    or os.path.realpath(args[0]) != expected
    or (program is not None and (not isinstance(program, str) or os.path.realpath(program) != expected))
    or args[1] != "serve"
    or len(config_flags) != 1
    or config_flags[0] + 1 >= len(args)
    or not os.path.isabs(args[config_flags[0] + 1])
    or os.path.realpath(args[config_flags[0] + 1]) != os.path.realpath(config)
):
    sys.exit(1)
PY
}

# Prints the kernel process start in microseconds after binding launchd's PID
# to the exact canonical executable, uid and real uid. This mirrors the
# released installer's libproc lifecycle-lease identity check.
verify_job_process() {
  local expected_pid="$1" live_pid
  verify_launch_plist || return 1
  live_pid="$(job_pid)"
  [ "$live_pid" = "$expected_pid" ] || return 1
  python3 - "$expected_pid" "$INSTALL_DIR/macprovider-cli" "$(id -u)" <<'PY'
import ctypes, os, sys
class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags",ctypes.c_uint32),("pbi_status",ctypes.c_uint32),("pbi_xstatus",ctypes.c_uint32),
        ("pbi_pid",ctypes.c_uint32),("pbi_ppid",ctypes.c_uint32),("pbi_uid",ctypes.c_uint32),
        ("pbi_gid",ctypes.c_uint32),("pbi_ruid",ctypes.c_uint32),("pbi_rgid",ctypes.c_uint32),
        ("pbi_svuid",ctypes.c_uint32),("pbi_svgid",ctypes.c_uint32),("rfu_1",ctypes.c_uint32),
        ("pbi_comm",ctypes.c_char*16),("pbi_name",ctypes.c_char*32),("pbi_nfiles",ctypes.c_uint32),
        ("pbi_pgid",ctypes.c_uint32),("pbi_pjobc",ctypes.c_uint32),("pbi_e_tdev",ctypes.c_uint32),
        ("pbi_e_tpgid",ctypes.c_uint32),("pbi_nice",ctypes.c_int32),
        ("pbi_start_tvsec",ctypes.c_uint64),("pbi_start_tvusec",ctypes.c_uint64),
    ]
pid, binary, owner = int(sys.argv[1]), os.path.realpath(sys.argv[2]), int(sys.argv[3])
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
proc_pidinfo = libproc.proc_pidinfo
proc_pidinfo.argtypes = [ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
proc_pidinfo.restype = ctypes.c_int
info = ProcBsdInfo()
if proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info)) != ctypes.sizeof(info): sys.exit(1)
buf = ctypes.create_string_buffer(4096)
proc_pidpath = libproc.proc_pidpath
proc_pidpath.argtypes = [ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
proc_pidpath.restype = ctypes.c_int
if proc_pidpath(pid,buf,ctypes.sizeof(buf)) <= 0: sys.exit(1)
start = int(info.pbi_start_tvsec)*1000000 + int(info.pbi_start_tvusec)
path = os.path.realpath(buf.value.decode("utf-8","surrogateescape"))
if start <= 0 or int(info.pbi_uid) != owner or int(info.pbi_ruid) != owner or path != binary: sys.exit(1)
print(start)
PY
}

stop_jobs() {
  launchctl bootout "$DOMAIN/$WATCHDOG_LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  for _ in $(seq 1 60); do
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 &&
       ! launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  say "provider or watchdog job still loaded after 60s bootout"
  return 1
}

# start_jobs: bootstrap the provider and, unless "provider" is passed, its
# watchdog (when installed); fails when a requested job is not loaded
# afterwards. The swap and the rollback start the provider alone: an installed
# watchdog armed for this boot would treat the new process's model-load
# window as a failed /v1/health and kickstart it, which reads as a crash loop.
# The watchdog comes back only once the provider is buyer_serving.
start_jobs() {
  local job ok jobs="$LABEL $WATCHDOG_LABEL"
  [ "${1:-}" = provider ] && jobs="$LABEL"
  for job in $jobs; do
    [ -f "$LA_DIR/$job.plist" ] || continue
    ok=0
    for _ in 1 2 3 4 5; do
      if launchctl bootstrap "$DOMAIN" "$LA_DIR/$job.plist" 2>/dev/null ||
         launchctl print "$DOMAIN/$job" >/dev/null 2>&1; then
        ok=1
        break
      fi
      sleep 2
    done
    [ "$ok" = 1 ] || { say "launchctl bootstrap of $job failed"; return 1; }
  done
}

# start_watchdog: bring the installed watchdog back once the provider serves.
# A failure is reported, not fatal: the provider is already serving.
start_watchdog() {
  [ -f "$LA_DIR/$WATCHDOG_LABEL.plist" ] || return 0
  launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1 && return 0
  local _
  for _ in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$LA_DIR/$WATCHDOG_LABEL.plist" 2>/dev/null ||
       launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1; then
      say "watchdog $WATCHDOG_LABEL restarted"
      return 0
    fi
    sleep 2
  done
  say "!!! watchdog $WATCHDOG_LABEL did not start; bootstrap it by hand"
}

require_watchdog() {
  [ -f "$LA_DIR/$WATCHDOG_LABEL.plist" ] || return 0
  start_watchdog
  launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1 || {
    say "!!! watchdog $WATCHDOG_LABEL is not loaded"
    return 1
  }
}

# wait_serving VERSION: resume (the operator pause outlives a restart) until
# VERSION is buyer_serving and stays so for STABLE_S.
wait_serving() {
  local deadline body ready_at=""
  deadline=$(( $(now) + READY_TIMEOUT_S ))
  while [ "$(now)" -lt "$deadline" ]; do
    body="$(status_json || true)"
    if [ -n "$body" ] && [ "$(status_field "$body" model_loaded)" = true ] && paused "$body"; then
      if [ "$MODE" != swap ]; then
        verify_binary_identity && verify_job_process "$(job_pid)" >/dev/null || return 1
      fi
      control resume_request || true
    fi
    if [ -n "$body" ] && serving "$body" "$1"; then
      [ -n "$ready_at" ] || ready_at="$(now)"
      [ $(( $(now) - ready_at )) -lt "$STABLE_S" ] || return 0
    else
      ready_at=""
    fi
    sleep "$POLL_S"
  done
  return 1
}

PAUSED=0
SWAPPED=0
CONFIG_ARMED=0
FINISHED=0
LOCKED=0
OLD_VERSION=""

# watchdog_note: on an operator-recovery exit the watchdog is deliberately
# left booted out (it would kick a half-restored provider); say so.
watchdog_note() {
  [ -f "$LA_DIR/$WATCHDOG_LABEL.plist" ] || return 0
  launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1 && return 0
  say "!!! watchdog $WATCHDOG_LABEL left unloaded; bootstrap it once the provider is buyer_serving: launchctl bootstrap $DOMAIN '$LA_DIR/$WATCHDOG_LABEL.plist'"
}

# finish RC: the single exit; records RC for the operator side.
finish() {
  FINISHED=1
  trap - EXIT
  [ "$1" != 6 ] || watchdog_note || true
  printf '%s\n' "$1" >"$RESULT_FILE.tmp" && mv "$RESULT_FILE.tmp" "$RESULT_FILE"
  if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ] && [ "$1" = 5 ]; then
    # Cancellation/completion is durable before releasing the same host lock
    # a delayed original worker must acquire before touching the provider.
    python3 - "$(dirname "$RESULT_FILE")/result.restored" <<'PY' || exit 6
import os, sys, tempfile
path=sys.argv[1]
fd, temporary=tempfile.mkstemp(dir=os.path.dirname(path),prefix=".air-terminal-")
with os.fdopen(fd,"w") as stream:
    stream.write("5\n"); stream.flush(); os.fsync(stream.fileno())
os.replace(temporary,path)
directory=os.open(os.path.dirname(path),os.O_RDONLY)
try: os.fsync(directory)
finally: os.close(directory)
PY
  fi
  if [ "$LOCKED" = 1 ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  exit "$1"
}

restore_backup() {
  if [ "$MODE" != swap ]; then
    restore_config "$1"
  fi
  FINISHED=1
  say "ROLLBACK: restoring $BACKUP ($1)"
  if [ -n "$AIR_PROVIDER_SHA" ]; then
    python3 - "$(dirname "$RESULT_FILE")/result.recovery.json" <<'PY' || finish 6
import json, os, sys, tempfile
path=sys.argv[1]
with open(path) as stream: record=json.load(stream)
record["phase"]="restoring"
fd, temporary=tempfile.mkstemp(dir=os.path.dirname(path), prefix=".air-restore-")
with os.fdopen(fd,"w") as stream:
    json.dump(record,stream); stream.flush(); os.fsync(stream.fileno())
os.replace(temporary,path)
directory=os.open(os.path.dirname(path),os.O_RDONLY)
try: os.fsync(directory)
finally: os.close(directory)
PY
  fi
  stop_jobs || { say "!!! rollback could not stop the candidate job; restore $BACKUP into $INSTALL_DIR by hand"; finish 6; }
  if [ -e "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$FAILED_DIR" || { say "!!! could not move the candidate payload aside; restore $BACKUP by hand"; finish 6; }
  elif [ -z "$AIR_PROVIDER_SHA" ]; then
    finish 6
  fi
  cp -Rp "$BACKUP" "$INSTALL_DIR" || { say "!!! could not copy $BACKUP back to $INSTALL_DIR; do it by hand"; finish 6; }
  start_jobs provider || { say "!!! restored $BACKUP but the provider job did not start; bootstrap $LABEL by hand"; finish 6; }
  if [ -n "$AIR_PROVIDER_SHA" ]; then
    # The signed incumbent was disconnected before recovery. Restoring that
    # exact zero-work state is a successful rollback, not a buyer-serving claim.
    local air_deadline air_body air_pid air_start air_since
    air_deadline=$(( $(now) + READY_TIMEOUT_S ))
    while :; do
      air_pid="$(job_pid)"
      if [ -n "$air_pid" ] && air_start="$(verify_job_process "$air_pid")"; then break; fi
      [ "$(now)" -lt "$air_deadline" ] || finish 6
      sleep "$POLL_S"
    done
    air_since=0
    while :; do
      [ "$(job_pid)" = "$air_pid" ] && [ "$(verify_job_process "$air_pid")" = "$air_start" ] || finish 6
      air_body="$(status_json || true)"
      if [ "$(status_field "$air_body" binary_version)" = "$OLD_VERSION" ] &&
         [ "$(status_field_sha "$air_body" provider_id)" = "$AIR_PROVIDER_SHA" ] &&
         [ "$(status_field "$air_body" requests_in_flight)" = 0 ] &&
         [ "$(status_field "$air_body" lifecycle.operator_paused)" != true ] &&
         [ "$(shasum -a 256 "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')" = "$AIR_OLD_BINARY_SHA" ]; then
        [ "$air_since" != 0 ] || air_since="$(now)"
        if [ $(( $(now) - air_since )) -lt "$STABLE_S" ]; then sleep "$POLL_S"; continue; fi
        codesign --verify --strict "$INSTALL_DIR/macprovider-cli" >/dev/null 2>&1 || finish 6
        require_watchdog || finish 6
        say "ROLLBACK done: exact signed Air incumbent restored; buyer readiness is not claimed"
        finish 5
      fi
      air_since=0
      [ "$(now)" -lt "$air_deadline" ] || finish 6
      sleep "$POLL_S"
    done
  elif ! wait_serving "$OLD_VERSION"; then
    say "!!! restored $BACKUP but $OLD_VERSION is not buyer_serving within ${READY_TIMEOUT_S}s; check the provider and send resume_request on $SOCKET"
    finish 6
  fi
  start_watchdog
  say "ROLLBACK done: $OLD_VERSION buyer_serving again; failed payload kept at $FAILED_DIR"
  finish 5
}

config_postconditions() {
  [ "$(status_field "$1" binary_version)" = "$VERSION" ] &&
    [ "$(status_field_sha "$1" provider_id)" = "$EXPECTED_PROVIDER_SHA" ] &&
    [ "$(status_field "$1" model)" = "$EXPECTED_MODEL" ] &&
    [ "$(status_field "$1" capacity.max_concurrency)" = 4 ] &&
    [ "$(status_field "$1" continuous_batching.active)" = true ] &&
    [ "$(status_field "$1" continuous_batching.policy.load_status)" = live_verified ] &&
    [ "$(status_field "$1" continuous_batching.policy.authorized)" = true ] &&
    [ "$(status_field "$1" continuous_batching.policy.policy_sha256)" = "$EXPECTED_POLICY_SHA" ] &&
    [ "$(status_field "$1" continuous_batching.policy.release_id)" = "$EXPECTED_POLICY_RELEASE" ] &&
    [ "$(status_field "$1" continuous_batching.policy.tuple_sha256)" = "$EXPECTED_POLICY_TUPLE" ] &&
    [ "$(status_field "$1" continuous_batching.self_check.served_slots)" = 4 ] &&
    [ "$(status_field "$1" continuous_batching.scheduler.slots_total)" = 4 ] &&
    [ "$(status_field "$1" coordinator.connected)" = true ] &&
    [ "$(status_field "$1" lifecycle.operator_paused)" != true ]
}

restore_config() {
  local result_code="${2:-5}" recovered_pid recovered_start body
  FINISHED=1
  say "ROLLBACK: restoring the 4/owner pin ($1)"
  stop_jobs || { say "!!! rollback could not stop the provider; journal retained"; finish 6; }
  python3 "$HELPER" restore --config "$CONFIG" --journal "$JOURNAL" || {
    say "!!! scoped pin restore refused; journal and protected backup retained"; finish 6;
  }
  if ! verify_binary_identity || ! verify_launch_plist; then
    say "!!! pin restored but signed executable identity is not exact; provider and watchdog remain stopped; journal retained"
    finish 6
  fi
  start_jobs provider || { say "!!! pin restored but provider did not start; journal retained"; finish 6; }
  recovered_pid="$(job_pid)"
  recovered_start="$(verify_job_process "$recovered_pid")" || {
    say "!!! pin restored but launched process is not the exact signed executable; journal retained"; stop_jobs || true; finish 6;
  }
  if ! wait_serving "$VERSION"; then
    say "!!! pin restored but $VERSION is not buyer_serving within ${READY_TIMEOUT_S}s; journal retained"
    finish 6
  fi
  body="$(status_json || true)"
  if ! config_postconditions "$body"; then
    say "!!! pin restored but serving status does not preserve the signed four-slot tuple; journal retained"
    finish 6
  fi
  [ "$(status_field "$body" service_instance.pid)" = "$recovered_pid" ] &&
    [ "$(verify_job_process "$recovered_pid")" = "$recovered_start" ] || {
      say "!!! recovered provider process identity changed; journal retained"; finish 6;
    }
  require_watchdog || { say "!!! pin restored but watchdog is not loaded; journal retained"; finish 6; }
  python3 "$HELPER" finish --config "$CONFIG" --journal "$JOURNAL" --restored || {
    say "!!! provider recovered but restore journal could not be finalized"; finish 6;
  }
  say "ROLLBACK done: exact 4/owner pin restored and $VERSION buyer_serving"
  finish "$result_code"
}

# shellcheck disable=SC2329  # EXIT trap
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$FINISHED" = 1 ]; then
    say "!!! recovery stopped unexpectedly (exit $rc); check $INSTALL_DIR against $BACKUP"
    finish 6
  fi
  if [ "$CONFIG_ARMED" = 1 ]; then
    restore_config "unexpected exit $rc during the owner-pin transaction"
  fi
  if [ "$SWAPPED" = 1 ]; then
    restore_backup "unexpected exit $rc during the swap"
  fi
  if [ "$PAUSED" = 1 ] && ! wait_serving "$OLD_VERSION"; then
    say "!!! provider may still be PAUSED or not serving; send resume_request on $SOCKET"
    finish 6
  fi
  case "$rc" in 4) finish 4 ;; *) finish 6 ;; esac
}
trap on_exit EXIT
if [ "$MODE" = swap ]; then
  trap 'say "ignoring SIGHUP"' HUP
else
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
fi

refuse() { say "REFUSED: $*"; exit 4; }

# --- preflight: nothing touched yet -----------------------------------------
# One swap at a time on this Mac, whichever operator Mac started it. The lock
# is published with its owner pid already inside (rename of a prepared dir),
# so no run ever sees an ownerless lock; one without a readable pid is busy.
lock_refused() {
  say "REFUSED: $1"
  trap - EXIT
  printf '4\n' >"$RESULT_FILE"
  exit 4
}
publish_lock() {
  python3 - "$LOCK_DIR" "$$" <<'PY'
import os, sys, tempfile
lock, pid = sys.argv[1], sys.argv[2]
prep = tempfile.mkdtemp(prefix=os.path.basename(lock) + ".init.", dir=os.path.dirname(lock))
with open(os.path.join(prep, "pid"), "w") as f:
    f.write(pid + "\n")
try:
    os.rename(prep, lock)  # fails when lock exists and is not empty
except OSError:
    os.remove(os.path.join(prep, "pid")); os.rmdir(prep)
    sys.exit(1)
PY
}
if ! publish_lock; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  case "$holder" in ''|*[!0-9]*) lock_refused "canary-swap lock $LOCK_DIR has no owner pid; remove it by hand if no swap runs" ;; esac
  kill -0 "$holder" 2>/dev/null && lock_refused "another canary swap (pid $holder) is running on this Mac"
  # Stale owner: only the run whose rename wins may publish again.
  mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null || lock_refused "could not take over the canary-swap lock"
  rm -rf "$LOCK_DIR.stale.$$"
  publish_lock || lock_refused "could not take over the canary-swap lock"
  say "took over stale canary-swap lock (pid $holder)"
fi
LOCKED=1
if [ "$MODE" = swap ] && [ -n "$AIR_PROVIDER_SHA" ] && [ "$AIR_ACTION" = recover-air ] &&
   [ -f "$(dirname "$RESULT_FILE")/result.restored" ]; then
  refuse "this Air dispatch was cancelled/restored before its worker started"
fi

case "$INSTALL_DIR" in
  "$HOME"/?*) ;;
  *) refuse "install dir $INSTALL_DIR is not under $HOME" ;;
esac
case "$INSTALL_DIR" in *"/../"*|*/..|*"/./"*|*/.|*//*) refuse "install dir $INSTALL_DIR is not canonical" ;; esac
[ ! -L "$INSTALL_DIR" ] || refuse "install dir $INSTALL_DIR is a symlink"
if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ] && [ ! -e "$INSTALL_DIR" ]; then
  [ "$(cd "$(dirname "$INSTALL_DIR")" && pwd -P)" = "$(dirname "$INSTALL_DIR")" ] &&
    [ -O "$(dirname "$INSTALL_DIR")" ] || refuse "Air recovery parent is not canonical and owner-owned"
else
[ -d "$INSTALL_DIR" ] || refuse "install dir $INSTALL_DIR is missing"
# No symlinked ancestor below $HOME either: the physical path must be the
# lexical one, so every mv/cp/rm below stays inside it.
[ "$(cd "$INSTALL_DIR" && pwd -P)" = "$(cd "$HOME" && pwd -P)/${INSTALL_DIR#"$HOME"/}" ] ||
  refuse "install dir $INSTALL_DIR resolves through a symlink"
[ -O "$INSTALL_DIR" ] || refuse "install dir $INSTALL_DIR is not owned by $(id -un)"
fi
[ "$MODE" != swap ] || [ "$AIR_ACTION" = restore-air ] ||
  { [ ! -e "$BACKUP" ] && [ ! -e "$FAILED_DIR" ]; } || refuse "backup path $BACKUP already exists"
[ -f "$LA_DIR/$LABEL.plist" ] || refuse "missing LaunchAgent $LA_DIR/$LABEL.plist"
[ "$MODE" = swap ] || {
  case "$CONFIG" in "$HOME"/?*) ;; *) refuse "config is not under HOME" ;; esac
  case "$JOURNAL" in "$HOME"/?*) ;; *) refuse "journal is not under HOME" ;; esac
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] && [ -O "$CONFIG" ] || refuse "config is missing, symlinked, or not owner-owned"
  [ -f "$HELPER" ] && [ ! -L "$HELPER" ] && [ -O "$HELPER" ] || refuse "config helper is missing, symlinked, or not owner-owned"
}

if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ]; then
  CONFIG="$AIR_CONFIG"
  [ "$VERSION" = 1.8.260 ] && [ "$(sysctl -n hw.model)" = Mac15,12 ] &&
    [ "$(sysctl -n hw.memsize)" = 17179869184 ] || refuse "Air payload restore identity mismatch"
  verify_launch_plist || refuse "Air restore LaunchAgent mismatch"
  [ -f "$AIR_CONFIG" ] && [ ! -L "$AIR_CONFIG" ] && [ -O "$AIR_CONFIG" ] || refuse "Air baseline config is not an owned regular file"
  [ "$(shasum -a 256 "$AIR_CONFIG" | awk '{print $1}')" = "$AIR_CONFIG_SHA" ] || refuse "Air baseline config changed"
  if [ ! -e "$(dirname "$RESULT_FILE")/result.recovery.json" ]; then
    # The same host lock excludes a live worker. An unchanged authenticated
    # incumbent proves the pre-armed window; result.restored seals cancellation
    # against a delayed original worker after this lock is released.
    [ -f "$INSTALL_DIR/macprovider-cli" ] && [ ! -L "$INSTALL_DIR/macprovider-cli" ] || refuse "pre-armed Air incumbent is absent"
    [ "$(shasum -a 256 "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')" = "$AIR_OLD_BINARY_SHA" ] || refuse "pre-armed Air bytes changed"
    codesign --verify --strict "$INSTALL_DIR/macprovider-cli" >/dev/null 2>&1 || refuse "pre-armed incumbent signature invalid"
    body="$(status_json)" || refuse "pre-armed incumbent status is unavailable"
    [ "$(status_field "$body" binary_version)" = 1.8.258 ] &&
      [ "$(status_field_sha "$body" provider_id)" = "$AIR_PROVIDER_SHA" ] &&
      [ "$(status_field "$body" coordinator.connected)" = false ] &&
      [ "$(status_field "$body" requests_in_flight)" = 0 ] &&
      [ "$(status_field "$body" lifecycle.operator_paused)" != true ] || refuse "pre-armed incumbent is not the untouched Air baseline"
    verify_job_process "$(job_pid)" >/dev/null || refuse "pre-armed incumbent process mismatch"
    finish 5
  fi
  BACKUP="$(python3 - "$(dirname "$RESULT_FILE")/result.recovery.json" "$INSTALL_DIR" "$AIR_CONFIG" "$AIR_PROVIDER_SHA" "$AIR_OLD_BINARY_SHA" "$TARBALL_SHA" <<'PY'
import hashlib, json, os, pathlib, stat, sys
path, install, config, provider, binary_sha, target_sha = sys.argv[1:]
info=os.lstat(path)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077: raise SystemExit(1)
d=json.load(open(path))
if d.get("schema_version")!="macprovider.air_payload_recovery.v1" or d.get("install_dir")!=install or d.get("provider_id_sha256")!=provider or d.get("incumbent_binary_sha256")!=binary_sha or d.get("target_tarball_sha256")!=target_sha: raise SystemExit(1)
if pathlib.Path(config).is_symlink() or hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest()!=d.get("config_sha256"): raise SystemExit(1)
backup=pathlib.Path(d["backup_path"])
if backup.parent!=pathlib.Path(install).parent or not backup.name.startswith(pathlib.Path(install).name+".pre-1.8.260-") or backup.resolve()!=backup or not backup.is_dir(): raise SystemExit(1)
binary=backup/"macprovider-cli"
if binary.is_symlink() or hashlib.sha256(binary.read_bytes()).hexdigest()!=binary_sha: raise SystemExit(1)
if not pathlib.Path(install).exists() and d.get("phase")!="restoring": raise SystemExit(1)
print(backup)
PY
)" || refuse "Air recovery record/backup/config cannot be authenticated"
  codesign --verify --strict "$BACKUP/macprovider-cli" >/dev/null 2>&1 || refuse "Air recovery backup signature invalid"
  OLD_VERSION=1.8.258
  SWAPPED=1
  restore_backup "journal-first explicit Air payload recovery"
fi

if [ "$MODE" = restore-owner-pin ]; then
  [ -f "$JOURNAL" ] || refuse "no unfinished owner-pin journal to restore"
  CONFIG_ARMED=1
  restore_config "operator recovery" 0
fi

if [ "$MODE" = remove-owner-pin ]; then
  verify_binary_identity || refuse "installed CLI signed identity changed"
  verify_launch_plist || refuse "provider LaunchAgent does not execute the signed CLI path"
  body="$(status_json)" || refuse "live /v1/status on :$PORT is not answering"
  OLD_VERSION="$(status_field "$body" binary_version)"
  [ "$OLD_VERSION" = "$VERSION" ] || refuse "live binary version ${OLD_VERSION:-none} != $VERSION"
  serving "$body" "$VERSION" || refuse "the provider is not buyer_serving on $VERSION"
  config_postconditions "$body" || refuse "live status is not the exact signed four-slot GLM tuple"
  old_pid="$(job_pid)"
  [ -n "$old_pid" ] || refuse "provider job has no pid"
  [ "$(status_field "$body" service_instance.pid)" = "$old_pid" ] || refuse "status and launchd provider pid differ"
  verify_job_process "$old_pid" >/dev/null || refuse "live provider process is not the signed CLI path"
  provider_hash="$(status_field_sha "$body" provider_id)"
  python3 "$HELPER" prepare --config "$CONFIG" --journal "$JOURNAL" --backup "$BACKUP" \
    --version "$VERSION" --provider-id-sha256 "$provider_hash" --model "$EXPECTED_MODEL" \
    --policy-sha256 "$EXPECTED_POLICY_SHA" --policy-release-id "$EXPECTED_POLICY_RELEASE" \
    --policy-tuple-sha256 "$EXPECTED_POLICY_TUPLE" --binary-sha256 "$EXPECTED_BINARY_SHA" \
    --team-id "$EXPECTED_TEAM_ID" --signing-identifier "$EXPECTED_SIGNING_IDENTIFIER" \
    --cdhash "$EXPECTED_CDHASH" --executable-path "$INSTALL_DIR/macprovider-cli" ||
    refuse "could not arm the owner-pin journal"
  CONFIG_ARMED=1
  PAUSED=1
  control pause_request || refuse "pause_request was not accepted on $SOCKET"
  deadline=$(( $(now) + DRAIN_TIMEOUT_S ))
  while :; do
    body="$(status_json || true)"
    inflight="$(status_field "$body" requests_in_flight)"
    [ "$inflight" = 0 ] && break
    [ "$(now)" -lt "$deadline" ] || refuse "requests_in_flight=${inflight:-unknown} after ${DRAIN_TIMEOUT_S}s drain"
    sleep "$POLL_S"
  done
  stop_jobs || restore_config "provider job did not stop"
  python3 "$HELPER" apply --config "$CONFIG" --journal "$JOURNAL" || restore_config "scoped config mutation failed"
  verify_binary_identity || restore_config "signed executable identity changed before config validation"
  "$INSTALL_DIR/macprovider-cli" provider context explain --config "$CONFIG" --port "$PORT" >/dev/null ||
    restore_config "released CLI rejected the unpinned config"
  verify_binary_identity || restore_config "signed executable identity changed before bootstrap"
  verify_launch_plist || restore_config "provider LaunchAgent changed before bootstrap"
  start_jobs provider || restore_config "provider job did not start"
  start="$(now)"; pid0=""
  while [ -z "$pid0" ]; do
    pid0="$(job_pid)"
    [ -n "$pid0" ] && break
    [ $(( $(now) - start )) -lt 15 ] || restore_config "provider job has no process 15s after bootstrap"
    sleep 1
  done
  [ "$pid0" != "$old_pid" ] || restore_config "provider restart kept the old pid $old_pid"
  process_start="$(verify_job_process "$pid0")" || restore_config "launched provider is not the exact signed executable"
  last_answer="$start"; loaded=0; ready_at=""
  while :; do
    t="$(now)"; pid="$(job_pid)"
    [ "$pid" = "$pid0" ] || restore_config "provider process restarted (pid $pid0 -> ${pid:-none}): crash loop"
    [ "$(verify_job_process "$pid0")" = "$process_start" ] || restore_config "provider process identity changed during readiness"
    body="$(status_json || true)"
    if [ -n "$body" ]; then
      last_answer="$t"
      [ "$(status_field "$body" binary_version)" = "$VERSION" ] || restore_config "status binary identity changed"
      if [ "$(status_field "$body" model_loaded)" = true ]; then
        loaded=1
        paused "$body" && control resume_request || true
      fi
      if serving "$body" "$VERSION" && config_postconditions "$body"; then
        [ -n "$ready_at" ] || ready_at="$t"
        [ $(( t - ready_at )) -lt "$STABLE_S" ] || break
      else
        ready_at=""
      fi
    elif [ "$loaded" = 1 ] && [ $(( t - last_answer )) -ge "$STATUS_TIMEOUT_S" ]; then
      restore_config "/v1/status silent after model load"
    fi
    [ $(( t - start )) -lt "$READY_TIMEOUT_S" ] || restore_config "not buyer_serving on the signed four-slot tuple within ${READY_TIMEOUT_S}s"
    sleep "$POLL_S"
  done
  verify_binary_identity || restore_config "signed executable identity changed after readiness"
  [ "$(verify_job_process "$pid0")" = "$process_start" ] || restore_config "provider process identity changed after readiness"
  require_watchdog || restore_config "watchdog did not return after readiness"
  [ "$(verify_job_process "$pid0")" = "$process_start" ] || restore_config "watchdog restart changed the accepted provider process"
  python3 "$HELPER" accept --config "$CONFIG" --journal "$JOURNAL" --pid "$pid0" \
    --process-start-us "$process_start" --executable-path "$INSTALL_DIR/macprovider-cli" ||
    restore_config "could not durably bind the accepted provider process"
  # The controller keeps the journal armed through the provider-attributed
  # gateway proof. It either finalizes it after that proof or dispatches this
  # script's restore-owner-pin mode on every failure/signal.
  CONFIG_ARMED=0
  say "OK: owner pin removed; $VERSION buyer_serving at four slots (pid $pid0 start $process_start)"
  finish 0
fi

[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" = "$TARBALL_SHA" ] || refuse "staged tarball sha256 differs from the verified candidate"

# Members are checked from the archive headers before anything is extracted:
# relative names only, regular files and directories only, no duplicates.
rm -rf "$STAGE"
mkdir -p "$STAGE"
python3 - "$TARBALL" "$STAGE" <<'PY' || refuse "candidate tarball has unsafe or unexpected members"
import os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
with tarfile.open(src, "r:gz") as tar:
    members, seen = tar.getmembers(), set()
    for m in members:
        name = os.path.normpath(m.name)
        if m.name.startswith("/") or name == ".." or name.startswith("../") or name in seen:
            sys.exit("unsafe member name: %r" % m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit("non-regular member: %r" % m.name)
        seen.add(name)
    for m in members:
        tar.extract(m, dest, set_attrs=False)
PY
[ -f "$STAGE/macprovider-cli" ] && [ -f "$STAGE/mlx.metallib" ] || refuse "candidate payload lacks macprovider-cli or mlx.metallib"
chmod 755 "$STAGE/macprovider-cli"
staged_version="$("$STAGE/macprovider-cli" --version | tr -d '\r\n')"
[ "$staged_version" = "$VERSION" ] || refuse "staged macprovider-cli reports $staged_version, expected $VERSION"
body="$(status_json)" || refuse "live /v1/status on :$PORT is not answering; not swapping an unhealthy provider"
OLD_VERSION="$(status_field "$body" binary_version)"
[ -n "$OLD_VERSION" ] || refuse "live /v1/status reports no binary_version"
[ "$OLD_VERSION" != "$VERSION" ] || refuse "the canary already runs $VERSION"
if [ -n "$AIR_PROVIDER_SHA" ]; then
  # The only non-serving swap is the explicitly bound, signed Air recovery.
  [ "$VERSION" = 1.8.260 ] && [ "$OLD_VERSION" = 1.8.258 ] || refuse "Air recovery version mismatch"
  [ "$(sysctl -n hw.model)" = Mac15,12 ] && [ "$(sysctl -n hw.memsize)" = 17179869184 ] || refuse "Air recovery hardware mismatch"
  [ "$(status_field_sha "$body" provider_id)" = "$AIR_PROVIDER_SHA" ] || refuse "Air recovery provider mismatch"
  [ "$(status_field "$body" coordinator.connected)" = false ] && [ "$(status_field "$body" requests_in_flight)" = 0 ] || refuse "Air recovery requires disconnected zero-inflight incumbent"
  [ "$(status_field "$body" lifecycle.operator_paused)" != true ] || refuse "Air recovery cannot override operator pause"
  [ "$(shasum -a 256 "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')" = "$AIR_OLD_BINARY_SHA" ] || refuse "Air recovery incumbent bytes changed"
  [ "$(shasum -a 256 "$AIR_CONFIG" | awk '{print $1}')" = "$AIR_CONFIG_SHA" ] || refuse "Air recovery config changed"
  codesign --verify --strict "$INSTALL_DIR/macprovider-cli" >/dev/null 2>&1 || refuse "Air recovery incumbent signature is invalid"
  CONFIG="$AIR_CONFIG"
  verify_launch_plist || refuse "Air recovery LaunchAgent mismatch"
  verify_job_process "$(job_pid)" >/dev/null || refuse "Air recovery process mismatch"
else
  serving "$body" "$OLD_VERSION" || refuse "the canary is not buyer_serving on $OLD_VERSION; not swapping"
fi
say "preflight ok: live $OLD_VERSION -> candidate $VERSION"

# --- pause and drain -------------------------------------------------------
# Marked before sending: an accepted pause whose ack is lost still gets resumed.
PAUSED=1
if [ -z "$AIR_PROVIDER_SHA" ]; then
  control pause_request || refuse "pause_request was not accepted on $SOCKET"
else
  # Recheck immediately before stopping: never discard work admitted meanwhile.
  body="$(status_json)" || refuse "Air recovery lost incumbent status"
  [ "$(status_field "$body" coordinator.connected)" = false ] && [ "$(status_field "$body" requests_in_flight)" = 0 ] || refuse "Air recovery incumbent became active"
fi
deadline=$(( $(now) + DRAIN_TIMEOUT_S ))
while :; do
  body="$(status_json || true)"
  inflight="$(status_field "$body" requests_in_flight)"
  [ "$inflight" = 0 ] && break
  [ "$(now)" -lt "$deadline" ] || refuse "requests_in_flight=${inflight:-unknown} after ${DRAIN_TIMEOUT_S}s drain"
  sleep "$POLL_S"
done
say "drained in_flight=0"

# --- swap ------------------------------------------------------------------
cp -Rp "$INSTALL_DIR" "$BACKUP" || refuse "could not back up $INSTALL_DIR"
say "backup=$BACKUP"
if [ -n "$AIR_PROVIDER_SHA" ]; then
  # Detached operation metadata survives controller loss; no config or tokens.
  python3 - "$RESULT_FILE.recovery.json" "$BACKUP" "$INSTALL_DIR" "$AIR_PROVIDER_SHA" "$AIR_OLD_BINARY_SHA" "$TARBALL_SHA" "$AIR_CONFIG" <<'PY' || refuse "could not arm Air payload recovery record"
import hashlib, json, os, sys
path, backup, install, provider, old_sha, target_sha, config = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    json.dump({"schema_version":"macprovider.air_payload_recovery.v1", "phase":"armed",
               "backup_path":backup, "install_dir":install, "provider_id_sha256":provider,
               "incumbent_binary_sha256":old_sha, "target_tarball_sha256":target_sha,
               "config_sha256":hashlib.sha256(open(config,"rb").read()).hexdigest()}, stream)
    stream.flush(); os.fsync(stream.fileno())
directory = os.open(os.path.dirname(path), os.O_RDONLY)
try: os.fsync(directory)
finally: os.close(directory)
PY
fi
SWAPPED=1
stop_jobs || restore_backup "provider job did not stop"
for f in $MANAGED_FILES; do
  rm -f "$INSTALL_DIR/$f"
  [ ! -f "$STAGE/$f" ] || cp "$STAGE/$f" "$INSTALL_DIR/$f"
done
for d in $MANAGED_DIRS; do
  rm -rf "${INSTALL_DIR:?}/$d"
  [ ! -d "$STAGE/$d" ] || cp -R "$STAGE/$d" "$INSTALL_DIR/$d"
done
chmod 755 "$INSTALL_DIR/macprovider-cli"
cmp "$STAGE/macprovider-cli" "$INSTALL_DIR/macprovider-cli" || restore_backup "installed binary differs from the staged candidate"
start_jobs provider || restore_backup "provider job did not start"
say "restarted on $VERSION"

# --- watch: crash loop, exit or post-load status silence restores the backup -
# A pid change (crash loop) or a process that exited (launchd reports no pid)
# fails at once. /v1/status silence
# while the model loads is not a failure: the model-load window of a large
# model is bounded by READY_TIMEOUT_S alone. Once the candidate has reported
# model_loaded, a silence of STATUS_TIMEOUT_S is a hang and fails.
start="$(now)"
pid0=""
while [ -z "$pid0" ]; do
  pid0="$(job_pid)"
  [ -n "$pid0" ] && break
  [ $(( $(now) - start )) -lt 15 ] || restore_backup "provider job has no process 15s after bootstrap"
  sleep 1
done
last_answer="$start"
loaded=0
ready_at=""
while :; do
  t="$(now)"
  pid="$(job_pid)"
  [ "$pid" = "$pid0" ] || restore_backup "provider process restarted (pid $pid0 -> ${pid:-none}): crash loop"
  body="$(status_json || true)"
  if [ -n "$body" ]; then
    last_answer="$t"
    running="$(status_field "$body" binary_version)"
    [ "$running" = "$VERSION" ] || restore_backup "/v1/status reports binary_version ${running:-none}, expected $VERSION"
    if [ "$(status_field "$body" model_loaded)" = true ]; then
      [ "$loaded" = 1 ] || say "model loaded on $VERSION after $(( t - start ))s"
      loaded=1
      if paused "$body"; then
        control resume_request || true
      fi
    fi
    if serving "$body" "$VERSION"; then
      if [ -z "$ready_at" ]; then
        ready_at="$t"
        say "buyer_serving on $VERSION; holding ${STABLE_S}s for a crash"
      fi
      [ $(( t - ready_at )) -lt "$STABLE_S" ] || break
    else
      ready_at=""
    fi
  elif [ "$loaded" = 1 ] && [ $(( t - last_answer )) -ge "$STATUS_TIMEOUT_S" ]; then
    restore_backup "/v1/status not answering for ${STATUS_TIMEOUT_S}s after the model loaded"
  fi
  [ $(( t - start )) -lt "$READY_TIMEOUT_S" ] || restore_backup "not buyer_serving within ${READY_TIMEOUT_S}s"
  sleep "$POLL_S"
done
start_watchdog
say "OK: canary serves $VERSION (pid $pid0); previous payload kept at $BACKUP"
finish 0
