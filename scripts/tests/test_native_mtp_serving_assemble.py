import copy
from datetime import datetime,timedelta,timezone
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

REPO=Path(__file__).resolve().parents[5]
# Discover the actual checkout without relying on this ignored copy's depth.
REPO=next(p for p in Path(__file__).resolve().parents if (p/'AGENTS.md').is_file())
sys.path.insert(0,str(REPO/'scripts'));sys.path.insert(0,str(REPO))
spec=importlib.util.spec_from_file_location('assemble',Path(__file__).resolve().parents[1]/'native_mtp_serving_assemble.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
from scripts.tests import test_native_mtp_journey_evidence as fixtures
import native_mtp_journey_evidence as contract
privacy_spec=importlib.util.spec_from_file_location('assembly_privacy',Path(__file__).resolve().parents[1]/'privacy_class_beta_journey_evidence.py')
privacy=importlib.util.module_from_spec(privacy_spec);sys.modules[privacy_spec.name]=privacy;privacy_spec.loader.exec_module(privacy)


class AssemblyTests(unittest.TestCase):
    def environment(self):
        lab={'lab_binary_sha256':'a'*64,'lab_decode_path_digest':'b'*64,
             'machine':{'chip':'Apple M3 Ultra','ram_gb':256,'os_version':'15.1'}}
        env={'schema':'macprovider.native-mtp-lab-environment.v1','source_commit':'c'*40,
             'lab_binary_sha256':'a'*64,'decode_path_digest':'b'*64,
             'machine':dict(hardware_model='Mac16,9',chip='Apple M3 Ultra',ram_bytes=256*(1<<30),os_version='15.1',os_build='24B83'),
             'toolchain':dict(xcode_build_version='Xcode 16.1 Build version 16B40',swift_version='Apple Swift version 6.0')}
        return env,{'ram_bytes':256*(1<<30)},lab

    def test_environment_actual_machine(self):
        env,entry,lab=self.environment()
        self.assertEqual(a.validate_environment(env,entry,lab)['machine'],env['machine'])

    def test_foundation_os_string_matches_actual_product_and_build(self):
        env,entry,lab=self.environment();lab['machine']['os_version']='Version 15.1 (Build 24B83)'
        a.validate_environment(env,entry,lab)
        lab['machine']['os_version']='Version 15.1 (Build wrong)'
        with self.assertRaises(ValueError):a.validate_environment(env,entry,lab)

    def test_environment_wrong_tier_or_lab_hash_rejected(self):
        env,entry,lab=self.environment()
        for field,bad in [('ram_bytes',128*(1<<30)),('chip','Apple M4'),('hardware_model','private-host.local')]:
            changed=copy.deepcopy(env);changed['machine'][field]=bad
            with self.subTest(field=field),self.assertRaises(ValueError):a.validate_environment(changed,entry,lab)
        env['lab_binary_sha256']='d'*64
        with self.assertRaises(ValueError):a.validate_environment(env,entry,lab)

    def test_environment_private_path_rejected(self):
        env,entry,lab=self.environment();env['toolchain']['swift_version']='/Users/example/swift'
        with self.assertRaises(ValueError):a.validate_environment(env,entry,lab)

    def test_collector_refuses_operator_nonstudio(self):
        with mock.patch.object(a.sys,'platform','linux'),mock.patch.object(a.subprocess,'check_output') as run:
            with self.assertRaises(ValueError):a.collect_environment(REPO,Path('binary'))
            run.assert_not_called()

    def test_step_passflag_cannot_substitute_failed_check(self):
        with self.assertRaises(ValueError):a.step('02','capability-negatives',{'real':False},{'passed':True})

    def test_case_map_exists_in_actual_test_sources(self):
        for mapping in (a.CAPABILITY_CASES,a.SECURITY_CASES):
            for cls,names in mapping.items():
                path=REPO/'phase3-binary/Tests/macprovider-cliTests'/(cls+'.swift')
                if cls=='NativeMTPArtifactObservationTests':path=Path(__file__).resolve().parents[2]/'phase3-binary/Tests/macprovider-cliTests'/(cls+'.swift')
                text=path.read_text()
                for name in names:self.assertIn('func '+name+'(',text)

    def test_protocol_identity_must_match_actual_candidate(self):
        entry=dict(reproducible_build_sha256='a'*64,live_executable_cdhash='b'*40)
        a.assert_candidate({'candidate':{'binary_sha256':'a'*64,'cdhash':'b'*40}},entry)
        with self.assertRaises(ValueError):a.assert_candidate({'candidate':{'binary_sha256':'c'*64,'cdhash':'b'*40}},entry)

    def prepared(self,base):
        prepared=base/'prepared';prepared.mkdir()
        captured=(datetime.now(timezone.utc)-timedelta(minutes=2)).strftime('%Y-%m-%dT%H:%M:%SZ')
        sidecar,policy=fixtures.sidecar_and_policy()
        files={'native-mtp-admission.json':sidecar,'r015-policy.json':policy}
        for key,checks in fixtures.serving_checks().items():
            if key=='step-15-redaction-review':continue
            files['steps/'+key+'.json']=fixtures.step_bytes(key,checks,{'entry_index':0} if key=='step-01-bind-tuple' else {})
        for name,data in files.items():
            path=prepared/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        inventory={name:a.sha(data) for name,data in sorted(files.items())}
        record={'schema':'macprovider.native-mtp-serving-review-inventory.v1','files':inventory,'inventory_sha256':a.sha(a.canonical(inventory)),
                'captured_at':captured,'review_categories':a.CATEGORIES,'journey_complete':False}
        (prepared/'REVIEW-INVENTORY.json').write_bytes(a.canonical(record))
        narrative=base/'private-review.md';narrative.write_text('Actual test-only review fixture: every listed category was inspected against the exact inventory; no findings.\n')
        review={'schema':'macprovider.native-mtp-serving-privacy-review.v1','inventory_sha256':record['inventory_sha256'],
                'reviewed_at':datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),'reviewer_fingerprint':'e'*64,
                'review_record_sha256':a.sha(narrative.read_bytes()),'reviewed_categories':a.CATEGORIES,'findings':[]}
        reviewpath=base/'review.json';reviewpath.write_bytes(a.canonical(review))
        return prepared,reviewpath,narrative

    def modules(self,root,name):
        return {'native_mtp_journey_evidence':contract,'privacy_class_beta_journey_evidence':privacy}[name]

    def test_full_final_inventory_and_real_existing_contract(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d);prepared,review,narrative=self.prepared(base)
            with mock.patch.object(a,'module',side_effect=self.modules):result=a.finalize(REPO,prepared,review,narrative,base/'stage')
            self.assertTrue(result['journey_complete'])
            evidence=json.loads(Path(result['redacted_evidence_path']).read_text())
            self.assertEqual(len(evidence['steps']),14)
            finalbundle=Path(result['redacted_evidence_path'].removesuffix('.redacted.json'))
            self.assertTrue((finalbundle/'MANIFEST.sha256').is_file())

    def test_changed_reviewed_inventory_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d);prepared,review,narrative=self.prepared(base)
            (prepared/'r015-policy.json').write_bytes(b'changed')
            with mock.patch.object(a,'module',side_effect=self.modules),self.assertRaisesRegex(ValueError,'inventory changed'):
                a.finalize(REPO,prepared,review,narrative,base/'stage')

    def test_incomplete_review_and_findings_rejected(self):
        for change in ({'findings':['unresolved']},{'reviewed_categories':['credentials']},{'review_record_sha256':'0'*64}):
            with tempfile.TemporaryDirectory() as d:
                base=Path(d);prepared,review,narrative=self.prepared(base)
                value=a.load(review);value.update(change);review.write_bytes(a.canonical(value))
                with mock.patch.object(a,'module',side_effect=self.modules),self.assertRaises(ValueError):a.finalize(REPO,prepared,review,narrative,base/'stage')

    def test_public_scan_rejects_secret_in_final_inputs(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d);prepared,review,narrative=self.prepared(base)
            # Review cannot authorize secret publication; the scanner still runs.
            # Split the synthetic marker so the repository guard cannot mistake this fixture for a key.
            path=prepared/'leak.txt';path.write_text(('-----BEGIN ' + 'RSA PRIVATE KEY-----\n'))
            inventory=a.load(prepared/'REVIEW-INVENTORY.json');inventory['files']['leak.txt']=a.sha(path.read_bytes())
            inventory['inventory_sha256']=a.sha(a.canonical(inventory['files']))
            (prepared/'REVIEW-INVENTORY.json').write_bytes(a.canonical(inventory))
            record=a.load(review);record['inventory_sha256']=inventory['inventory_sha256'];review.write_bytes(a.canonical(record))
            with mock.patch.object(a,'module',side_effect=self.modules),self.assertRaises(privacy.PrivacyEvidenceError):a.finalize(REPO,prepared,review,narrative,base/'stage')

    def test_existing_public_admission_sidecars_pass_scanner(self):
        paths=list((REPO/'phase3-binary/catalog').rglob('native-mtp-admission.json'))
        self.assertTrue(paths)
        for path in paths:
            privacy.assert_bundle_redacted(privacy.Bundle('test',{'native-mtp-admission.json':path.read_bytes()},b''))

    def test_public_tensor_identifiers_only_exempt_dns_heuristic(self):
        for token in ('language_model.model.layers.0.mlp.gate','language_model.model.layers.17.self_attn.indexer.wk',
                      'language_model.mtp.1.block.self_attn.indexer.wk'):
            privacy.assert_bundle_redacted(privacy.Bundle('test',{'public.json':json.dumps({'module':token}).encode()},b''))
        for token in ('language_model.model.layers.0.mlp.gate.example.com','language_model.model.layers.0.mlp.evil',
                      'private-studio.local','https://private-studio.local/x','/Users/operator/private',
                      ('-----BEGIN ' + 'RSA PRIVATE KEY-----')):
            with self.subTest(token=token),self.assertRaises(privacy.PrivacyEvidenceError):
                privacy.assert_bundle_redacted(privacy.Bundle('test',{'public.json':json.dumps({'module':token}).encode()},b''))
        # An allowed public token on the same line never hides other host text.
        with self.assertRaises(privacy.PrivacyEvidenceError):
            privacy.assert_bundle_redacted(privacy.Bundle('test',{'public.json':b'language_model.model.layers.0.mlp.gate private-studio.local'},b''))

    def test_existing_analyzer_failure_cannot_be_overridden_by_saved_pass(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d);policy=base/'policy';policy.write_bytes(b'{}')
            saved=base/'analysis';saved.write_bytes(b'{"overall_status":"PASS"}')
            config={'qualification_bundle':str(base),'sidecar':str(base/'sidecar'),'entry_index':0,
                    'w3_policy':str(policy),'w3_runs':str(base/'runs'),'w3_analysis':str(saved)}
            core=mock.Mock();core.validate_serving_qualification.return_value={}
            analyzer=mock.Mock();analyzer.analyze.return_value={'overall_status':'FAIL'}
            with mock.patch.object(a,'module',return_value=analyzer),self.assertRaisesRegex(ValueError,'did not rederive PASS'):
                a.benchmark(REPO,config,{'source_commit':'a'*40},core)

    def test_historical_w3_fork_requires_exact_mechanical_source_bridge(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d);q=base/'qualification';q.mkdir();(q/'replay-policy.json').write_bytes(b'{}')
            entry=dict(model_key='zai-org/glm-5.3-flash',ram_bytes=256*(1<<30),qualified_slots=4,max_native_active_rows=1,
                proposal_depth=1,max_prompt_tokens=4096,ordinary_baseline={'artifact_hash':'a'*64},artifact_hash='b'*64,
                tokenizer_sha256='c'*64,runtime_revision='NEW',source_commit='e'*40,decode_path_digest='f'*64,
                request_feature_profile='native_mtp_sampled_text_v1',hardware_class='apple-m3-ultra')
            policy=dict(schema='macprovider.native-mtp-r015-policy.v1',ram_gb=256,qualified_slots=4,max_native_active_rows=1,
                proposal_depth=1,maximum_prompt_tokens=4096,model_id=entry['model_key'],target_sha256='a'*64,
                mtp_sha256='b'*64,tokenizer_sha256='c'*64,mlx_fork_revision='OLD',provider_commit='d'*40)
            for name,value in [('policy',policy),('analysis',{'overall_status':'PASS'})]:(base/name).write_bytes(a.canonical(value))
            (base/'runs').write_bytes(b'actual frozen metric rows')
            config=dict(qualification_bundle=str(base),sidecar=str(base/'sidecar'),entry_index=0,w3_policy=str(base/'policy'),
                        w3_runs=str(base/'runs'),w3_analysis=str(base/'analysis'))
            core=mock.Mock();core.validate_serving_qualification.return_value={'benchmark_policy_sha256':a.sha(b'{}')}
            analyzer=mock.Mock();analyzer.analyze.return_value={'overall_status':'PASS'}
            equiv=mock.Mock(W3_SOURCE='d'*40,OLD_FORK='OLD',NEW_FORK='NEW')
            equiv.source_decode_digest.return_value='1'*64;equiv.verify_source_equivalence.return_value='2'*64
            modules={'native_mtp_r015_analyze':analyzer,'native_mtp_journey_evidence':mock.Mock(),'native_mtp_source_equivalence':equiv}
            with mock.patch.object(a,'module',side_effect=lambda root,name:modules[name]):
                artifact,_=a.benchmark(REPO,config,entry,core)
                self.assertFalse(artifact['details']['lower_tier_qualification_claimed'])
                self.assertEqual(equiv.verify_source_equivalence.call_args.kwargs,{'request_feature_profile':'native_mtp_sampled_text_v1'})
                equiv.verify_source_equivalence.return_value=None
                with self.assertRaisesRegex(ValueError,'runtime fork differs'):a.benchmark(REPO,config,entry,core)

    def test_duplicate_json_and_nonfinite_rejected(self):
        for data in (b'{"x":1,"x":2}',b'{"x":NaN}'):
            with self.assertRaises(ValueError):a.strict(data)

    def test_prepare_caller_pass_flags_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError,'inputs fields'):a.prepare(REPO,{'schema':a.SCHEMA,'passed':True},Path(d)/'out')


if __name__=='__main__':unittest.main()
