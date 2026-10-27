#!/usr/bin/env python3
"""Public-safe post-cut evidence transport, invoked only by the CLI ops train."""
from __future__ import annotations
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from types import SimpleNamespace

import native_mtp_journey_evidence as contract
import native_mtp_postcut_evidence as consumer
import privacy_class_beta_journey_evidence as privacy

REPO = consumer.REPOSITORY
WORKFLOW = 'promote-signed-native-mtp-serving-journey.yml'
WORKFLOW_PATH = '.github/workflows/' + WORKFLOW
STATE_SCHEMA = 'macprovider.native-mtp-postcut-upload.v1'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def gh(path, *, method='GET', payload=None):
    args = ['gh', 'api', '--method', method, path]
    if payload is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=None if payload is None else canonical(payload),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=60)
    return json.loads(result.stdout) if result.stdout.strip() else None


def pages(path, key=None):
    rows=[]
    for page in range(1, 101):
        data=gh(path + ('&' if '?' in path else '?') + f'per_page=100&page={page}')
        batch=data[key] if key else data
        require(isinstance(batch,list),'authenticated list shape differs')
        rows.extend(batch)
        if len(batch)<100:return rows
    raise ValueError('authenticated list exceeds page bound')


def load(path):
    return contract.parse_json(Path(path).read_bytes(), 'local evidence metadata')


def regular(path, limit):
    st=path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink==1 and st.st_size<=limit,'unsafe local input')
    return path.read_bytes()


def atomic_state(directory, value):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    st=directory.lstat()
    require(stat.S_ISDIR(st.st_mode) and st.st_uid==os.getuid() and not st.st_mode&0o077,'unsafe ops state directory')
    target=directory/'state.json'
    fd,name=tempfile.mkstemp(prefix='.state-',dir=directory)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(canonical(value));out.flush();os.fsync(out.fileno())
        os.replace(name,target)
        fd=os.open(directory,os.O_RDONLY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if os.path.exists(name):os.unlink(name)


def read_state(directory):
    path=directory/'state.json'
    if not path.exists():return None
    raw=regular(path,1<<20)
    st=path.stat()
    require(st.st_uid==os.getuid() and not st.st_mode&0o077,'unsafe ops state file')
    state=contract.parse_json(raw,'ops transport state')
    require(state.get('schema')==STATE_SCHEMA,'unknown ops transport state')
    return state


def run_identity(row, source, workflow, event):
    require(row.get('path')==workflow and row.get('head_sha')==source
            and row.get('head_branch')=='main' and row.get('event')==event
            and row.get('repository',{}).get('full_name')==REPO,'authenticated workflow provenance differs')


def evidence_path(root, evidence):
    path=Path(evidence)
    path=path if path.is_absolute() else root/path
    require(re.fullmatch(r'native-mtp-serving-[0-9]{8}T[0-9]{6}Z.redacted.json',path.name) is not None,'local evidence filename differs')
    for parent in (path,*path.parents):
        require(not parent.is_symlink(),'local evidence path traverses a symlink')
    return path


@contextlib.contextmanager
def input_tree(root, evidence):
    source=evidence_path(root,evidence)
    document=regular(source,consumer.MAX_FILE)
    relative='journeys/evidence/'+source.name
    prefix=relative.removesuffix('.redacted.json')
    directory=source.parent/source.name.removesuffix('.redacted.json')
    require(directory.is_dir() and not directory.is_symlink(),'local evidence bundle absent or unsafe')
    with tempfile.TemporaryDirectory(prefix='native-mtp-public-stage.') as tmp:
        target=Path(tmp);out=target/relative;out.parent.mkdir(parents=True);out.write_bytes(document)
        count=1;total=len(document)
        for path in sorted(directory.rglob('*')):
            require(not path.is_symlink(),'local evidence bundle symlink')
            if path.is_dir():continue
            data=regular(path,consumer.MAX_FILE);count+=1;total+=len(data)
            require(count<consumer.MAX_FILES and total<=consumer.MAX_ARCHIVE,'local evidence bundle exceeds bounds')
            relative_file=path.relative_to(directory)
            require(all(contract.SAFE_COMPONENT_RE.fullmatch(part) for part in relative_file.parts),'unsafe local evidence member')
            dest=target/prefix/relative_file;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
        yield target,relative,document


def binding(root, evidence, marker, *, evidence_root=None):
    require(subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
            ==subprocess.check_output(['git','rev-parse','origin/main'],cwd=root,text=True).strip(),
            'ops source must equal reviewed merged origin/main')
    mark=load(marker)
    source=mark.get('candidate_sha')
    require(isinstance(source,str) and re.fullmatch(r'[0-9a-f]{40}',source),'invalid candidate source')
    require(subprocess.run(['git','merge-base','--is-ancestor',source,'origin/main'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0,'candidate source is not reviewed merged main')
    evidence_root=evidence_root or root
    obj=load(evidence_root/evidence)
    bundle=contract.validate_evidence(evidence_root,contract.SERVING,evidence,obj)
    step,_=contract.step_artifact(bundle,'step-01-bind-tuple')
    entry,_=contract.validated_sidecar_entry(bundle.require('native-mtp-admission.json'),step['details'].get('entry_index'))
    require(mark.get('candidate_sha')==source and mark.get('binary_sha256')==entry['reproducible_build_sha256'],
            'signed-byte marker differs from serving evidence')
    match=re.fullmatch(re.escape(REPO)+r':(v[0-9]+\.[0-9]+\.[0-9]+)@'+source,mark.get('compatibility_set_id',''))
    require(match is not None,'signed-byte marker compatibility identity differs')
    candidate=gh(f'repos/{REPO}/actions/runs/{int(mark["run_id"])}')
    control=candidate.get('head_sha')
    require(isinstance(control,str) and re.fullmatch(r'[0-9a-f]{40}',control),'invalid acceptance control commit')
    require(subprocess.run(['git','merge-base','--is-ancestor',control,'origin/main'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0,'acceptance controls are not reviewed merged main')
    run_identity(candidate,control,'.github/workflows/acceptance-candidate.yml','workflow_dispatch')
    require(candidate.get('status')=='completed' and candidate.get('conclusion')=='success','candidate is not successful')
    cis=pages(f'repos/{REPO}/actions/workflows/ci.yml/runs?head_sha={source}&event=push', 'workflow_runs')
    cis=[row for row in cis if row.get('status')=='completed' and row.get('conclusion')=='success' and row.get('head_sha')==source]
    require(bool(cis),'successful merged-source CI is absent')
    ci=gh(f'repos/{REPO}/actions/runs/{cis[0]["id"]}')
    run_identity(ci,source,'.github/workflows/ci.yml','push')
    m=dict(schema=consumer.SCHEMA,repository=REPO,source_sha=source,
           acceptance_run_id=candidate['id'],acceptance_run_attempt=candidate['run_attempt'],
           acceptance_control_commit=control,
           acceptance_tag=match.group(1),checksums_sha256=mark['checksums_sha256'],
           binary_sha256=entry['reproducible_build_sha256'],code_cdhash=entry['live_executable_cdhash'],
           decode_path_digest=entry['decode_path_digest'],metallib_sha256=entry['metallib_sha256'],
           ci_run_id=ci['id'],redacted_evidence_path=evidence)
    consumer.verify_candidate(root,Path(mark['bytes_dir']),m)
    consumer.verify_bindings(root,evidence,m,evidence_root=evidence_root)
    artifacts=gh(f'repos/{REPO}/actions/runs/{candidate["id"]}/artifacts')
    matches=[a for a in artifacts.get('artifacts',[]) if a.get('name')=='acceptance-candidate-'+source]
    require(len(matches)==1 and matches[0].get('expired') is False
            and matches[0].get('workflow_run',{}).get('id')==candidate['id']
            and matches[0].get('workflow_run',{}).get('head_sha')==control,'acceptance artifact is absent, expired or unbound')
    require(entry['source_commit']==source,'serving source differs from merged source')
    return m,bundle,obj


def assert_public(files):
    try:
        privacy.assert_bundle_redacted(SimpleNamespace(files=files))
    except privacy.PrivacyEvidenceError as exc:
        raise ValueError(str(exc)) from exc


def public_archive(root, evidence, metadata, bundle, original):
    """Reproject only the validated public evidence; never archive a directory."""
    prefix=contract.bundle_dir_for_source(contract.SERVING,evidence)
    files=dict(bundle.files)
    provenance=canonical(metadata)
    if 'postcut-provenance.json' in files:
        require(files['postcut-provenance.json']==provenance,'existing provenance differs')
    files['postcut-provenance.json']=provenance
    updated=contract.Bundle(prefix,files,contract.manifest_bytes(files))
    projected=contract.compose_serving(updated,captured_at=original['captured_at'],expires_at=original['expires_at'])
    public={evidence:canonical(projected),prefix+'/'+contract.MANIFEST_NAME:updated.manifest,
            **{prefix+'/'+name:data for name,data in files.items()}}
    # Apply the established public bundle scan to EVERY byte, including the
    # evidence document and newly derived public provenance. Draft is not privacy.
    assert_public(public)
    m=dict(metadata,files={name:consumer.sha(data) for name,data in public.items()})
    consumer.validate_manifest(m,metadata['source_sha'],evidence)
    assert_public({'postcut-manifest.json':canonical(m)})
    public['postcut-manifest.json']=canonical(m)
    require(len(public)<=consumer.MAX_FILES and sum(map(len,public.values()))<=consumer.MAX_ARCHIVE,'public inventory exceeds bounds')
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_DEFLATED) as archive:
        for name,data in sorted(public.items()):
            require(len(data)<=consumer.MAX_FILE,'public file exceeds bound')
            item=zipfile.ZipInfo(name,(1980,1,1,0,0,0));item.external_attr=(stat.S_IFREG|0o600)<<16
            item.compress_type=zipfile.ZIP_DEFLATED
            archive.writestr(item,data)
    result=stream.getvalue()
    require(len(result)<=consumer.MAX_ARCHIVE,'public archive exceeds bound')
    return m,result


def title(source,digest):
    return 'native-mtp-postcut-'+source+'-'+digest


def matching_runs(source,digest,root):
    # Dispatch runs on reviewed main, which may be newer than the candidate.
    # The immutable title binds candidate source and uploaded archive bytes.
    runs=pages(f'repos/{REPO}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch','workflow_runs')
    hits=[r for r in runs if r.get('display_title')==title(source,digest)]
    require(len(hits)<=1,'multiple dispatch runs match immutable upload identity')
    if not hits:return None
    run=gh(f'repos/{REPO}/actions/runs/{hits[0]["id"]}')
    control=run.get('head_sha')
    require(isinstance(control,str) and re.fullmatch(r'[0-9a-f]{40}',control),'invalid signed journey control commit')
    require(subprocess.run(['git','merge-base','--is-ancestor',control,'origin/main'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0,'journey controls are not reviewed merged main')
    require(subprocess.run(['git','merge-base','--is-ancestor',source,control],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0,'candidate source is not an ancestor of journey controls')
    run_identity(run,control,WORKFLOW_PATH,'workflow_dispatch')
    require(run.get('display_title')==title(source,digest),'dispatch title differs')
    return run


def report(state,root):
    if state is None:return {'status':'absent'}
    run=matching_runs(state['source_sha'],state['archive_sha256'],root)
    if run is None:return dict(state,status='dispatch_pending' if state.get('dispatch_pending') else 'staged')
    if state.get('run_id') is not None:require(state['run_id']==run['id'],'dispatch run changed')
    status='running'
    if run.get('status')=='completed':status='success' if run.get('conclusion')=='success' else 'failure'
    return dict(state,status=status,run_id=run['id'],run_attempt=run['run_attempt'])


def require_ops_lock(root):
    result=subprocess.check_output(['bash',str(root/'scripts/ops/live-lock.sh'),'status'],text=True,timeout=10)
    status=json.loads(result)
    lock=status.get('lock') or {}
    require(status.get('held') is True and status.get('stale') is False
            and lock.get('owner')==os.environ.get('MACPROVIDER_OPS_OWNER')
            and lock.get('purpose')=='cli-release:native_mtp_postcut',
            'post-cut upload requires the current CLI ops live lock')


def upload(args):
    require(os.environ.get('MACPROVIDER_OPS_ENTRYPOINT')=='1' and bool(os.environ.get('MACPROVIDER_OPS_OWNER')),
            'post-cut upload requires guarded scripts/ops next --run')
    require_ops_lock(args.root)
    with input_tree(args.root,args.evidence) as (evidence_root,redacted,document):
        m,bundle,obj=binding(args.root,redacted,args.candidate_marker,evidence_root=evidence_root)
        manifest,data=public_archive(evidence_root,redacted,m,bundle,obj)
    digest=consumer.sha(data)
    with tempfile.TemporaryDirectory(prefix='native-mtp-public-check.') as tmp:
        archive=Path(tmp)/'public.zip';archive.write_bytes(data)
        consumer.archive_bytes(archive,digest,m['source_sha'],redacted)
    state=read_state(args.state_dir)
    fingerprint=dict(source_sha=m['source_sha'],archive_sha256=digest,evidence_sha256=consumer.sha(document))
    if state is not None:
        require(all(state.get(k)==v for k,v in fingerprint.items()),'immutable upload intent changed; existing transaction cannot be replaced')
        current=report(state,args.root)
        if current['status'] in {'success','failure','running','dispatch_pending'}:return current
    else:
        state=dict(schema=STATE_SCHEMA,**fingerprint)
        atomic_state(args.state_dir,state)
    require_ops_lock(args.root)
    tag='native-mtp-evidence-'+m['source_sha']+'-'+digest[:16]
    releases=[r for r in pages(f'repos/{REPO}/releases') if r.get('tag_name')==tag]
    require(len(releases)<=1,'ambiguous draft staging release')
    release=releases[0] if releases else gh(f'repos/{REPO}/releases',method='POST',payload=dict(tag_name=tag,target_commitish=m['source_sha'],name='Public-safe native MTP evidence',draft=True,prerelease=True))
    require(release.get('draft') is True and release.get('target_commitish')==m['source_sha'],'staging release is not the bound draft')
    name='native-mtp-postcut-'+digest+'.zip'
    assets=[a for a in gh(f'repos/{REPO}/releases/{release["id"]}/assets') if a.get('name')==name]
    require(len(assets)<=1,'ambiguous evidence asset')
    if not assets:
        with tempfile.TemporaryDirectory(prefix='native-mtp-public-upload.') as tmp:
            archive=Path(tmp)/name;archive.write_bytes(data)
            subprocess.run(['gh','release','upload',tag,str(archive),'--repo',REPO],check=True,timeout=120)
        assets=[a for a in gh(f'repos/{REPO}/releases/{release["id"]}/assets') if a.get('name')==name]
    require(len(assets)==1,'uploaded evidence asset is absent')
    asset=assets[0]
    require(asset.get('digest')=='sha256:'+digest and asset.get('state')=='uploaded' and asset.get('size')==len(data), 'existing asset differs; immutable assets are never overwritten')
    state.update(release_id=release['id'],asset_id=asset['id'],dispatch_pending=True)
    # Commit intent before POST. On an ambiguous network result, subsequent
    # runs only discover the exact fingerprint; they never duplicate dispatch.
    atomic_state(args.state_dir,state)
    require_ops_lock(args.root)
    gh(f'repos/{REPO}/actions/workflows/{WORKFLOW}/dispatches',method='POST',payload=dict(ref='main',inputs=dict(source_sha=m['source_sha'],redacted_evidence_path=redacted,evidence_confirmed='true',postcut_asset_id=str(asset['id']),postcut_asset_sha256=digest,postcut_release_id=str(release['id']))))
    return report(state,args.root)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('command',choices=['status','upload'])
    p.add_argument('--root',type=Path,required=True);p.add_argument('--evidence',required=True)
    p.add_argument('--candidate-marker',type=Path,required=True);p.add_argument('--state-dir',type=Path,required=True)
    args=p.parse_args();args.root=args.root.resolve()
    try:
        if args.command=='upload':result=upload(args)
        else:
            state=read_state(args.state_dir)
            if state:
                marker=load(args.candidate_marker)
                require(state['source_sha']==marker.get('candidate_sha') and state['evidence_sha256']==consumer.sha(regular(evidence_path(args.root,args.evidence),consumer.MAX_FILE)),'ops evidence intent changed')
            result=report(state,args.root)
        print(json.dumps(result,sort_keys=True))
    except (ValueError,OSError,KeyError,TypeError,contract.NativeMTPEvidenceError,subprocess.SubprocessError,zipfile.BadZipFile) as exc:
        p.exit(1,'post-cut transport: '+str(exc)+'\n')

if __name__=='__main__':main()
