"""Closed composition boundaries; mocks never stand for real hardware proof."""
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch

HERE=Path(__file__).resolve().parents[1]
ROOT=next(p for p in HERE.parents if (p/'scripts/native_mtp_admission_sidecar.py').is_file())
spec=importlib.util.spec_from_file_location('representative_journey',HERE/'native_mtp_journey_evidence.py')
C=importlib.util.module_from_spec(spec);sys.modules[spec.name]=C;spec.loader.exec_module(C);C.ROOT=ROOT

def data(value):return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()

class RepresentativeCompositionTests(unittest.TestCase):
    def setUp(self):
        self.policy=data({'schema':'macprovider.native-mtp-post-gateway-replay-policy.v1'})
        self.entry=dict(model_key='model',ordinary_baseline={'artifact_hash':'a'*64},artifact_hash='b'*64,
            tokenizer_sha256='c'*64,max_native_active_rows=1,max_prompt_tokens=4096,qualified_slots=4,proposal_depth=1,
            request_feature_profile='native_mtp_sampled_text_v1',source_commit='d'*40,decode_path_digest='e'*64,runtime_revision='f'*40)
        for key in ('batch_evidence_sha256','performance_evidence_sha256','correctness_evidence_sha256','security_negative_evidence_sha256'):
            self.entry[key]='1'*64
        self.entry['benchmark_policy_sha256']=C.sha256(self.policy)
        self.w3=dict(schema=C.R015_POLICY_SCHEMA,model_id='model',target_sha256='a'*64,mtp_sha256='b'*64,tokenizer_sha256='c'*64,
            max_native_active_rows=1,maximum_prompt_tokens=4096,qualified_slots=4,proposal_depth=1,hw_model='studio',chip='M',ram_gb=256,
            provider_commit='2'*40,mlx_fork_revision='f'*40)
        self.files={'observations/representative/'+name:data({}) for name in ('capture.json','tuple-bounds.json','projection-plan.json',
            'privacy-review.json','preregistration.json','bench-policy.json','replay.json','replay-policy.json','analysis.json','source.json')}
        self.files['observations/representative/replay-policy.json']=self.policy
        self.files['observations/representative/bench-policy.json']=data({key:self.w3[key] for key in ('hw_model','chip','ram_gb')})
        self.files.update({'observations/w3-policy.json':data(self.w3),'observations/w3-runs.jsonl':b'actual paired records\n',
            'observations/w3-analysis.json':data({'overall_status':'PASS'}),'observations/r005-numeric-projection.json':data({'closed':'projection'})})
        self.details={'qualification_sha256':{key:self.entry[key] for key in self.entry if key.endswith('_evidence_sha256') or key=='benchmark_policy_sha256'},
            'w3_provider_commit':'2'*40,'w3_source_equivalence_contract_sha256':'3'*64}
        for kind in ('policy','runs','analysis'):self.details['w3_'+kind+'_sha256']=C.sha256(self.files['observations/w3-'+kind+('.jsonl' if kind=='runs' else '.json')])
        self.r005={'r005_result_sha256':'1'*64,'r005_policy_sha256':'4'*64,'r005_corpus_sha256':'5'*64,
            'r005_numeric_projection_sha256':C.sha256(self.files['observations/r005-numeric-projection.json'])}
        self.steps={'step-14-studio-and-tier-benchmark':{'details':self.details},'step-04-serial-token-oracle':{'details':self.r005}}
        self.analyzer=SimpleNamespace(analyze=Mock(return_value={'overall_status':'PASS'}))
        hashes={key:self.entry[key] for key in ('batch_evidence_sha256','performance_evidence_sha256','benchmark_policy_sha256')}
        self.core=SimpleNamespace(BindingBundleError=ValueError,validate_representative_replay=Mock(return_value=hashes),_module=Mock(return_value=self.analyzer))
        self.reuse=SimpleNamespace(SourceEquivalenceError=ValueError,source_decode_digest=Mock(return_value='6'*64),
            verify_source_equivalence=Mock(return_value='3'*64),W3_SOURCE='2'*40,OLD_FORK='7'*40,NEW_FORK='8'*40)
        self.numeric=SimpleNamespace(validate_projection=Mock(return_value={'raw_result_sha256':'1'*64,'policy_sha256':'4'*64,'corpus_sha256':'5'*64,
            'measured_source_commit':'9'*40,'projection_sha256':self.r005['r005_numeric_projection_sha256']}))

    def validate(self):
        def module(filename):
            return self.core if filename=='native_mtp_binding_bundle.py' else self.numeric
        with patch.object(C,'_serving_contract_module',side_effect=module),patch.object(C,'_source_equivalence_module',return_value=self.reuse):
            C.validate_representative_serving_policy(C.Bundle('bundle',self.files,b''),self.entry,self.policy,self.steps)

    def test_preserves_real_policy_schema_and_original_measurement_sources(self):
        self.validate()
        self.assertNotIn('provider_commit',json.loads(self.policy))
        self.assertEqual(self.w3['provider_commit'],'2'*40)
        self.assertEqual([call.args[1] for call in self.reuse.verify_source_equivalence.call_args_list],['2'*40,'9'*40])
        self.core.validate_representative_replay.assert_called_once()
        self.analyzer.analyze.assert_called_once()

    def test_wrong_representative_policy_bytes_refused(self):
        self.files['observations/representative/replay-policy.json']+=b' '
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'policy bytes differ'):self.validate()

    def test_failed_actual_w3_analysis_is_never_accepted(self):
        self.analyzer.analyze.return_value={'overall_status':'FAIL'}
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'analyzer result'):self.validate()

    def test_missing_raw_custody_match_or_projection_hash_refused(self):
        self.r005['r005_result_sha256']='0'*64
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'projected custody digest'):self.validate()
        self.r005['r005_result_sha256']='1'*64;self.r005['r005_numeric_projection_sha256']='0'*64
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'projection digest'):self.validate()

    def test_changed_qualification_map_or_unsupported_source_proof_refused(self):
        self.details['qualification_sha256']['performance_evidence_sha256']='0'*64
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'qualification digests'):self.validate()
        self.details['qualification_sha256']['performance_evidence_sha256']='1'*64
        self.reuse.verify_source_equivalence.side_effect=ValueError('unproven production change')
        with self.assertRaisesRegex(C.NativeMTPEvidenceError,'unproven production change'):self.validate()

if __name__=='__main__':unittest.main()
