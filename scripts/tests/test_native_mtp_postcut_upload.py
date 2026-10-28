"""Model-free post-cut transport tests. All authenticated GH operations are mocks."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(Path.cwd()/'scripts'))
sys.path.insert(0,str(SCRIPTS))
import native_mtp_postcut_upload as tool


class PostcutTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve()
        self.source='a'*40;self.control='c'*40
        self.evidence='journeys/evidence/native-mtp-serving-20261026T120000Z.redacted.json'
        path=self.root/self.evidence;path.parent.mkdir(parents=True);path.write_text('{}')
        self.metadata=dict(schema=tool.consumer.SCHEMA,repository=tool.REPO,source_sha=self.source,
            acceptance_control_commit=self.control,acceptance_run_id=1,acceptance_run_attempt=1,
            acceptance_tag='v1.2.3',checksums_sha256='1'*64,binary_sha256='2'*64,
            code_cdhash='3'*40,decode_path_digest='4'*64,metallib_sha256='5'*64,
            ci_run_id=2,redacted_evidence_path=self.evidence)
        prefix=self.evidence.removesuffix('.redacted.json')
        self.bundle=tool.contract.Bundle(prefix,{'safe.json':b'{"safe":true}'},b'')
        (self.root/prefix).mkdir()
        (self.root/prefix/'safe.json').write_bytes(b'{"safe":true}')
        self.original=dict(captured_at='2026-10-26T12:00:00Z',expires_at='2026-10-27T12:00:00Z')
        self.args=SimpleNamespace(root=self.root,evidence=self.evidence,candidate_marker=self.root/'marker',state_dir=self.root/'state')

    def archive(self):
        with mock.patch.object(tool.contract,'compose_serving',return_value={'safe':True}):
            return tool.public_archive(self.root,self.evidence,self.metadata,self.bundle,self.original)

    def test_external_input_normalizes_without_public_private_paths(self):
        local=self.root/self.evidence
        with tool.input_tree(self.root,str(local)) as (root,relative,document):
            self.assertEqual(relative,self.evidence)
            self.assertEqual(document,b'{}')
            self.assertEqual((root/relative).read_bytes(),document)
            self.assertNotEqual(root,self.root)

    def test_archive_deterministic_closed_and_consumer_accepted(self):
        m,data=self.archive()
        self.assertEqual(self.archive(),(m,data))
        path=self.root/'safe.zip';path.write_bytes(data)
        actual,files=tool.consumer.archive_bytes(path,tool.consumer.sha(data),self.source,self.evidence)
        self.assertEqual(actual,m)
        self.assertNotIn('marker',files)
        self.assertIn(self.bundle.relative_dir+'/postcut-provenance.json',files)
        self.assertNotIn(str(self.root).encode(),data)

    def test_reject_private_content_before_archiving(self):
        for text in [b'{"path":"/Users/private/raw"}',b'{"secret":"ghp_abcdefghijklmnopqrstuvwxyz"}',b'{"host":"private.example.net"}',b'{"ip":"10.1.2.3"}']:
            with self.subTest(text=text):
                self.bundle.files={'safe.json':text}
                with self.assertRaises(ValueError):self.archive()

    def test_existing_provenance_cannot_be_replaced(self):
        self.bundle.files['postcut-provenance.json']=b'{}'
        with self.assertRaisesRegex(ValueError,'provenance differs'):self.archive()

    def test_unknown_manifest_field_rejected(self):
        self.metadata['extra']='unsafe'
        with self.assertRaisesRegex(ValueError,'manifest fields'):self.archive()

    def test_state_is_private_and_replaced_atomically(self):
        tool.atomic_state(self.args.state_dir,dict(schema=tool.STATE_SCHEMA,value=1))
        tool.atomic_state(self.args.state_dir,dict(schema=tool.STATE_SCHEMA,value=2))
        self.assertEqual(tool.read_state(self.args.state_dir)['value'],2)
        self.assertEqual((self.args.state_dir/'state.json').stat().st_mode&0o777,0o600)
        self.assertEqual(self.args.state_dir.stat().st_mode&0o777,0o700)

    def test_unsafe_state_symlink_rejected(self):
        self.args.state_dir.mkdir(mode=0o700)
        target=self.root/'other';target.write_text('{}')
        (self.args.state_dir/'state.json').symlink_to(target)
        with self.assertRaises(ValueError):tool.read_state(self.args.state_dir)

    def test_foreign_or_stale_live_lock_rejected(self):
        for status in [dict(held=False),dict(held=True,stale=True,lock={'owner':'test','purpose':'cli-release:native_mtp_postcut'}),dict(held=True,stale=False,lock={'owner':'foreign','purpose':'cli-release:native_mtp_postcut'})]:
            with self.subTest(status=status),mock.patch.dict(os.environ,MACPROVIDER_OPS_OWNER='test'),mock.patch.object(tool.subprocess,'check_output',return_value=json.dumps(status)):
                with self.assertRaisesRegex(ValueError,'live lock'):tool.require_ops_lock(self.root)

    def test_upload_guard_precedes_gh(self):
        with mock.patch.dict(os.environ,{},clear=True),mock.patch.object(tool,'gh') as gh:
            with self.assertRaisesRegex(ValueError,'next --run'):tool.upload(self.args)
        gh.assert_not_called()

    def upload_mock(self, *, prior=None, asset_digest=None, dispatch_error=False):
        m,data=self.archive();digest=tool.consumer.sha(data)
        release=dict(id=11,draft=True,target_commitish=self.source,tag_name='tag')
        asset=dict(id=12,name='native-mtp-postcut-'+digest+'.zip',digest='sha256:'+(asset_digest or digest),state='uploaded',size=len(data))
        if prior:
            tool.atomic_state(self.args.state_dir,dict(schema=tool.STATE_SCHEMA,source_sha=self.source,archive_sha256=digest,evidence_sha256=tool.consumer.sha((self.root/self.evidence).read_bytes()),**prior))
        calls=[]
        def gh(path,method='GET',payload=None):
            calls.append((path,method,payload))
            if method=='POST' and path.endswith('/releases'):return release
            if path.endswith('/assets'):return [asset]
            if path.endswith('/dispatches'):
                # The durable pending intent must exist BEFORE the network mutation.
                self.assertTrue(tool.read_state(self.args.state_dir)['dispatch_pending'])
                if dispatch_error:raise subprocess.CalledProcessError(1,['gh'])
                return None
            raise AssertionError(path)
        with mock.patch.dict(os.environ,MACPROVIDER_OPS_ENTRYPOINT='1',MACPROVIDER_OPS_OWNER='test'), \
             mock.patch.object(tool,'require_ops_lock',return_value=None), \
             mock.patch.object(tool,'binding',return_value=(self.metadata,self.bundle,self.original)), \
             mock.patch.object(tool,'public_archive',return_value=(m,data)), \
             mock.patch.object(tool,'pages',return_value=[]), \
             mock.patch.object(tool,'gh',side_effect=gh), \
             mock.patch.object(tool,'matching_runs',return_value=None):
            result=tool.upload(self.args)
        return result,calls

    def test_existing_digest_asset_reused_without_overwrite(self):
        result,calls=self.upload_mock()
        self.assertEqual(result['status'],'dispatch_pending')
        self.assertEqual(sum(p.endswith('/dispatches') for p,_,_ in calls),1)
        self.assertFalse(any('clobber' in str(c) for c in calls))

    def test_existing_asset_mismatch_rejected_no_dispatch(self):
        with self.assertRaisesRegex(ValueError,'never overwritten'):
            self.upload_mock(asset_digest='f'*64)

    def test_ambiguous_dispatch_never_retried(self):
        with self.assertRaises(subprocess.CalledProcessError):self.upload_mock(dispatch_error=True)
        result,calls=self.upload_mock(prior=None)
        self.assertEqual(result['status'],'dispatch_pending')
        self.assertEqual(calls,[])

    def test_run_matching_rejects_duplicate_or_foreign_authority(self):
        title=tool.title(self.source,'1'*64)
        rows=[dict(id=1,display_title=title),dict(id=2,display_title=title)]
        with mock.patch.object(tool,'pages',return_value=rows):
            with self.assertRaisesRegex(ValueError,'multiple dispatch'):tool.matching_runs(self.source,'1'*64,self.root)
        row=dict(id=1,display_title=title,path=tool.WORKFLOW_PATH,head_sha=self.control,head_branch='main',event='workflow_dispatch',repository={'full_name':'other/repo'})
        with mock.patch.object(tool,'pages',return_value=rows[:1]),mock.patch.object(tool,'gh',return_value=row),mock.patch.object(tool.subprocess,'run',return_value=SimpleNamespace(returncode=0)):
            with self.assertRaisesRegex(ValueError,'provenance'):tool.matching_runs(self.source,'1'*64,self.root)

    def test_run_discovery_uses_fingerprint_when_main_advances(self):
        fingerprint=tool.title(self.source,'1'*64)
        row=dict(id=9,display_title=fingerprint,path=tool.WORKFLOW_PATH,head_sha=self.control,
                 head_branch='main',event='workflow_dispatch',repository={'full_name':tool.REPO})
        def listing(path,key):
            self.assertEqual(key,'workflow_runs')
            self.assertNotIn('head_sha=',path)
            return [row]
        with mock.patch.object(tool,'pages',side_effect=listing),mock.patch.object(tool,'gh',return_value=row), \
             mock.patch.object(tool.subprocess,'run',return_value=SimpleNamespace(returncode=0)) as ancestry:
            self.assertEqual(tool.matching_runs(self.source,'1'*64,self.root),row)
        self.assertEqual(ancestry.call_args_list[1].args[0],['git','merge-base','--is-ancestor',self.source,self.control])

    def test_run_discovery_rejects_unrelated_candidate(self):
        row=dict(id=9,display_title=tool.title(self.source,'1'*64),head_sha=self.control)
        with mock.patch.object(tool,'pages',return_value=[row]),mock.patch.object(tool,'gh',return_value=row), \
             mock.patch.object(tool.subprocess,'run',side_effect=[SimpleNamespace(returncode=0),SimpleNamespace(returncode=1)]):
            with self.assertRaisesRegex(ValueError,'candidate source is not an ancestor'):
                tool.matching_runs(self.source,'1'*64,self.root)

    def test_cli_records_only_successful_authenticated_signed_run(self):
        text=(SCRIPTS/'ops/cli-release.sh').read_text()
        start=text.index('native_mtp_postcut() {');body=text[start:text.index('\n}',start)+2]
        scriptdir=self.root/'scripts';scriptdir.mkdir()
        (scriptdir/'native_mtp_postcut_upload.py').write_text('import os,json;print(json.dumps(dict(status=os.environ["RESULT"],run_id=99)))')
        code='''set -eu
REPO_ROOT="$TEST_ROOT"; OPS_STATE_DIR="$TEST_ROOT/state"; NATIVE_MTP_POSTCUT_EVIDENCE=private-input
MACPROVIDER_OPS_ENTRYPOINT=1; MACPROVIDER_OPS_OWNER=test
is_semver() { return 0; }
refuse() { echo "$*" >&2; exit 11; }
marker_field() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
marker_path() { echo marker; }
check_journey_run() { echo checked >> "$TEST_ROOT/trace"; echo '{"id":99}'; }
mark_done() { echo marked >> "$TEST_ROOT/trace"; }
log() { :; }
'''
        code+=body+'\nnative_mtp_postcut 1.2.3\n'
        for status in ['running','dispatch_pending','failure','success']:
            with self.subTest(status=status):
                trace=self.root/'trace'
                if trace.exists():trace.unlink()
                result=subprocess.run(['bash','-c',code],env=dict(os.environ,TEST_ROOT=str(self.root),RESULT=status),text=True,capture_output=True,timeout=5)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(trace.read_text().splitlines() if trace.exists() else [],['checked','marked'] if status=='success' else [])

    def test_cli_e2e_preserves_normal_manual_path_and_real_run_check(self):
        text=(SCRIPTS/'ops/cli-release.sh').read_text()
        self.assertIn('elif [ -n "${NATIVE_MTP_POSTCUT_EVIDENCE:-}" ]; then',text)
        self.assertIn('set_next e2e_gate manual',text)
        start=text.index('native_mtp_postcut() {');body=text[start:text.index('\n}',start)]
        self.assertLess(body.index('check_journey_run'),body.index('mark_done'))
        self.assertIn('if [ "$status" = success ]; then',body)
        self.assertIn('next --run',body)


if __name__=='__main__':unittest.main()
