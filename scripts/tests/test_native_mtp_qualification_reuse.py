"""No-hardware source reuse checks; never claim new-profile qualification."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

COPY=Path(__file__).resolve().parents[2]
ROOT=next(p for p in [COPY, *COPY.parents] if (p/'scripts/native_mtp_admission_sidecar.py').is_file())
sys.path.insert(0,str(ROOT/'scripts'));sys.path.insert(0,str(ROOT))
from scripts.tests.test_native_mtp_journey_evidence import sidecar_and_policy
spec=importlib.util.spec_from_file_location('reuse_contract',COPY/'scripts/native_mtp_journey_evidence.py')
C=importlib.util.module_from_spec(spec);sys.modules[spec.name]=C;spec.loader.exec_module(C);C.ROOT=ROOT


class ReuseTests(unittest.TestCase):
    def setUp(self):
        origin,self.policy=sidecar_and_policy('a'*40)
        body=json.loads(origin);entry=body['entries'][0]
        entry['decode_path_digest']='e'*64;entry['metallib_sha256']='f'*64
        self.origin=json.dumps(body).encode();self.current=copy.deepcopy(entry)
        self.current.update(source_commit='b'*40,provider_revision='b'*40,reproducible_build_sha256='c'*64,live_executable_cdhash='d'*40)
        self.current['ordinary_baseline']['provider_revision']='b'*40
        self.proof={'schema':'macprovider.native-mtp-qualification-source-reuse.v1',
                    'measured_source_commit':'a'*40,'current_source_commit':'b'*40,'measured_entry_index':0,
                    'measured_sidecar_sha256':C.sha256(self.origin),'benchmark_policy_sha256':C.sha256(self.policy),
                    'decode_path_digest':'e'*64,'metallib_sha256':'f'*64}

    def check(self,digests=None):
        files={'qualification-reuse.json':json.dumps(self.proof).encode(),'qualification-origin-native-mtp-admission.json':self.origin}
        bundle=C.Bundle('bundle',files,b'')
        with patch.object(C,'source_decode_digest',side_effect=digests or ['e'*64,'e'*64]) as compute:
            C.validate_qualification_source_reuse(bundle,self.current,self.policy,json.loads(self.policy))
        return compute

    def test_equal_source_digest_rebind_preserves_measurement_policy(self):
        original=self.policy;compute=self.check()
        self.assertEqual(self.policy,original)
        self.assertEqual([call.args[1] for call in compute.call_args_list],['a'*40,'b'*40])

    def test_compose_uses_verified_original_policy_without_relabelling(self):
        from scripts.tests.test_native_mtp_journey_evidence import serving_checks,step_bytes
        body=json.loads(self.origin);body['entries'][0]=self.current
        files={'native-mtp-admission.json':json.dumps(body).encode(),'r015-policy.json':self.policy,
               'qualification-reuse.json':json.dumps(self.proof).encode(),
               'qualification-origin-native-mtp-admission.json':self.origin}
        for step,checks in serving_checks().items():
            files['steps/'+step+'.json']=step_bytes(step,checks,{'entry_index':0} if step=='step-01-bind-tuple' else {})
        with patch.object(C,'source_decode_digest',return_value='e'*64):
            result=C.compose_serving(C.Bundle('bundle',files,b''),captured_at='2026-10-26T01:00:00Z')
        self.assertEqual(result['benchmark_policy_sha256'],C.sha256(self.policy))
        self.assertEqual(json.loads(files['r015-policy.json'])['provider_commit'],'a'*40)


    def changed_proof(self):
        self.current['decode_path_digest']='0'*64
        self.proof.update(schema='macprovider.native-mtp-qualification-source-reuse.v2',
            measured_decode_path_digest=self.proof.pop('decode_path_digest'),
            current_decode_path_digest='0'*64, source_equivalence_contract_sha256='9'*64)
        return C.Bundle('bundle',{'qualification-reuse.json':json.dumps(self.proof).encode(),
            'qualification-origin-native-mtp-admission.json':self.origin},b'')

    def test_reviewed_changed_digest_path_preserves_original_policy(self):
        # The shared validator is independently exercised against actual source
        # bytes in test_native_mtp_source_equivalence.py; spy on its boundary here.
        bundle=self.changed_proof()
        import importlib.util
        helper_path=C.Path(C.__file__).with_name('native_mtp_source_equivalence.py')
        helper_spec=importlib.util.spec_from_file_location('reuse_helper_test',helper_path)
        helper=importlib.util.module_from_spec(helper_spec);helper_spec.loader.exec_module(helper)
        with patch.object(helper,'verify_source_equivalence',return_value='9'*64) as verify, patch.object(C,'_source_equivalence_module',return_value=helper):
            C.validate_qualification_source_reuse(bundle,self.current,self.policy,json.loads(self.policy))
        self.assertEqual(json.loads(self.policy)['provider_commit'],'a'*40)
        self.assertEqual(verify.call_args.args[1:],('a'*40,'b'*40,'e'*64,'0'*64))

    def test_changed_digest_still_refuses_profile_or_metal_change(self):
        bundle=self.changed_proof()
        self.current['metallib_sha256']='1'*64
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'profile/runtime'):
            C.validate_qualification_source_reuse(bundle,self.current,self.policy,json.loads(self.policy))
        self.current['metallib_sha256']='f'*64
        self.current['max_native_active_rows']=2
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'profile/runtime'):
            C.validate_qualification_source_reuse(bundle,self.current,self.policy,json.loads(self.policy))

    def test_changed_source_decode_digest_is_rejected(self):
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'source decode identities'):self.check(['e'*64,'0'*64])

    def test_changed_profile_is_rejected(self):
        self.current['request_feature_profile']='native_mtp_greedy_text_v1'
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'profile/runtime'):self.check()

    def test_changed_rows_is_rejected(self):
        self.current['max_native_active_rows']=2
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'profile/runtime'):self.check()

    def test_changed_runtime_is_rejected(self):
        self.current['runtime_revision']='different'
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'profile/runtime'):self.check()

    def test_changed_evidence_digest_is_rejected(self):
        self.current['benchmark_policy_sha256']='0'*64
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'profile/runtime'):self.check()

    def test_relabelled_original_policy_is_rejected(self):
        self.proof['measured_source_commit']='c'*40
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'original/current'):self.check()

    def test_changed_origin_bytes_is_rejected(self):
        self.origin+=b' '
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'evidence bytes'):self.check()

    def test_boolean_equivalence_waiver_is_rejected(self):
        self.proof['unchanged']=True
        with self.assertRaises(C.NativeMTPEvidenceError):self.check()

    def test_metal_binding_is_required(self):
        self.proof['metallib_sha256']='0'*64
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'Metal identity'):self.check()


class SourceArchiveTests(unittest.TestCase):
    def test_git_blobs_recompute_unchanged_and_changed_paths(self):
        import subprocess,tempfile
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            def git(*args):return subprocess.check_output(['git',*args],cwd=root,text=True).strip()
            git('init','-q');git('config','user.name','test');git('config','user.email','test@example.invalid')
            package=root/'phase3-binary';(package/'Sources').mkdir(parents=True)
            (package/'decode-path-manifest.json').write_text(json.dumps({'schema_version':'macprovider.decode-path-manifest.v1','files':['Sources/test.swift'],'dependencies':['mlx-swift']}))
            (package/'Package.resolved').write_text(json.dumps({'pins':[{'identity':'mlx-swift','state':{'revision':'a'*40}}]}))
            code=package/'Sources/test.swift';code.write_text('let value=1')
            git('add','.');git('commit','-qm','measured');measured=git('rev-parse','HEAD')
            (root/'ops.txt').write_text('tooling only');git('add','.');git('commit','-qm','tooling');current=git('rev-parse','HEAD')
            self.assertEqual(C.source_decode_digest(root,measured),C.source_decode_digest(root,current))
            code.write_text('let value=2');git('add','.');git('commit','-qm','changed path');changed=git('rev-parse','HEAD')
            self.assertNotEqual(C.source_decode_digest(root,measured),C.source_decode_digest(root,changed))

    def test_missing_source_is_rejected(self):
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'source blob missing'):
            C.source_decode_digest(ROOT,'0'*40)


if __name__=='__main__':unittest.main()
