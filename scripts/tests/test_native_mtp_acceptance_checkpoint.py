"""Model-free checkpoint tests; fixtures are never hardware evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest
# Load the sibling fixture module by file path: works with both package -m and
# unittest discover, without exporting its TestCase class into this module.
_fixture_spec = importlib.util.spec_from_file_location(
    "checkpoint_binding_fixtures", Path(__file__).with_name("test_native_mtp_binding_bundle.py"))
_fixture_module = importlib.util.module_from_spec(_fixture_spec)
sys.modules[_fixture_spec.name] = _fixture_module
_fixture_spec.loader.exec_module(_fixture_module)
m = _fixture_module.m

class CheckpointTests(unittest.TestCase):
    def fixture(self):
        result, policy, corpus, entry = _fixture_module.BindingCoreTests().fixture()
        rows = copy.deepcopy(result['cases'][:3])
        for row in rows:
            row['prompt_tokens']={'short':8,'1.5k':1536,'4k':4096,'8k':8192,'near_boundary':4096}[row['stratum']]
            row['checkpoint_observations'] = dict(accepted=20,rejected=1,proposed=21,decode_path='native_mtp',tool_call_count=0,reasoning_nonempty=False,content_nonempty=True,conversation_cache_key_absent=True)
        value = dict(schema='macprovider.native-mtp-acceptance-checkpoint.v1',provider_commit=policy['provider_commit'],policy_sha256='e'*64,corpus_sha256='d'*64,cases=rows)
        return value,policy,corpus,result,entry
    def validate(self, value, policy, corpus):
        return m.validate_acceptance_checkpoint(value,policy,corpus,policy_sha='e'*64,corpus_sha='d'*64)
    def test_actual_numeric_prefix_aggregates_without_final_pass(self):
        value,policy,corpus,_,_=self.fixture()
        totals=self.validate(value,policy,corpus)
        self.assertEqual(totals['native_positions'],120)
        self.assertEqual((totals['accepted'],totals['rejected']),(60,3))
        self.assertNotIn('status',totals)
    def test_empty_prefix_skips_nothing(self):
        value,policy,corpus,_,_=self.fixture();value['cases']=[]
        self.assertEqual(self.validate(value,policy,corpus)['native_positions'],0)
    def test_source_policy_corpus_and_duplicate_prefix_fail(self):
        for mutation in ('provider_commit','policy_sha256','corpus_sha256','duplicate','missing','reordered','failed'):
            with self.subTest(mutation=mutation):
                value,policy,corpus,_,_=self.fixture()
                if mutation in value:value[mutation]='0'*64
                elif mutation=='duplicate':value['cases'][1]=copy.deepcopy(value['cases'][0])
                elif mutation=='missing':value['cases'].pop(0)
                elif mutation=='reordered':value['cases'].reverse()
                else:value['cases'][1]['passed']=False
                with self.assertRaises(m.BindingBundleError):self.validate(value,policy,corpus)
    def test_full_numerical_records_required_before_counts(self):
        for mutation in ('token','top1','numeric','nan','visible','terminal','selected','observations','cache','counters','path'):
            with self.subTest(mutation=mutation):
                value,policy,corpus,_,_=self.fixture();row=value['cases'][0]
                if mutation=='token':row['selected_positions'][-1]['native_token']+=1
                elif mutation=='top1':row['positions'][0]['native_top1']+=1
                elif mutation=='numeric':row['positions'][0]['max_abs_difference']=.050001
                elif mutation=='nan':row['positions'][0]['ordinary_gap']=float('nan')
                elif mutation=='visible':row['completion_tokens']+=1
                elif mutation=='terminal':row['native_terminal']='stopSequence'
                elif mutation=='selected':row['selected_positions']=[]
                elif mutation=='observations':del row['checkpoint_observations']
                elif mutation=='cache':row['checkpoint_observations']['conversation_cache_key_absent']=False
                elif mutation=='counters':row['checkpoint_observations']['accepted']=999
                else:row['checkpoint_observations']['decode_path']='ordinary'
                with self.assertRaises(m.BindingBundleError):self.validate(value,policy,corpus)
    def test_final_all200_floor_gate_is_unchanged(self):
        value,policy,corpus,result,entry=self.fixture();result['cases']=value['cases']
        with self.assertRaisesRegex(m.BindingBundleError,'corpus incomplete'):
            m.validate_acceptance(result,policy,corpus,entry,policy_sha='e'*64,corpus_sha='d'*64)
    def test_swift_init_argument_plumbing_and_checked_accumulation(self):
        source=(Path(__file__).resolve().parents[2]/'phase3-binary/Sources/macprovider-cli/NativeMTPJourneyE2ECommand.swift').read_text()
        runner=source[source.index('final class NativeMTPJourneyRunner'):]
        initializer=runner[runner.index('    init('):runner.index('    ) {',runner.index('    init('))]
        self.assertIn('acceptanceCheckpointPath: String? = nil,',initializer)
        self.assertIn('private let acceptanceCheckpointPath: String?',runner)
        self.assertIn('self.acceptanceCheckpointPath = acceptanceCheckpointPath',runner)
        command=source[source.index('        let journey = NativeMTPJourneyRunner('):source.index('        let result = try await journey.run()')]
        self.assertIn('acceptanceCheckpointPath: acceptanceCheckpointPath,',command)
        self.assertIn('accepted.addingReportingOverflow(',runner)
        self.assertIn('rejected.addingReportingOverflow(',runner)
        self.assertIn('checkpoint aggregate counter overflow',runner)
    def test_aggregate_uint64_overflow_is_refused(self):
        maximum=2**63-1
        for mode in ('accepted','rejected','combined'):
            with self.subTest(mode=mode):
                value,policy,corpus,_,_=self.fixture()
                for index,row in enumerate(value['cases']):
                    accepted,rejected=(maximum,0) if mode=='accepted' else (0,maximum)
                    if mode=='combined':accepted,rejected=((maximum,0),(0,maximum),(2,0))[index]
                    row['checkpoint_observations'].update(accepted=accepted,rejected=rejected,proposed=accepted+rejected)
                with self.assertRaisesRegex(m.BindingBundleError,'aggregate counter overflow'):
                    self.validate(value,policy,corpus)
    def test_controller_revalidates_transport_bytes_and_fixed_command(self):
        value,policy,corpus,_,_=self.fixture()
        root=Path(__file__).resolve().parents[2]
        spec=importlib.util.spec_from_file_location('checkpoint_controller',root/'scripts/ops/studio-mtp-measurement.py')
        c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
        raw=json.dumps(value).encode();meta=dict(source=str(root),policy_sha256='e'*64,corpus_sha256='d'*64,resume_sha256=hashlib.sha256(raw).hexdigest(),commit=policy['provider_commit'],cell='acceptance')
        self.assertEqual(c.validate_checkpoint(meta,raw,json.dumps(policy).encode(),json.dumps(corpus).encode())['accepted'],60)
        with self.assertRaises(c.Refusal):c.validate_checkpoint(meta,raw+b' ',json.dumps(policy).encode(),json.dumps(corpus).encode())
        command=c.bench_command(meta,Path('/private-fixture'))
        self.assertIn('--acceptance-checkpoint',command)
        self.assertEqual(command[command.index('--acceptance-corpus')+1],'/private-fixture/acceptance-corpus.json')
        self.assertEqual(c.CELL,3000)
        self.assertIn("timeout=CELL - 10",(root/"scripts/ops/studio-mtp-measurement.py").read_text())

if __name__=='__main__':unittest.main()
