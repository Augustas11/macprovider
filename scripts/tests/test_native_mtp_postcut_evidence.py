"""Small no-network checks of authenticated post-cut evidence boundaries."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[2]
REPO=next(p for p in [ROOT, *ROOT.parents] if (p/'scripts/native_mtp_journey_evidence.py').is_file())
sys.path.insert(0,str(REPO/'scripts'))
spec=importlib.util.spec_from_file_location('postcut',ROOT/'scripts/native_mtp_postcut_evidence.py')
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)


class PostCutTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.archive=Path(self.tmp.name)/'evidence.zip'
        self.redacted='journeys/evidence/native-mtp-serving-20261026T010000Z.redacted.json'
        self.provenance=self.redacted.removesuffix('.redacted.json')+'/postcut-provenance.json'
        self.m=dict(schema=M.SCHEMA,repository=M.REPOSITORY,source_sha='a'*40,
                    acceptance_run_id=10,acceptance_run_attempt=1,acceptance_tag='v1.8.274',acceptance_control_commit='a'*40,
                    checksums_sha256='b'*64,binary_sha256='c'*64,code_cdhash='d'*40,
                    decode_path_digest='e'*64,metallib_sha256='f'*64,ci_run_id=20,
                    redacted_evidence_path=self.redacted,files={})
        self.files={self.redacted:b'{}',self.provenance:json.dumps({k:v for k,v in self.m.items() if k!='files'}).encode()}
        self.m['files']={p:M.sha(b) for p,b in self.files.items()}

    def write(self,extra=None):
        with zipfile.ZipFile(self.archive,'w') as out:
            out.writestr('postcut-manifest.json',json.dumps(self.m))
            for p,b in self.files.items():out.writestr(p,b)
            if extra:out.writestr(*extra)
        return M.sha(self.archive.read_bytes())

    def read(self,expected=None):
        return M.archive_bytes(self.archive,expected or M.sha(self.archive.read_bytes()),'a'*40,self.redacted)

    def metadata(self):
        digest=self.write()
        asset={'id':30,'state':'uploaded','size':self.archive.stat().st_size,'digest':'sha256:'+digest}
        release={'id':40,'draft':True,'target_commitish':'a'*40,'assets':[asset.copy()]}
        candidate={'id':10,'run_attempt':1,'path':'.github/workflows/acceptance-candidate.yml','status':'completed','conclusion':'success','event':'workflow_dispatch','head_sha':'a'*40,'head_branch':'main','repository':{'full_name':M.REPOSITORY}}
        ci={**candidate,'id':20,'path':'.github/workflows/ci.yml','event':'push'}
        artifacts={'artifacts':[{'name':'acceptance-candidate-'+'a'*40,'expired':False,'workflow_run':{'id':10,'head_sha':'a'*40}}]}
        return [self.m,asset,release,30,40,self.archive.stat().st_size,digest,candidate,artifacts,ci]

    def test_exact_bounded_archive_is_accepted(self):
        self.write();m,files=self.read();self.assertEqual(m,self.m);self.assertEqual(files,self.files)

    def test_wrong_archive_digest_is_rejected(self):
        self.write()
        with self.assertRaisesRegex(ValueError,'archive digest'):self.read('0'*64)

    def test_unlisted_file_is_rejected(self):
        self.write(('unexpected.txt',b'bad'))
        with self.assertRaisesRegex(ValueError,'inventory differs'):self.read()

    def test_parent_traversal_is_rejected(self):
        self.write(('../scripts/signer.py',b'bad'))
        with self.assertRaisesRegex(ValueError,'unsafe ZIP path'):self.read()

    def test_symlink_member_is_rejected(self):
        self.write()
        info=zipfile.ZipInfo('link');info.external_attr=0o120777<<16
        with zipfile.ZipFile(self.archive,'a') as z:z.writestr(info,'target')
        with self.assertRaisesRegex(ValueError,'not regular'):self.read()

    def test_wrong_source_is_rejected(self):
        self.m['source_sha']='b'*40;self.write()
        with self.assertRaisesRegex(ValueError,'source differs'):self.read()

    def test_forged_bound_provenance_is_rejected(self):
        self.files[self.provenance]=b'{}';self.m['files'][self.provenance]=M.sha(b'{}');self.write()
        with self.assertRaisesRegex(ValueError,'exact post-cut provenance'):self.read()

    def test_secret_material_is_rejected_before_staging(self):
        # Assemble a synthetic PEM marker so repository secret scanners do not
        # mistake this rejection fixture for actual key material.
        marker=b'-----BEGIN '+b'PRIVATE KEY-----'
        self.files[self.redacted]=b'{"key":"'+marker+b'"}'
        self.m['files'][self.redacted]=M.sha(self.files[self.redacted]);self.write()
        with self.assertRaises(ValueError):self.read()


    def test_exact_authenticated_run_metadata_is_accepted(self):M.validate_metadata(*self.metadata())

    def test_published_staging_release_is_rejected(self):
        args=self.metadata();args[2]['draft']=False
        with self.assertRaisesRegex(ValueError,'staging release'):M.validate_metadata(*args)

    def test_changed_authenticated_asset_digest_is_rejected(self):
        args=self.metadata();args[1]['digest']='sha256:'+'0'*64
        with self.assertRaisesRegex(ValueError,'asset digest'):M.validate_metadata(*args)

    def test_wrong_source_ci_is_rejected(self):
        args=self.metadata();args[-1]['head_sha']='b'*40
        with self.assertRaisesRegex(ValueError,'workflow provenance'):M.validate_metadata(*args)

    def test_fork_candidate_is_rejected(self):
        args=self.metadata();args[-3]['repository']={'full_name':'attacker/fork'}
        with self.assertRaisesRegex(ValueError,'workflow provenance'):M.validate_metadata(*args)

    def test_wrong_acceptance_attempt_is_rejected(self):
        args=self.metadata();args[-3]['run_attempt']=2
        with self.assertRaisesRegex(ValueError,'acceptance run'):M.validate_metadata(*args)

    def test_ambiguous_acceptance_artifact_is_rejected(self):
        args=self.metadata();args[-2]['artifacts']*=2
        with self.assertRaisesRegex(ValueError,'artifact provenance'):M.validate_metadata(*args)

    def test_distinct_accepted_control_and_source_are_preserved(self):
        self.m['acceptance_control_commit']='b'*40
        args=self.metadata();args[-3]['head_sha']='b'*40
        args[-2]['artifacts'][0]['workflow_run']['head_sha']='b'*40
        M.validate_metadata(*args)


    def test_failed_ci_is_rejected(self):
        args=self.metadata();args[-1]['conclusion']='failure'
        with self.assertRaisesRegex(ValueError,'workflow provenance'):M.validate_metadata(*args)


if __name__=='__main__':unittest.main()
