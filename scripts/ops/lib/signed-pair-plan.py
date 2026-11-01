#!/usr/bin/env python3
"""Build or offline-check a signed native pair plan.

  build  Derive every release-bound field of a new plan from the committed
         release bytes (dist/static), take Studio, receipt-reader and prior
         identity from the previous plan (--template), and write a fresh
         transaction with an arm-window deadline, mode 0600, never overwriting.
  check  Validate a plan against the release bytes and print every failed
         check by name. Exit 1 when any check fails.

No network, SSH or live state is read. Pass Pearl's release listing with
--existing-release-ids to refuse a release directory that already exists.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
CONTENT = ROOT / 'scripts/catalog-content-release.sh'
CATALOG = ROOT / 'scripts/ops/catalog-activate.sh'
SWAP = ROOT / 'scripts/ops/canary-swap.sh'
REMOTE = ROOT / 'scripts/ops/lib/canary-swap-remote.sh'
SCHEMA = 'macprovider.signed_native_pair.v1'
PROFILE = 'native_mtp_greedy_text_v1'
ENDPOINTS = ('/v1/native-mtp-admission', '/v1/native-mtp-admission.sig',
             '/v1/native-mtp-selftest-bank', '/v1/native-mtp-selftest-bank.sig',
             '/v1/native-mtp-artifact-manifest', '/v1/autotune-candidates',
             '/v1/autotune-candidates.sig', '/v1/continuous-batching-policy',
             '/v1/continuous-batching-policy.sig', '/v1/catalog-artifacts',
             '/v1/catalog-artifacts.sig')
DEADLINE_MIN, DEADLINE_MAX = 1800, 3600
# Binary identity a new binary version must not inherit from the template.
VERSION_BOUND = ('source_commit', 'binary_sha256', 'tarball_sha256', 'decode_path_digest',
                 'cdhash', 'baked_catalog_release_id', 'local_tarball_path')
CANDIDATE_BOUND = ('candidate_run_id', 'acceptance_manifest_sha256',
                   'acceptance_signature_sha256', 'checksums_sha256')


class Failed(Exception):
    pass


def sha256_bytes(raw):
    return hashlib.sha256(raw).hexdigest()


def sha256_file(path):
    return sha256_bytes(Path(path).read_bytes())


def feed_file(endpoint):
    # Same endpoint -> dist/static mapping as the PAIR_INTENT root gate.
    name = endpoint.removeprefix('/v1/')
    sig = name.endswith('.sig')
    base = name[:-4] if sig else name
    return {'catalog-artifacts': 'autotune-artifacts'}.get(base, base) + '.json' + ('.sig' if sig else '')


def heredoc(path, tag):
    text = Path(path).read_text()
    return re.split(r"<<'" + re.escape(tag) + r"'[^\n]*\n", text, maxsplit=1)[1].split('\n' + tag, 1)[0]


def run_block(path, tag, *args, env=None):
    return subprocess.run([sys.executable, '-I', '-c', heredoc(path, tag), *map(str, args)],
                          capture_output=True, text=True, timeout=60, env=env)


def release_dirname(release_dir, autotune_dir):
    """Pearl's releases/<id>-<sha16> name, computed by the content release's
    own release_dirname() over the same assembled member set."""
    text = CONTENT.read_text()
    body = text[text.index('release_dirname() {'):]
    code = body.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    with tempfile.TemporaryDirectory() as temp:
        rel = Path(temp)
        for name in ('release.json', 'trusted-keys.json', 'tier2-catalog.json'):
            if not (autotune_dir / name).is_file():
                return None
            shutil.copyfile(autotune_dir / name, rel / name)
        for source in release_dir.iterdir():
            if source.is_file() and not (rel / source.name).exists():
                shutil.copyfile(source, rel / source.name)
        result = subprocess.run([sys.executable, '-I', '-c', code, str(rel)],
                                capture_output=True, text=True, timeout=60)
    return result.stdout.strip() if result.returncode == 0 else None


def load_release(release_dir):
    def doc(name):
        return json.loads((release_dir / name).read_text())
    return dict(policy=doc('continuous-batching-policy.json'),
                admission=doc('native-mtp-admission.json'),
                projection=doc('native-mtp-artifact-manifest.json'))


def cb_entries(release, model_key, model_sha256=None):
    return [e for e in release['policy'].get('entries', [])
            if e.get('model_key') == model_key and (model_sha256 is None or e.get('model_sha256') == model_sha256)]


def admission_entries(release, model_key):
    return [e for e in release['admission'].get('entries', []) if e.get('model_key') == model_key]


def existing_names(value):
    if not value:
        return set()
    raw = Path(value).read_text() if Path(value).is_file() else value.replace(',', '\n')
    return {Path(line.strip().rstrip('/')).name for line in raw.splitlines() if line.strip()}


def check(plan_path, release_dir, autotune_dir=None, expect_model_key=None, existing=None):
    """Return [(check name, detail)] for every failed check."""
    failures = []

    def fail(name, detail):
        failures.append((name, detail))

    plan_path = Path(plan_path)
    release_dir = Path(release_dir)
    autotune_dir = Path(autotune_dir) if autotune_dir else release_dir.parent.parent / 'catalog/autotune'
    try:
        info = os.lstat(plan_path)
    except OSError as error:
        return [('plan_readable', str(error))]
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail('plan_mode_0600', 'mode %o owner %d; consumers require a regular owner-only file'
             % (stat.S_IMODE(info.st_mode), info.st_uid))
    try:
        plan = json.loads(plan_path.read_text())
        target = plan['target']
    except (OSError, ValueError, KeyError, TypeError) as error:
        return failures + [('plan_json', '%s: %s' % (type(error).__name__, error))]

    if plan.get('schema_version') != SCHEMA:
        fail('schema_version', 'observed %r, expected %r' % (plan.get('schema_version'), SCHEMA))
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', str(plan.get('transaction_id', ''))):
        fail('transaction_id', 'must match [A-Za-z0-9_-]{1,80}')
    deadline = run_block(CATALOG, 'PAIR_DEADLINE', plan_path)
    if deadline.returncode != 0:
        fail('deadline_window', (deadline.stdout or deadline.stderr).strip()
             or 'deadline_epoch is outside [now+%d, now+%d]' % (DEADLINE_MIN, DEADLINE_MAX))

    model_key = target.get('model_key')
    model_hash = target.get('model_hash')
    if expect_model_key is not None and model_key != expect_model_key:
        fail('expected_model_key', 'plan targets %r, expected %r' % (model_key, expect_model_key))

    try:
        release = load_release(release_dir)
    except (OSError, ValueError) as error:
        return failures + [('release_dir', '%s: %s' % (type(error).__name__, error))]

    rid = target.get('catalog_release_id')
    for name, document in (('continuous-batching-policy.json', release['policy']),
                           ('native-mtp-admission.json', release['admission'])):
        if document.get('release_id') != rid:
            fail('target_release_id', '%s release_id %r, plan %r' % (name, document.get('release_id'), rid))
    if (autotune_dir / 'release.json').is_file():
        committed = json.loads((autotune_dir / 'release.json').read_text()).get('release_id')
        if committed != rid:
            fail('target_release_id', 'catalog/autotune/release.json release_id %r, plan %r' % (committed, rid))

    feeds = target.get('feed_sha256') or {}
    missing = sorted(set(ENDPOINTS) - set(feeds))
    if missing:
        fail('feed_endpoints_complete', 'missing ' + ', '.join(missing))
    for endpoint, expected in sorted(feeds.items()):
        path = release_dir / feed_file(endpoint)
        observed = sha256_file(path) if path.is_file() else None
        if observed != expected:
            fail('feed_sha256 ' + endpoint, 'plan %s, %s %s' % (expected, path.name, observed or 'absent'))

    policy_sha = sha256_file(release_dir / 'continuous-batching-policy.json')
    if target.get('cb_policy_sha256') != policy_sha:
        fail('cb_policy_sha256', 'plan %s, continuous-batching-policy.json %s' % (target.get('cb_policy_sha256'), policy_sha))
    entries = cb_entries(release, model_key, model_hash)
    if not entries:
        fail('model_in_cb_policy', 'no CB policy entry for %s with model_sha256 %s' % (model_key, model_hash))
    elif target.get('cb_tuple_sha256') not in {e.get('tuple_sha256') for e in entries}:
        fail('cb_tuple_sha256', 'plan %s, policy tuples for %s: %s' % (
            target.get('cb_tuple_sha256'), model_key, ', '.join(sorted(e['tuple_sha256'] for e in entries))))

    admitted = admission_entries(release, model_key)
    if len(admitted) != 1:
        fail('model_in_admission', '%d native-MTP admission entries for %s' % (len(admitted), model_key))
    else:
        entry = admitted[0]
        if entry.get('artifact_hash') != model_hash:
            fail('admission_model_hash', 'admission artifact_hash %s, plan model_hash %s' % (entry.get('artifact_hash'), model_hash))
        if entry.get('decode_path_digest') != target.get('decode_path_digest'):
            fail('admission_decode_path_digest', 'admission %s, plan %s' % (
                entry.get('decode_path_digest'), target.get('decode_path_digest')))
        if entry.get('request_feature_profile') != target.get('request_feature_profile'):
            fail('admission_request_feature_profile', 'admission %r, plan %r' % (
                entry.get('request_feature_profile'), target.get('request_feature_profile')))
    projected = set((release['projection'].get('models') or {}).keys())
    if model_key not in projected:
        fail('model_in_projection', '%s absent from native-mtp-artifact-manifest.json' % model_key)
    unprojected = sorted({e.get('model_key') for e in release['admission'].get('entries', [])} - projected)
    if unprojected:
        fail('projection_covers_admission', 'admitted but not projected: ' + ', '.join(map(str, unprojected)))

    if existing:
        dirname = release_dirname(release_dir, autotune_dir)
        if dirname is None:
            fail('release_dir_unused', 'cannot compute the release directory name from %s' % autotune_dir)
        elif dirname in existing:
            fail('release_dir_unused', 'releases/%s already exists' % dirname)
        reused = sorted(n for n in existing if n != dirname and re.fullmatch(re.escape(str(rid)) + r'-[0-9a-f]{16}', n))
        if reused:
            fail('release_id_unused', 'release id %s already published as %s' % (rid, ', '.join(reused)))

    # The consumers' own gates, so a passing check cannot disagree with them.
    gates = (('root_plan_gate', CATALOG, 'PAIR_PLAN', (plan_path, rid)),
             ('root_intent_gate', CONTENT, 'PAIR_INTENT', (plan_path, rid, release_dir)),
             ('transport_arm_gate', SWAP, 'PAIR_VALIDATE_PY', (plan_path, 'arm')))
    for name, path, tag, args in gates:
        result = run_block(path, tag, *args)
        if result.returncode != 0:
            fail(name, '%s %s refused the plan' % (path.relative_to(ROOT), tag))
    key = str((plan.get('receipt_reader') or {}).get('private_key_path', ''))
    marker = '/.config/macprovider/operator-secrets/'
    studio_home = key.split(marker, 1)[0] if marker in key else str(Path.home())
    driver = ("import json,sys\n"
              "src=open(sys.argv[1]).read().split(\"<<'SIGNED_PAIR_PY'\\n\",1)[1].split('\\nSIGNED_PAIR_PY',1)[0]\n"
              "g={'__name__':'signed_pair_check'};exec(compile(src,sys.argv[1],'exec'),g)\n"
              "try:g['validate'](json.load(open(sys.argv[2])))\n"
              "except (g['Refused'],KeyError,TypeError,ValueError) as e:print(type(e).__name__+': '+str(e));sys.exit(1)\n")
    # validate() resolves the operator secret store under the Studio home.
    result = subprocess.run([sys.executable, '-I', '-c', driver, str(REMOTE), str(plan_path)],
                            capture_output=True, text=True, timeout=60, env=dict(os.environ, HOME=studio_home))
    if result.returncode != 0:
        fail('studio_actor_validate', result.stdout.strip() or result.stderr.strip()[-200:])
    return failures


def tarball_identity(path):
    """Identity fields derivable from a release tarball's bytes."""
    path = Path(path).resolve()
    out = dict(local_tarball_path=str(path), tarball_sha256=sha256_file(path))
    found = re.fullmatch(r'macprovider-cli-v([0-9]+\.[0-9]+\.[0-9]+)-darwin-arm64\.tar\.gz', path.name)
    if found:
        out['version'] = found.group(1)
    with tarfile.open(path, 'r:gz') as archive:
        names = {os.path.normpath(m.name): m for m in archive.getmembers() if m.isfile()}
        if 'macprovider-cli' in names:
            binary = archive.extractfile(names['macprovider-cli']).read()
            out['binary_sha256'] = sha256_bytes(binary)
            markers = set(re.findall(rb'macprovider\.decode-path-digest\.v1:([0-9a-f]{64})', binary))
            if len(markers) == 1:
                out['decode_path_digest'] = markers.pop().decode()
        if 'catalog-release/release.json' in names:
            out['baked_catalog_release_id'] = json.loads(
                archive.extractfile(names['catalog-release/release.json']).read())['release_id']
    return out


def build(args):
    release_dir = Path(args.release_dir).resolve()
    template = json.loads(Path(args.template).read_text())
    release = load_release(release_dir)
    old_tx = template['transaction_id']
    tx = str(uuid.uuid4())
    if not args.deadline_seconds or not DEADLINE_MIN <= args.deadline_seconds <= DEADLINE_MAX:
        raise Failed('--deadline-seconds must be within [%d, %d]' % (DEADLINE_MIN, DEADLINE_MAX))

    target = dict(template['target'])
    derived = tarball_identity(args.local_tarball) if args.local_tarball else {}
    explicit = {k: v for k, v in dict(
        version=args.binary_version, source_commit=args.source_commit, cdhash=args.cdhash,
        team_id=args.team_id, signing_identifier=args.signing_identifier, provenance=args.provenance,
        candidate_run_id=args.candidate_run_id, acceptance_manifest_sha256=args.acceptance_manifest_sha256,
        acceptance_signature_sha256=args.acceptance_signature_sha256, checksums_sha256=args.checksums_sha256).items()
        if v is not None}
    for key in set(derived) & set(explicit):
        if derived[key] != explicit[key]:
            raise Failed('--%s %s disagrees with the tarball (%s)' % (key.replace('_', '-'), explicit[key], derived[key]))
    supplied = dict(derived, **explicit)
    if supplied.get('version', target['version']) != target['version']:
        bound = VERSION_BOUND + (CANDIDATE_BOUND if supplied.get('provenance', target.get('provenance'))
                                 == 'reviewed_signed_acceptance_candidate' else ())
        missing = [k for k in bound if k not in supplied]
        if missing:
            raise Failed('a new binary version cannot inherit %s from the template; pass %s' % (
                ', '.join(missing), ' '.join('--' + k.replace('_', '-') for k in missing
                                             if k not in ('local_tarball_path', 'tarball_sha256', 'binary_sha256'))
                or '--local-tarball'))
    if supplied.get('provenance') == 'reviewed_published_signed_release':
        for key in CANDIDATE_BOUND:
            target.pop(key, None)
    target.update(supplied)

    admitted = admission_entries(release, args.model_key)
    if len(admitted) != 1:
        raise Failed('%d native-MTP admission entries for %s' % (len(admitted), args.model_key))
    model_sha = args.model_sha256 or admitted[0]['artifact_hash']
    entries = cb_entries(release, args.model_key, model_sha)
    if args.cb_tuple_sha256:
        entries = [e for e in entries if e['tuple_sha256'] == args.cb_tuple_sha256]
    if len(entries) != 1:
        raise Failed('%d CB policy entries for %s %s; pass --cb-tuple-sha256 to choose one' % (
            len(entries), args.model_key, model_sha))
    target.update(
        catalog_release_id=release['policy']['release_id'],
        feed_sha256={e: sha256_file(release_dir / feed_file(e)) for e in ENDPOINTS},
        cb_policy_sha256=sha256_file(release_dir / 'continuous-batching-policy.json'),
        cb_tuple_sha256=entries[0]['tuple_sha256'],
        model_key=args.model_key, model=args.model or entries[0]['model_id'], model_hash=model_sha,
        request_feature_profile=admitted[0]['request_feature_profile'],
        previous_window_sha256=args.previous_window_sha256)

    def rebind(value):
        if isinstance(value, dict):
            return {k: rebind(v) for k, v in value.items()}
        return value.replace('signed-pair-' + old_tx, 'signed-pair-' + tx) if isinstance(value, str) else value
    plan = rebind({k: v for k, v in template.items() if k not in ('prior', 'target')})
    plan['prior'] = dict(template['prior'], tarball_path=rebind(template['prior']['tarball_path']))
    stage = Path(plan['studio']['journal_path']).parent
    target['tarball_path'] = str(stage / Path(target['local_tarball_path']).name) \
        if args.local_tarball else rebind(target['tarball_path'])
    plan['target'] = target
    plan['transaction_id'] = tx
    plan['deadline_epoch'] = int(time.time()) + args.deadline_seconds
    hosts = Path(plan['receipt_reader'].get('local_known_hosts_path', ''))
    if hosts.is_file():
        plan['receipt_reader']['known_hosts_sha256'] = sha256_file(hosts)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = out.with_name('.' + out.name + '.next-' + str(os.getpid()))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(plan, stream, indent=2, sort_keys=True)
            stream.write('\n')
        failures = check(temporary, release_dir, args.autotune_dir, args.model_key, existing_names(args.existing_release_ids))
        if failures:
            report(failures)
            raise Failed('generated plan failed its own check; nothing written')
        os.link(temporary, out)  # never replaces an existing plan
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps(dict(plan=str(out), transaction_id=tx, deadline_epoch=plan['deadline_epoch'],
                          target_release_id=target['catalog_release_id'], model_key=args.model_key,
                          cb_tuple_sha256=target['cb_tuple_sha256']), sort_keys=True))


def report(failures):
    for name, detail in failures:
        print('FAIL %s: %s' % (name, detail), file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--release-dir', default=str(ROOT / 'phase3-binary/dist/static'))
    common.add_argument('--autotune-dir', help='committed catalog/autotune (default: <release-dir>/../../catalog/autotune)')
    common.add_argument('--existing-release-ids', help="Pearl's releases/ listing: a file or a comma list")
    b = sub.add_parser('build', parents=[common])
    b.add_argument('--template', required=True, help='previous plan: Studio, receipt reader and prior identity')
    b.add_argument('--model-key', required=True)
    b.add_argument('--model-sha256')
    b.add_argument('--model', help='served model name (default: the CB entry model_id)')
    b.add_argument('--cb-tuple-sha256', help='choose among several CB entries for one model')
    b.add_argument('--previous-window-sha256', required=True)
    b.add_argument('--local-tarball', help='target release tarball; its bytes give the binary identity')
    for flag in ('binary-version', 'source-commit', 'cdhash', 'team-id', 'signing-identifier', 'provenance',
                 'candidate-run-id', 'acceptance-manifest-sha256', 'acceptance-signature-sha256', 'checksums-sha256'):
        b.add_argument('--' + flag)
    b.add_argument('--deadline-seconds', type=int, default=3300)
    b.add_argument('--out', required=True)
    c = sub.add_parser('check', parents=[common])
    c.add_argument('--plan', required=True)
    c.add_argument('--expect-model-key')
    args = parser.parse_args(argv)
    if args.command == 'build' and args.candidate_run_id is not None:
        args.candidate_run_id = int(args.candidate_run_id)
    try:
        if args.command == 'build':
            build(args)
            return 0
        failures = check(args.plan, args.release_dir, args.autotune_dir, args.expect_model_key,
                         existing_names(args.existing_release_ids))
    except (Failed, OSError, ValueError, KeyError) as error:
        print('signed-pair plan: %s: %s' % (type(error).__name__, error), file=sys.stderr)
        return 1
    report(failures)
    print('signed-pair plan check: %s' % ('%d failed' % len(failures) if failures else 'ok'))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
