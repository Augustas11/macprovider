#!/usr/bin/env python3
"""Sent over SSH: bounded identity-only edit under both Pearl deployment locks.

No credentials, private keys, provider IDs or full configuration are printed.
Release signature verification is performed by the reviewed ops entry point.
"""
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

import yaml

BASE = Path('/opt/macprovider/coordinator.yaml')
OVERLAY = Path('/etc/macprovider/coordinator.pearl-overlays.yaml')
GATEWAY = Path('/opt/macprovider/gateway.yaml')
EXPIRY = '2026-10-20T00:00:00Z'
CONFIG_GUARD_MODULE = Path('/usr/local/share/macprovider/scripts/coordinator_config_guard.py')
CONFIG_GUARD_SHA256 = 'be9c226719b2b6921bd9455e3e3ee9e4222da19fbacaaa3a3a0cd70e72625338'
RUNTIME_HASHES = {
    'coordinator': 'b208eb9b034e65ff8a4a5ac274996aebfd85369b0e9c247d5984517fbb1b5121',
    'gateway': '99f8a8738086c7d1da11421b169c575dced23f76af311ef30d015baf46d26382',
    'coordinator-cli': '1012085a840e707bc498be71e727f776178baa4e91389cce1b0340b908625f0b',
}
IDENTITY = dict(team_id='YF7XNRJUG4', signing_identifier='live.malibu.provider.cli',
                code_cdhash='94b66febaee9ac7265dc0fe1a6ad87559ff602b8',
                binary_version='1.8.224')


def check_release(data):
    release = json.loads(base64.b64decode(data, validate=True))
    identity = release['provider_code_identity']
    expected = {k: v for k, v in IDENTITY.items() if k != 'code_cdhash'}
    if release['tag'] != 'v1.8.224' or any(identity.get(k) != v for k, v in expected.items()):
        raise ValueError('release identity mismatch')
    if identity['slices'] != [{'arch': 'arm64', 'code_cdhash': IDENTITY['code_cdhash']}]:
        raise ValueError('release slice mismatch')


def expired():
    return dt.datetime.now(dt.timezone.utc) >= dt.datetime.fromisoformat(EXPIRY.replace('Z', '+00:00'))


def approved(pc):
    if expired():
        return False
    entries = pc.get('approved_code_identities') or []
    if len(entries) != 1:
        return False
    for entry in entries:
        expiry = entry.get('expires_at')
        if isinstance(expiry, dt.datetime):
            expiry = expiry.astimezone(dt.timezone.utc).isoformat().replace('+00:00', 'Z')
        if all(entry.get(k) == v for k, v in IDENTITY.items()) and expiry == EXPIRY:
            return True
    return False


def preflight(check_expiry=False):
    if check_expiry and expired():
        raise ValueError('activation exception expired')
    runtime_provenance()
    base = yaml.safe_load(BASE.read_text())
    overlay = yaml.safe_load(OVERLAY.read_text()) or {}
    gateway = yaml.safe_load(GATEWAY.read_text())
    if 'privacy_class' in overlay or 'relay_blind' in overlay:
        raise ValueError('privacy overlay requires explicit reconciliation')
    pc = base['privacy_class']
    if pc.get('enabled') is not True or base['relay_blind'].get('enabled') is not True:
        raise ValueError('existing privacy/relay configuration must already be enabled')
    if gateway['features'].get('privacy_class', {}).get('enabled') is not True or gateway['features'].get('relay_blind_requests', {}).get('enabled') is not True:
        raise ValueError('gateway privacy features are disabled')
    if pc.get('release_code_identities'):
        raise ValueError('release-derived identities require bounded exception reconciliation')
    if not pc.get('directory', {}).get('signing_key_path'):
        raise ValueError('dedicated directory signing key is required')
    return pc


def verify_config_paths(argv):
    # Kill-switch writes must target the live store, not merely an installed
    # config belonging to an otherwise identical reviewed service binary.
    if b'--config' not in argv or b'--config-overlay' not in argv:
        raise ValueError('running coordinator config provenance mismatch')
    if argv[argv.index(b'--config') + 1] != bytes(BASE) or argv[argv.index(b'--config-overlay') + 1] != bytes(OVERLAY):
        raise ValueError('running coordinator config paths mismatch')


def runtime_provenance():
    # These hashes are from the signature-verified immutable v1.8.227 release,
    # source fbb96363e92f6ffe2ce60d39f11a433eb6534c0c (contains #1871/#1892).
    for binary, expected in RUNTIME_HASHES.items():
        path = Path('/opt/macprovider', binary)
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                raise ValueError('running backend release differs from approved runtime')
        if binary != 'coordinator-cli':
            pid = subprocess.check_output(['systemctl', 'show', '--property=MainPID', '--value',
                                           'macprovider-' + binary], text=True).strip()
            with Path('/proc', pid, 'exe').open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                    raise ValueError('service process differs from installed signed runtime')
            if binary == 'coordinator':
                verify_config_paths(Path('/proc', pid, 'cmdline').read_bytes().split(b'\0'))


def config_guard():
    # Reuse the installed L0 lease-order/journal guard, never a new lock scheme.
    source = CONFIG_GUARD_MODULE.read_bytes()
    if hashlib.sha256(source).hexdigest() != CONFIG_GUARD_SHA256:
        raise ValueError('installed config guard differs from reviewed source')
    spec = importlib.util.spec_from_loader('privacy_config_guard', loader=None)
    module = importlib.util.module_from_spec(spec)
    exec(compile(source, str(CONFIG_GUARD_MODULE), 'exec'), module.__dict__)
    return module.LockSet('/opt/macprovider')


def disabled():
    config = yaml.safe_load(BASE.read_text())
    path = Path(config['relay_blind']['sqlite_path']).resolve(strict=True)
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=3) as db:
        row = db.execute('SELECT disabled FROM privacy_class_control WHERE id=1').fetchone()
        return bool(row and row[0])


def disable():
    with config_guard():
        disable_locked()


def disable_locked():
    runtime_provenance()
    # The reviewed CLI owns the durable kill switch; no direct DB writes.
    subprocess.run(['bash', '-euc', 'set -a; source /etc/macprovider/coordinator.env; '
                    'set +a; exec runuser -u macprovider -- /opt/macprovider/coordinator-cli '
                    'privacy-class disable --reason activation-rollback '
                    '--config /opt/macprovider/coordinator.yaml '
                    '--config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    if not disabled():
        raise RuntimeError('durable kill switch did not engage')
    print(json.dumps({'disabled': True}))


def replace_privacy(text, pc):
    # Only this top-level block changes. All other bytes (including secrets,
    # comments and other sessions' unrelated settings) are preserved.
    matches = list(re.finditer(r'^privacy_class:\s*(?:#.*)?\n(?:[ \t].*(?:\n|$)|\s*\n)*', text, re.M))
    if len(matches) != 1:
        raise ValueError('expected exactly one standalone privacy_class block')
    match = matches[0]
    return text[:match.start()] + yaml.safe_dump({'privacy_class': pc}, sort_keys=False) + text[match.end():]


def install(text):
    st = BASE.stat()
    fd, name = tempfile.mkstemp(prefix='.privacy-activation-', dir=BASE.parent)
    try:
        os.fchmod(fd, st.st_mode & 0o777)
        os.fchown(fd, st.st_uid, st.st_gid)
        with os.fdopen(fd, 'w') as target:
            target.write(text)
            target.flush()
            os.fsync(target.fileno())
        os.replace(name, BASE)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def validate():
    # Load the same protected environment as the service without exposing it.
    subprocess.run(['bash', '-euc', 'set -a; source /etc/macprovider/coordinator.env; '
                    'set +a; exec runuser -u macprovider -- /opt/macprovider/coordinator '
                    '--config /opt/macprovider/coordinator.yaml '
                    '--config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml '
                    '--validate-config'], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=60)


def restart_healthy():
    subprocess.run(['systemctl', 'restart', 'macprovider-coordinator'], check=True, timeout=90)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with opener.open('http://127.0.0.1:8443/healthz', timeout=3) as response:
                if response.status == 200:
                    return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError('coordinator health did not recover')


def apply(data):
    check_release(data)
    with config_guard():
        pc = preflight(check_expiry=True)
        if disabled():
            raise ValueError('privacy kill switch is engaged')
        if approved(pc):
            print(json.dumps({'approved': True, 'changed': False}))
            return
        original = BASE.read_text()
        entry = dict(IDENTITY, expires_at=EXPIRY)
        # Replace only the superseded approval set; retain all key pins and
        # quarantine/denial configuration. No loader can extend the expiry.
        pc['approved_code_identities'] = [entry]
        candidate = replace_privacy(original, pc)
        if yaml.safe_load(candidate)['privacy_class'] != pc:
            raise ValueError('candidate privacy block mismatch')
        backup_dir = Path(tempfile.mkdtemp(prefix='privacy-activation-', dir='/root'))
        os.chmod(backup_dir, 0o700)
        shutil.copy2(BASE, backup_dir / 'coordinator.yaml')
        try:
            install(candidate)
            validate()
        except Exception:
            install(original)
            raise
        try:
            restart_healthy()
            if not approved(preflight(check_expiry=True)):
                raise RuntimeError('approval postcondition did not hold')
        except Exception:
            install(original)
            restart_healthy()
            raise
        print(json.dumps({'approved': True, 'changed': True}))


def withdraw():
    if not expired():
        raise ValueError('expiry withdrawal before exception deadline is refused')
    with config_guard():
        original = BASE.read_text()
        pc = yaml.safe_load(original)['privacy_class']
        entries = pc.get('approved_code_identities') or []
        if pc.get('release_code_identities') or any(any(e.get(k) != v for k, v in IDENTITY.items()) for e in entries):
            raise ValueError('superseding approval requires reconciliation')
        disable_locked()
        pc['enabled'] = False
        pc['approved_code_identities'] = []
        try:
            install(replace_privacy(original, pc))
            validate()
            restart_healthy()
            runtime_provenance()
            current = yaml.safe_load(BASE.read_text())['privacy_class']
            if current.get('enabled') is not False or current.get('approved_code_identities') or not disabled():
                raise RuntimeError('withdrawal postcondition did not hold')
        except Exception:
            install(original)
            restart_healthy()
            # The durable switch deliberately remains disabled on failure.
            raise
        print(json.dumps({'withdrawn': True, 'disabled': True}))


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['status']:
            if expired():
                pc = yaml.safe_load(BASE.read_text())['privacy_class']
                withdrawn = pc.get('enabled') is False and not pc.get('approved_code_identities')
                print(json.dumps({'approved': False, 'disabled': disabled(), 'expired': True, 'withdrawn': withdrawn}))
            else:
                print(json.dumps({'approved': approved(preflight()), 'disabled': disabled(), 'expired': False}))
        elif sys.argv[1:] == ['withdraw']:
            withdraw()
        elif sys.argv[1:] == ['disable']:
            disable()
        elif len(sys.argv) == 3 and sys.argv[1] == 'apply':
            apply(sys.argv[2])
        else:
            raise ValueError('expected status or apply')
    except Exception as error:
        # Exception text may contain config/credentials; print type only.
        print('privacy activation refused: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
