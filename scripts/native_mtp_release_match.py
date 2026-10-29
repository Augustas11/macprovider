#!/usr/bin/env python3
"""Preflight the provider's exact native-MTP matcher without running the provider.

The release's compatibility manifest binds its packaged catalog release, which
binds the existing signed admission scope (model, artifact, hardware, RAM and
slots). That independent scope is deliberately distinct from the proposed tuple
inputs. Runtime, decode digest and metallib are read from the actual release
source/payload, never copied from either admission set. Historical discovery is
used as a signature/hash proof, not as a current update recommendation.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile


class MatchError(RuntimeError):
    pass


def require(value: object, field: str, detail: str) -> None:
    if not value:
        raise MatchError(f"{field}: {detail}")


def load_module(repo: pathlib.Path, name: str):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), repo / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_json(path: pathlib.Path) -> dict:
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            require(key not in obj, 'json', f'duplicate key {key}')
            obj[key] = value
        return obj
    obj = json.loads(path.read_bytes(), object_pairs_hook=unique)
    require(isinstance(obj, dict), 'json', 'object required')
    return obj


def run(args: list[str], field: str) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    require(result.returncode == 0, field, result.stderr.strip() or result.stdout.strip() or 'verification failed')
    return result.stdout.strip()


def digest(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def source_identity(repo: pathlib.Path, commit: str) -> tuple[str, str]:
    require(isinstance(commit, str) and re.fullmatch(r'[0-9a-f]{40}', commit), 'source_commit', 'full commit required')
    raw = run(['git', '-C', str(repo), 'show', f'{commit}:phase3-binary/Package.resolved'], 'runtime_revision')
    pins = [p['state']['revision'] for p in json.loads(raw)['pins'] if p['identity'] == 'mlx-swift-lm']
    require(len(pins) == 1, 'runtime_revision', 'exactly one mlx-swift-lm pin required')
    swift = run(['git', '-C', str(repo), 'show', f'{commit}:phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift'], 'binary_version')
    versions = re.findall(r'let binaryVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', swift)
    require(len(versions) == 1, 'binary_version', 'source has no unique binaryVersion')
    return pins[0], versions[0]


SCOPE_FIELDS = ('model_key', 'artifact_hash', 'hardware_class', 'ram_bytes', 'qualified_slots')
IDENTITY_FIELDS = ('runtime_revision', 'decode_path_digest', 'metallib_sha256')


def verify_entries(admission: dict, scope: dict, identity: dict) -> None:
    entries = admission.get('entries')
    baseline = scope.get('entries')
    require(isinstance(entries, list) and entries, 'entries', 'nonempty admission set required')
    require(isinstance(baseline, list) and baseline, 'scope', 'signed release contains no native-MTP scope')
    contexts = set()
    for entry in entries:
        require(isinstance(entry, dict), 'entries', 'entry object required')
        # Narrow candidates one field at a time so an operator sees the actual
        # mismatched matcher field, including for multi-model admission sets.
        candidates = baseline
        for field in SCOPE_FIELDS:
            value = entry.get(field)
            require(type(value) is (int if field in ('ram_bytes', 'qualified_slots') else str), field, 'invalid or missing value')
            candidates = [row for row in candidates if type(row.get(field)) is type(value) and row.get(field) == value]
            require(candidates, field, f"{entry.get('model_key', '<unknown>')} differs from signed release scope")
        for field in IDENTITY_FIELDS:
            require(isinstance(entry.get(field), str) and entry[field] == identity[field], field,
                    f"{entry['model_key']} differs from verified release identity")
        # The provider rejects the whole set if two entries select the same
        # runtime context, even when their wider admission sort keys differ.
        context = tuple(entry[field] for field in SCOPE_FIELDS + IDENTITY_FIELDS)
        require(context not in contexts, 'entries', f"{entry['model_key']} has ambiguous matching entries")
        contexts.add(context)


def release_directory(repo: pathlib.Path, state: pathlib.Path, explicit: pathlib.Path | None, version: str) -> pathlib.Path:
    if explicit:
        return explicit
    root = state / f'cli-release-{version}'
    for path in sorted(root.glob('candidate-*'), reverse=True):
        if (path / f'macprovider-cli-v{version}-darwin-arm64.tar.gz').is_file():
            return path
    cache = root / 'native-mtp-match-release'
    cache.mkdir(parents=True, exist_ok=True)
    names = ['pearl-release.json', 'pearl-release.json.sig', 'compatibility-set.json',
             'compatibility-artifact-index.json', 'macprovider-release-discovery.json',
             'macprovider-release-discovery.json.sig', 'native-mtp-admission.json',
             'native-mtp-admission.json.sig', f'macprovider-cli-v{version}-darwin-arm64.tar.gz']
    if not all((cache / name).is_file() for name in names):
        args = ['gh', 'release', 'download', f'v{version}', '-R', 'Augustas11/macprovider', '-D', str(cache), '--clobber']
        for name in names:
            args += ['-p', name]
        run(args, 'release_payload')
    return cache


def verify_release(repo: pathlib.Path, directory: pathlib.Path, commit: str, version: str) -> tuple[dict, dict, dict]:
    key = repo / 'ops/pearl-updater/release-signing-public.pem'
    discovery = load_module(repo, 'verify-release-discovery-transport')
    head = load_json(directory / 'macprovider-release-discovery.json')
    args = argparse.Namespace(head=directory / 'macprovider-release-discovery.json',
        signature=directory / 'macprovider-release-discovery.json.sig',
        artifact_index=directory / 'compatibility-artifact-index.json', public_key=key,
        repository='Augustas11/macprovider', target_tag=f'v{version}', target_commit=commit,
        minimum_sequence=0, allow_expired=True, openssl='openssl')
    discovery.verify_artifact_index(args)
    discovery.verify_head(args)
    index = load_json(args.artifact_index)
    tarball = directory / f'macprovider-cli-v{version}-darwin-arm64.tar.gz'
    for role, path in [('provider_cli', tarball), ('pearl_metadata', directory / 'pearl-release.json'),
                       ('pearl_metadata_signature', directory / 'pearl-release.json.sig'),
                       ('compatibility_manifest', directory / 'compatibility-set.json')]:
        record = index['artifacts'][role]
        require(record['name'] == path.name and digest(path) == record['sha256'], 'release_payload', f'{role} hash mismatch')
    run(['openssl', 'dgst', '-sha256', '-verify', str(key), '-signature', str(directory / 'pearl-release.json.sig'),
         str(directory / 'pearl-release.json')], 'release_signature')
    metadata = load_json(directory / 'pearl-release.json')
    require(metadata['commit'] == commit and metadata['tag'] == f'v{version}' and metadata['repository'] == 'Augustas11/macprovider',
            'source_commit', 'signed release identity differs')
    compatibility = load_module(repo, 'compatibility-set-manifest')
    manifest_path = directory / 'compatibility-set.json'
    manifest = compatibility.validate_envelope(manifest_path.read_bytes(), True)
    compatibility.verify_signature(manifest, key, 'openssl')
    require(manifest['signed']['release'] == dict(commit=commit, tag=f'v{version}', version=version, repository='Augustas11/macprovider'),
            'source_commit', 'compatibility manifest differs')
    code = load_module(repo, 'provider-code-identity')
    code.validate_identity(metadata['provider_code_identity'], tag=f'v{version}', binary_version=version)
    with tempfile.TemporaryDirectory(prefix='native-mtp-match-') as temp:
        root = pathlib.Path(temp)
        # Extract only named, unique regular members. Never unpack archive paths.
        with tarfile.open(tarball, 'r:gz') as archive:
            def member(name):
                matches = [m for m in archive.getmembers() if m.name.removeprefix('./') == name]
                require(len(matches) == 1 and matches[0].isfile() and 0 < matches[0].size <= 1024**3,
                        'release_payload', f'invalid member {name}')
                data = archive.extractfile(matches[0]).read()
                path = root / name.replace('/', '_')
                path.write_bytes(data)
                return path
            binary = member('macprovider-cli')
            require(digest(binary) == metadata['provider_code_identity']['binary_sha256'], 'binary_sha256', 'signed binary differs')
            require(member('compatibility-set.json').read_bytes() == manifest_path.read_bytes(), 'compatibility_manifest', 'payload differs')
            catalog = member('catalog-release/release.json')
            require(digest(catalog) == manifest['signed']['components']['catalog']['files']['release.json'], 'compatibility_manifest', 'catalog hash differs')
            keys_path = member('catalog-release/trusted-keys.json')
            require(digest(keys_path) == manifest['signed']['components']['catalog']['files']['trusted-keys.json'], 'trusted_keys', 'payload keyring differs')
            feeds = load_json(catalog)['feeds']
            scope = directory / 'native-mtp-admission.json'
            require(digest(scope) == feeds['native-mtp-admission.json']['sha256'], 'scope', 'release admission hash differs')
            catalog_tool = load_module(repo, 'catalog-release')
            keys = catalog_tool.keyring(keys_path)
            verify_admission_signature(catalog_tool, scope, pathlib.Path(str(scope) + '.sig'), keys)
            scope_doc = load_json(scope)
            metallib = digest(member('mlx.metallib'))
            decode = run([sys.executable, str(repo / 'scripts/decode_path_digest.py'), '--binary', str(binary)], 'decode_path_digest')
    return scope_doc, dict(decode_path_digest=decode, metallib_sha256=metallib), keys


def verify_admission_signature(catalog_tool, admission: pathlib.Path, signature: pathlib.Path, keys: dict) -> None:
    key_id, sig = catalog_tool.parse_sidecar(signature.read_bytes(), 'native-mtp-admission.json.sig')
    require(key_id in keys, 'admission_signature', 'unknown or retired signer')
    catalog_tool.verify_ed25519(keys[key_id], sig, admission.read_bytes(), 'admission_signature')


def verify(args: argparse.Namespace) -> None:
    repo = args.repo.resolve()
    release = load_json(args.release_input)
    commit = release['entry']['source_commit']
    runtime, version = source_identity(repo, commit)
    directory = release_directory(repo, args.state_dir, args.release_dir, version)
    scope, identity, keys = verify_release(repo, directory, commit, version)
    identity['runtime_revision'] = runtime
    signature = pathlib.Path(str(args.admission) + '.sig')
    if not signature.is_file():
        static = repo / 'phase3-binary/dist/static/native-mtp-admission.json'
        require(static.read_bytes() == args.admission.read_bytes(), 'admission_signature', 'unsigned admission differs from signed static feed')
        signature = pathlib.Path(str(static) + '.sig')
    catalog = load_module(repo, 'catalog-release')
    verify_admission_signature(catalog, args.admission, signature, keys)
    verify_entries(load_json(args.admission), scope, identity)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--release-input', type=pathlib.Path, required=True)
    parser.add_argument('--admission', type=pathlib.Path, required=True)
    parser.add_argument('--release-dir', type=pathlib.Path)
    parser.add_argument('--state-dir', type=pathlib.Path, default=pathlib.Path.home() / '.config/macprovider/ops-state')
    args = parser.parse_args()
    try:
        verify(args)
    except (MatchError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError, SystemExit, RuntimeError) as exc:
        print(f'blocked: {exc}')
        return 1
    print('ok')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
