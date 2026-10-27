#!/usr/bin/env python3
"""Authenticate a frozen signed serving export before sealing a candidate.

No evidence is installed into the caller's checkout. GitHub reads are mandatory;
no offline/caller-attested success mode exists.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

REPOSITORY = 'Augustas11/macprovider'
WORKFLOW = '.github/workflows/promote-signed-native-mtp-serving-journey.yml'
SCHEMA = 'macprovider.native-mtp-signed-serving-proof.v1'
PUBLIC_KEY_SHA256 = '849e9c9bc53db1fb8e28d3b46ab431089b12cb50b398c5317ced682d39bdbd38'
MAX_BYTES = 64 << 20
MAX_FILE = 8 << 20
MAX_FILES = 512
MANIFEST_FIELDS = {'schema_version','source_sha','evidence_sha','requirement_ids','journey_id',
                   'redacted_artifact','redacted_sha256','redaction_manifest','redaction_manifest_sha256',
                   'signed_envelope','signed_envelope_sha256','workflow_run_id','workflow_run_attempt'}


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse(data: bytes) -> dict:
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    value = json.loads(data, object_pairs_hook=unique)
    require(isinstance(value, dict), 'expected JSON object')
    return value


def regular(path: Path, limit: int) -> bytes:
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_size <= limit,
            'proof input must be a bounded regular file')
    return path.read_bytes()


def gh(endpoint: str) -> dict:
    return parse(subprocess.check_output(['gh','api',f'repos/{REPOSITORY}/{endpoint}'], timeout=60))


def authenticate(receipt: dict, source: str) -> tuple[dict, dict]:
    require(set(receipt) == {'schema','run_id','artifact_id','export_sha256'} and receipt['schema'] == SCHEMA,
            'proof receipt fields differ')
    for field in ('run_id','artifact_id'):
        require(type(receipt[field]) is int and receipt[field] > 0, 'invalid proof run/artifact ID')
    require(isinstance(receipt['export_sha256'],str) and re.fullmatch('[0-9a-f]{64}',receipt['export_sha256']) is not None,
            'invalid export digest')
    run = gh(f"actions/runs/{receipt['run_id']}")
    require(run.get('id') == receipt['run_id'] and run.get('status') == 'completed' and run.get('conclusion') == 'success'
            and run.get('event') == 'workflow_dispatch' and run.get('head_branch') == 'main'
            and run.get('path') == WORKFLOW and run.get('repository',{}).get('full_name') == REPOSITORY
            and run.get('head_repository',{}).get('full_name') == REPOSITORY,
            'serving signing run is not the successful reviewed main workflow')
    control = run.get('head_sha','')
    require(re.fullmatch('[0-9a-f]{40}',control) is not None and type(run.get('run_attempt')) is int and run['run_attempt'] > 0,
            'invalid signing controls/run attempt')
    compare = gh(f'compare/{control}...main')
    require(compare.get('status') in ('ahead','identical') and compare.get('merge_base_commit',{}).get('sha') == control,
            'signing controls are not reviewed main ancestry')
    artifact = gh(f"actions/artifacts/{receipt['artifact_id']}")
    require(artifact.get('id') == receipt['artifact_id'] and artifact.get('name') == f'signed-native-mtp-serving-journey-evidence-{source}'
            and artifact.get('expired') is False and artifact.get('digest') == 'sha256:' + receipt['export_sha256']
            and artifact.get('workflow_run',{}).get('id') == receipt['run_id']
            and artifact.get('workflow_run',{}).get('head_sha') == control,
            'serving export artifact provenance differs')
    return run, artifact


def export_bytes(path: Path, digest: str) -> dict[str, bytes]:
    data = regular(path, MAX_BYTES)
    require(sha(data) == digest, 'export ZIP digest differs')
    files = {}; total = 0
    with zipfile.ZipFile(path) as archive:
        require(1 < len(archive.infolist()) <= MAX_FILES, 'export member count exceeds bound')
        for item in archive.infolist():
            name = PurePosixPath(item.filename)
            require(not item.is_dir() and not name.is_absolute() and str(name) == item.filename and '..' not in name.parts
                    and all(re.fullmatch('[A-Za-z0-9][A-Za-z0-9._-]*', part) for part in name.parts), 'unsafe export path')
            require(item.filename not in files and not item.flag_bits & 1, 'duplicate/encrypted export member')
            require(stat.S_IFMT(item.external_attr >> 16) in (0,stat.S_IFREG), 'nonregular export member')
            total += item.file_size
            require(item.file_size <= MAX_FILE and total <= MAX_BYTES, 'export expanded bytes exceed bound')
            files[item.filename] = archive.read(item)
    return files


def validate_manifest(files: dict[str, bytes], receipt: dict, run: dict, source: str) -> dict:
    require('evidence-manifest.json' in files, 'export manifest missing')
    m = parse(files['evidence-manifest.json'])
    require(set(m) == MANIFEST_FIELDS and m['schema_version'] == 'macprovider.signed-native-mtp-serving-journey-evidence.v1'
            and m['source_sha'] == source and m['evidence_sha'] == run['head_sha']
            and m['workflow_run_id'] == str(receipt['run_id']) and m['workflow_run_attempt'] == str(run['run_attempt'])
            and m['journey_id'] == 'JOURNEY-NATIVE-MTP-SERVING', 'export manifest authority differs')
    redacted = m['redacted_artifact']
    require(isinstance(redacted,str) and re.fullmatch(r'journeys/evidence/native-mtp-serving-[0-9]{8}T[0-9]{6}Z.redacted.json',redacted) is not None,
            'unexpected serving evidence path')
    bundle = redacted.removesuffix('.redacted.json')
    require(m['redaction_manifest'] == bundle + '/MANIFEST.sha256' and m['signed_envelope'] == bundle + '.journey-result.signed.json',
            'export manifest paths differ')
    for path_key, digest_key in (('redacted_artifact','redacted_sha256'),('redaction_manifest','redaction_manifest_sha256'),('signed_envelope','signed_envelope_sha256')):
        require(m[path_key] in files and sha(files[m[path_key]]) == m[digest_key], 'export bound file digest differs')
    require(all(p in {'evidence-manifest.json',redacted,m['signed_envelope']} or p.startswith(bundle + '/') for p in files),
            'unexpected export file')
    return m


def validate_checkout(root: Path, files: dict[str, bytes], m: dict, run: dict, sidecar: bytes) -> dict:
    # Execute only authenticated reviewed-main tools, never archive executable data.
    require(sha((root/'security/acceptance-candidate-signing-public.pem').read_bytes()) == PUBLIC_KEY_SHA256,
            'trusted serving signing key changed')
    bundle = m['redacted_artifact'].removesuffix('.redacted.json')
    require(files.get(bundle + '/native-mtp-admission.json') == sidecar, 'serving qualification sidecar differs from candidate')
    for name, data in files.items():
        if name == 'evidence-manifest.json':
            continue
        target = root/name
        require(not target.exists() and not target.is_symlink(), 'export would overwrite reviewed checkout')
        parent = root
        for part in PurePosixPath(name).parts[:-1]:
            parent /= part
            require(not parent.is_symlink(), 'export parent symlink')
            parent.mkdir(exist_ok=True)
        target.write_bytes(data)
    subprocess.run([sys.executable,'-c',
                    'import sys; from pathlib import Path; sys.path.insert(0, str(Path(sys.argv[1])/"scripts")); '
                    'import privacy_class_beta_journey_evidence as p; '
                    'root=Path(sys.argv[1]); names=sys.argv[2:]; '
                    'p.assert_bundle_redacted(p.Bundle("signed-serving-export", {n:(root/n).read_bytes() for n in names}, b""))',
                    str(root),*[n for n in files if n != 'evidence-manifest.json']],cwd=root,check=True)
    envelope = parse(files[m['signed_envelope']])
    signatures = envelope.get('signatures')
    require(isinstance(signatures,list) and len(signatures) == 1
            and signatures[0].get('verifier') == f"{WORKFLOW}:{run['id']}:{run['run_attempt']}", 'signed verifier run differs')
    provenance = bundle + '/postcut-provenance.json'
    require(provenance in files, 'signed post-cut provenance missing')
    # Build before signature validation: this reopens every genuine step, policy,
    # tuple, qualification source and actual decode identity with no pass override.
    output = root/'serving-proof-payload.json'
    subprocess.run([sys.executable,str(root/'scripts/build-native-mtp-journey-result.py'),'--root',str(root),
                    'payload','serving',m['redacted_artifact'],'--source-sha',m['source_sha'],
                    '--evidence-sha',m['evidence_sha'],'--postcut-provenance',provenance,'--output',str(output)],cwd=root,check=True)
    payload = parse(output.read_bytes())
    require(payload == envelope.get('signed'), 'signed journey differs from complete builder projection')
    requirements = payload.get('requirement_ids')
    require(requirements == m['requirement_ids'] and isinstance(requirements,list) and requirements,
            'export requirements differ')
    subprocess.run([sys.executable,str(root/'scripts/validate-signed-journey-result.py'),'--root',str(root),
                    '--requirement-ids',','.join(requirements),m['signed_envelope']],cwd=root,check=True)
    return payload


def verify_serving_proof(proof_dir: Path, repo: Path, source_commit: str, sidecar_path: Path) -> dict:
    require(re.fullmatch('[0-9a-f]{40}',source_commit) is not None, 'invalid candidate source')
    proof_dir, repo = Path(proof_dir), Path(repo).resolve()
    require(proof_dir.is_dir() and not proof_dir.is_symlink(), 'proof directory is not regular')
    receipt = parse(regular(proof_dir/'receipt.json',MAX_FILE))
    run, artifact = authenticate(receipt,source_commit)
    files = export_bytes(proof_dir/'export.zip',receipt['export_sha256'])
    require(artifact.get('size_in_bytes') == (proof_dir/'export.zip').stat().st_size, 'export artifact size differs')
    m = validate_manifest(files,receipt,run,source_commit)
    sidecar = regular(Path(sidecar_path),MAX_FILE)
    with tempfile.TemporaryDirectory(prefix='native-mtp-serving-proof.') as directory:
        checkout = Path(directory)/'reviewed'
        subprocess.run(['git','-c','core.hooksPath=/dev/null','clone','--shared','--no-checkout','--quiet',str(repo),str(checkout)],check=True)
        subprocess.run(['git','-c','core.hooksPath=/dev/null','checkout','--quiet','--detach',run['head_sha']],cwd=checkout,check=True)
        subprocess.run(['git','merge-base','--is-ancestor',source_commit,run['head_sha']],cwd=checkout,check=True)
        payload = validate_checkout(checkout,files,m,run,sidecar)
    return {**receipt,'source_commit':source_commit,'control_commit':run['head_sha'],
            'run_attempt':run['run_attempt'],'native_mtp_admission_tuple':payload['environment']['candidate'],
            'signed_envelope_sha256':m['signed_envelope_sha256']}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('proof_dir',type=Path)
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--source-commit',required=True)
    parser.add_argument('--sidecar',type=Path,required=True)
    args = parser.parse_args()
    try:
        result = verify_serving_proof(args.proof_dir,args.repo,args.source_commit,args.sidecar)
    except (ValueError,OSError,subprocess.CalledProcessError,zipfile.BadZipFile) as exc:
        parser.exit(1,f'signed serving proof: {exc}\n')
    print(json.dumps(result,sort_keys=True))


if __name__ == '__main__':
    main()
