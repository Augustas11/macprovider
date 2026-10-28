#!/usr/bin/env python3
"""Verify public-safe post-cut journey evidence under reviewed workflow controls.

Authenticated GitHub metadata is fetched by the existing protected workflow;
this consumer never downloads an arbitrary URL or executes bundle content.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

import native_mtp_journey_evidence as contract
import privacy_class_beta_journey_evidence as privacy

REPOSITORY = 'Augustas11/macprovider'
SCHEMA = 'macprovider.native-mtp-postcut-evidence.v1'
FIELDS = {'schema','repository','source_sha','acceptance_run_id','acceptance_run_attempt',
          'acceptance_tag','acceptance_control_commit','checksums_sha256','binary_sha256','code_cdhash',
          'decode_path_digest','metallib_sha256','ci_run_id','redacted_evidence_path','files'}
MAX_ARCHIVE = 64 << 20
MAX_FILES = 512
MAX_FILE = 8 << 20


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def load(path: Path) -> dict:
    return contract.parse_json(path.read_bytes(), str(path))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate_manifest(m: dict, source: str, redacted: str) -> None:
    require(isinstance(m,dict) and set(m)==FIELDS,'post-cut manifest fields differ')
    require(m['schema']==SCHEMA and m['repository']==REPOSITORY,'post-cut authority differs')
    require(re.fullmatch(r'[0-9a-f]{40}',source) is not None and m['source_sha']==source,'post-cut source differs')
    require(re.fullmatch(r'journeys/evidence/native-mtp-serving-[0-9]{8}T[0-9]{6}Z.redacted.json',redacted) is not None
            and m['redacted_evidence_path']==redacted,'post-cut evidence path differs')
    for key in ('acceptance_run_id','acceptance_run_attempt','ci_run_id'):
        require(type(m[key]) is int and m[key]>0,'invalid post-cut run identity')
    require(isinstance(m['acceptance_control_commit'],str) and re.fullmatch(r'[0-9a-f]{40}',m['acceptance_control_commit']) is not None,'invalid acceptance control commit')
    require(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',m['acceptance_tag']) is not None,'invalid acceptance tag')
    for key in ('checksums_sha256','binary_sha256','decode_path_digest','metallib_sha256'):
        require(isinstance(m[key],str) and re.fullmatch(r'[0-9a-f]{64}',m[key]) is not None,'invalid post-cut digest')
    require(isinstance(m['code_cdhash'],str) and re.fullmatch(r'[0-9a-f]{40}',m['code_cdhash']) is not None,'invalid code identity')
    require(isinstance(m['files'],dict) and 1<=len(m['files'])<MAX_FILES,'invalid post-cut file inventory')
    for path,digest in m['files'].items():
        require(isinstance(path,str) and isinstance(digest,str) and re.fullmatch(r'[0-9a-f]{64}',digest) is not None,'invalid inventory binding')
        require(path==redacted or path.startswith(redacted.removesuffix('.redacted.json')+'/'),'unexpected archive path')
        require(all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*',part) for part in path.split('/')),'unsafe archive path')


def archive_bytes(archive: Path, expected_sha: str, source: str, redacted: str) -> tuple[dict,dict[str,bytes]]:
    st=archive.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink==1 and st.st_size<=MAX_ARCHIVE,'unsafe/oversized post-cut archive')
    data=archive.read_bytes()
    require(re.fullmatch(r'[0-9a-f]{64}',expected_sha) is not None and sha(data)==expected_sha,'post-cut archive digest differs')
    files={};total=0
    with zipfile.ZipFile(archive) as z:
        require(1<len(z.infolist())<=MAX_FILES,'post-cut archive file count exceeds bound')
        for item in z.infolist():
            path=PurePosixPath(item.filename)
            require(not item.is_dir() and not path.is_absolute() and str(path)==item.filename and '..' not in path.parts,'unsafe ZIP path')
            mode=item.external_attr>>16
            require(not mode or stat.S_IFMT(mode) in (0,stat.S_IFREG),'ZIP member is not regular')
            require(item.filename not in files and not item.flag_bits&1,'duplicate/encrypted ZIP member')
            require(item.file_size<=MAX_FILE,'ZIP member exceeds byte bound')
            total+=item.file_size
            require(total<=MAX_ARCHIVE,'ZIP expanded bytes exceed bound')
            files[item.filename]=z.read(item)
    require('postcut-manifest.json' in files,'post-cut manifest missing')
    try:
        privacy.assert_bundle_redacted(privacy.Bundle('postcut',files,b''))
    except privacy.PrivacyEvidenceError as exc:
        raise ValueError(str(exc)) from exc
    m=contract.parse_json(files.pop('postcut-manifest.json'),'postcut-manifest.json')
    validate_manifest(m,source,redacted)
    require(set(files)==set(m['files']),'post-cut inventory differs')
    require(all(sha(data)==m['files'][path] for path,data in files.items()),'post-cut file digest differs')
    provenance=redacted.removesuffix('.redacted.json')+'/postcut-provenance.json'
    require(provenance in files and contract.parse_json(files[provenance],provenance)=={k:v for k,v in m.items() if k!='files'},'signed bundle lacks exact post-cut provenance')
    return m,files


def validate_metadata(m: dict, asset: dict, release: dict, asset_id: int, release_id: int,
                      archive_size: int, archive_sha: str, candidate: dict, artifacts: dict, ci: dict) -> None:
    require(release.get('id')==release_id and release.get('draft') is True and release.get('target_commitish')==m['source_sha'], 'evidence staging release identity differs')
    require(asset.get('id')==asset_id and asset.get('state')=='uploaded' and asset.get('size')==archive_size,'evidence asset identity differs')
    require(asset.get('digest')=='sha256:'+archive_sha,'authenticated evidence asset digest differs')
    require(any(a.get('id')==asset_id and a.get('digest')==asset.get('digest') for a in release.get('assets',[])), 'asset is not in the authenticated staging release')
    require(candidate.get('id')==m['acceptance_run_id'] and candidate.get('run_attempt')==m['acceptance_run_attempt'], 'acceptance run differs')
    for row,path in ((candidate,'.github/workflows/acceptance-candidate.yml'),(ci,'.github/workflows/ci.yml')):
        require(row.get('path')==path and row.get('status')=='completed' and row.get('conclusion')=='success'
                and row.get('head_sha')==(m['acceptance_control_commit'] if row is candidate else m['source_sha']) and row.get('head_branch')=='main'
                and row.get('repository',{}).get('full_name')==REPOSITORY,'post-cut workflow provenance differs')
    require(candidate.get('event')=='workflow_dispatch' and ci.get('event')=='push' and ci.get('id')==m['ci_run_id'],'post-cut CI/run event differs')
    matches=[a for a in artifacts.get('artifacts',[]) if a.get('name')=='acceptance-candidate-'+m['source_sha']]
    require(len(matches)==1 and matches[0].get('expired') is False
            and matches[0].get('workflow_run',{}).get('id')==m['acceptance_run_id']
            and matches[0].get('workflow_run',{}).get('head_sha')==m['acceptance_control_commit'],'acceptance artifact provenance differs')


def verify_candidate(root: Path, candidate_dir: Path, m: dict) -> None:
    tool=root/'scripts/verify-acceptance-promotion.py'
    args=['--directory',str(candidate_dir),'--repository',REPOSITORY,'--run-id',str(m['acceptance_run_id']),
          '--run-attempt',str(m['acceptance_run_attempt']),'--tag',m['acceptance_tag'],
          '--candidate-sha',m['source_sha'],'--control-sha',m['acceptance_control_commit'],
          '--expected-checksums-sha256',m['checksums_sha256'],
          '--release-public-key',str(root/'ops/pearl-updater/release-signing-public.pem')]
    subprocess.run([sys.executable,str(tool),'verify-directory',*args],check=True,timeout=180)
    acceptance=load(candidate_dir/'acceptance-candidate.json')
    names=(candidate_dir/'release-assets.txt').read_text().splitlines()
    subprocess.run(['bash',str(root/'scripts/verify-release-checksums.sh'),'--acceptance-candidate',
                    str(candidate_dir/'acceptance-candidate.json'),acceptance['candidate_ref'],
                    str(m['acceptance_run_id']),str(m['acceptance_run_attempt']),m['acceptance_control_commit'],
                    str(candidate_dir/'checksums.txt'),str(candidate_dir/'acceptance-candidate.json.sig'),
                    str(candidate_dir/'release-provenance.json'),REPOSITORY,m['acceptance_tag'],m['source_sha'],
                    *(str(candidate_dir/name) for name in names)],check=True,timeout=180)
    identity=load(candidate_dir/'pearl-release.json')['provider_code_identity']
    require(identity['binary_sha256']==m['binary_sha256'] and any(s.get('code_cdhash')==m['code_cdhash'] for s in identity['slices']),'signed acceptance code identity differs')
    with tarfile.open(candidate_dir/identity['asset'],'r:gz') as archive:
        members=archive.getmembers()
        require(len(members)<=4096,'candidate archive inventory too large')
        def member(name: str) -> bytes:
            rows=[row for row in members if row.name.removeprefix('./')==name]
            require(len(rows)==1 and rows[0].isfile() and rows[0].size<=512<<20,'candidate runtime member is unsafe')
            content=archive.extractfile(rows[0])
            require(content is not None,'candidate runtime member missing')
            return content.read()
        require(sha(member('mlx.metallib'))==m['metallib_sha256'],'accepted Metal library differs')
        with tempfile.TemporaryDirectory(prefix='native-mtp-candidate-identity.') as directory:
            binary=Path(directory)/'macprovider-cli';binary.write_bytes(member(identity['member']))
            embedded=subprocess.check_output([sys.executable,str(root/'scripts/decode_path_digest.py'),'--binary',str(binary)],cwd=root,text=True).strip()
            require(embedded==m['decode_path_digest'],'accepted embedded decode digest differs')


def verify_bindings(root: Path, redacted: str, m: dict, *, evidence_root: Path | None = None) -> None:
    evidence_root=evidence_root or root
    evidence=load(evidence_root/redacted)
    bundle=contract.validate_evidence(evidence_root,contract.SERVING,redacted,evidence)
    step,_=contract.step_artifact(bundle,'step-01-bind-tuple')
    entry,_=contract.validated_sidecar_entry(bundle.require('native-mtp-admission.json'),step['details'].get('entry_index'))
    for field,key in (('source_commit','source_sha'),('reproducible_build_sha256','binary_sha256'),
                      ('live_executable_cdhash','code_cdhash'),('decode_path_digest','decode_path_digest'),('metallib_sha256','metallib_sha256')):
        require(entry.get(field)==m[key],'sidecar differs from post-cut '+field)
    actual=contract.source_decode_digest(root,m['source_sha'])
    require(actual==m['decode_path_digest'],'reviewed source decode digest differs')


def stage(args: argparse.Namespace) -> None:
    root=args.root.resolve()
    require(subprocess.run(['git','merge-base','--is-ancestor',args.source_sha,'HEAD'],cwd=root).returncode==0,'post-cut source must be reviewed-main ancestor')
    m,files=archive_bytes(args.archive,args.archive_sha256,args.source_sha,args.redacted)
    validate_metadata(m,load(args.asset_json),load(args.release_json),args.asset_id,args.release_id,
                      args.archive.stat().st_size,args.archive_sha256,load(args.candidate_run_json),load(args.candidate_artifacts_json),load(args.ci_run_json))
    require(subprocess.run(['git','merge-base','--is-ancestor',m['acceptance_control_commit'],'HEAD'],cwd=root).returncode==0,'acceptance controls must be reviewed-main ancestor')
    verify_candidate(root,args.candidate_dir,m)
    # Never overwrite checkout files or traverse symlink parents. Archive bytes
    # remain data and can only create the reviewed evidence prefix.
    for name,data in files.items():
        target=root/name
        require(not target.exists() and not target.is_symlink(),'post-cut path already exists')
        parent=root
        for part in PurePosixPath(name).parts[:-1]:
            parent/=part
            require(not parent.is_symlink(),'post-cut parent is a symlink')
            parent.mkdir(exist_ok=True)
        fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as out:out.write(data)
    verify_bindings(root,args.redacted,m)
    receipt=root/args.redacted.removesuffix('.redacted.json')/'postcut-provenance.json'
    print(str(receipt.relative_to(root)))


def main() -> None:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path('.'))
    p.add_argument('--archive',type=Path,required=True);p.add_argument('--archive-sha256',required=True)
    p.add_argument('--source-sha',required=True);p.add_argument('--redacted',required=True)
    p.add_argument('--asset-id',type=int,required=True);p.add_argument('--release-id',type=int,required=True)
    for name in ('asset-json','release-json','candidate-run-json','candidate-artifacts-json','ci-run-json','candidate-dir'):
        p.add_argument('--'+name,type=Path,required=True)
    try:stage(p.parse_args())
    except (ValueError,OSError,subprocess.SubprocessError,zipfile.BadZipFile) as exc:p.exit(1,'post-cut evidence: '+str(exc)+'\n')


if __name__=='__main__':main()
