"""Offline checks for the frozen DeepSeek CB/reference-DSpark window inputs."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / 'scripts/lab/dsv4'
POLICY = HARNESS / 'dsv4-cb-dspark-policy.json'


def module(name):
    spec = importlib.util.spec_from_file_location(name, HARNESS / f'{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class DeepseekCBDSparkHarnessTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads(POLICY.read_text())

    def test_frozen_requests_and_manifest_match(self):
        requests = HARNESS / 'dsv4-dspark-requests.json'
        self.assertEqual(hashlib.sha256(requests.read_bytes()).hexdigest(), self.policy['dspark']['requests_sha256'])
        rows = json.loads(requests.read_text())['requests']
        self.assertEqual(len(rows), 12)
        for row in rows:
            self.assertEqual(hashlib.sha256(json.dumps(row['ids']).encode()).hexdigest(), row['ids_sha256'])
        for line in (HARNESS / 'dsv4-cbds-manifest.sha256').read_text().splitlines():
            digest, name = line.split('  ', 1)
            self.assertEqual(hashlib.sha256((HARNESS / name).read_bytes()).hexdigest(), digest, name)

    def summary(self, directory):
        return json.loads(subprocess.check_output(
            [sys.executable, '-I', str(HARNESS / 'dsv4_cb_dspark_summary.py'), str(directory), str(POLICY)], text=True))

    def write_cb(self, directory):
        for n in (1, 2, 4, 8):
            t = dict(rows=n, runs=3, scenario='throughput', engine='scheduler', compiled=False,
                     promptTokensPerRow=1024, decodeTokensPerRow=256, aggregateTPSRuns=[70, 70, 70], aggregateTPSp50=70)
            p = dict(rows=n, runs=1, scenario='parity', engine='scheduler', compiled=False,
                     promptTokensPerRow=1024, decodeTokensPerRow=256,
                     leftovers={'parity': {'pass': True, 'comparedTokens': 256}})
            (directory / f'throughput-r{n}.json').write_text(json.dumps(t))
            (directory / f'parity-r{n}.json').write_text(json.dumps(p))

    def test_cb_missing_cells_never_pass_and_reference_is_not_native_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = self.summary(Path(tmp))
            self.assertEqual(s['cb_gate']['decision'], 'INCOMPLETE')
            self.assertFalse(s['dspark']['native_hardware_proof'])
            self.assertEqual(s['dspark']['proof_scope'], 'reference_only')
            self.assertEqual(s['native']['decision'], 'INCOMPLETE')
            self.assertFalse(s['native']['native_hardware_proof'])

    def test_cb_valid_cells_pass_but_wrong_rows_or_short_parity_do_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self.write_cb(directory)
            self.assertEqual(self.summary(directory)['cb_gate']['decision'], 'PASS')
            p = directory / 'parity-r8.json'
            value = json.loads(p.read_text())
            value['leftovers']['parity']['comparedTokens'] = 255
            p.write_text(json.dumps(value))
            self.assertEqual(self.summary(directory)['cb_gate']['decision'], 'FAIL')
            value['rows'] = 4
            p.write_text(json.dumps(value))
            self.assertEqual(self.summary(directory)['cb_gate']['decision'], 'INCOMPLETE')

    def test_cb_nonfinite_throughput_does_not_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self.write_cb(directory)
            p = directory / 'throughput-r4.json'
            value = json.loads(p.read_text())
            for invalid in (float('inf'), float('nan')):
                value['aggregateTPSp50'] = invalid
                p.write_text(json.dumps(value))
                self.assertEqual(self.summary(directory)['cb_gate']['decision'], 'INCOMPLETE')
            value['aggregateTPSp50'] = 70
            value['aggregateTPSRuns'][1] = float('nan')
            p.write_text(json.dumps(value))
            self.assertEqual(self.summary(directory)['cb_gate']['decision'], 'INCOMPLETE')

    @staticmethod
    def reference_runs():
        runs = []
        for s in ('prose', 'reasoning', 'code'):
            for i in range(4):
                runs.append(dict(phase='A', stratum=s, name=f'{s}-{i}', b=2, speedup=1.2, parity={'equal': True}))
            runs.append(dict(phase='B', stratum=s, b=2, parity={'equal': True}))
        runs.extend(dict(phase='C', ctx=ctx, b=2, parity={'equal': True}) for ctx in (8192, 32768))
        return runs

    def verdict(self, runs):
        return module('dsv4_dspark_bench').verdict(runs, [2], ['prose', 'reasoning', 'code'], 1.15)

    def test_dspark_requires_all_twelve_requests_and_long_cells(self):
        runs = self.reference_runs()
        self.assertEqual(self.verdict(runs)['decision'], 'GO')
        runs.pop()
        self.assertEqual(self.verdict(runs)['decision'], 'INCOMPLETE')
        subset = [r for r in self.reference_runs() if r.get('name') in ('prose-0', 'reasoning-0', 'code-0') or r['phase'] != 'A']
        self.assertEqual(self.verdict(subset)['decision'], 'INCOMPLETE')

    def test_dspark_nonfinite_speedup_is_incomplete(self):
        runs = self.reference_runs()
        runs[0]["speedup"] = float("nan")
        self.assertEqual(self.verdict(runs)["decision"], "INCOMPLETE")

    def test_dspark_batch_divergence_blocks_go(self):
        runs = copy.deepcopy(self.reference_runs())
        next(r for r in runs if r['phase'] == 'B')['parity']['equal'] = False
        self.assertEqual(self.verdict(runs)['decision'], 'NO_GO')

    def test_reference_go_cannot_supply_missing_native_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'dspark').mkdir()
            (directory / 'dspark/dspark.json').write_text(json.dumps({'verdict': {'decision': 'GO'}}))
            result = self.summary(directory)
            self.assertEqual(result['dspark']['decision'], 'GO')
            self.assertEqual(result['native']['decision'], 'INCOMPLETE')
            self.assertFalse(result['native']['native_hardware_proof'])

    def test_integrity_records_cannot_qualify_as_r015(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            policy = directory / 'depth-1.json'
            policy.write_text(json.dumps({'schema': 'macprovider.native-mtp-r015-policy.v1',
                                         'proposal_depth': 1, 'quantization': 'mlx_mxfp4_mxfp8'}))
            (directory / 'r015-d1.jsonl').write_text(json.dumps({
                'schema': 'macprovider.native-dsv4-dspark-run.v1', 'record_type': 'header', 'qualifies_r015': False}) + '\n')
            result = module('dsv4_cb_dspark_summary').native_r015(directory, 1, policy)
            self.assertEqual(result['decision'], 'INCOMPLETE')
            self.assertFalse(result['qualifies_r015'])

    def test_complete_native_integrity_is_distinct_from_qualification(self):
        helper = module('dsv4_cb_dspark_summary')
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            frozen = directory / 'depth-1.json'
            frozen.write_text(json.dumps({'proposal_depth': 1, 'quantization': 'mlx_mxfp4_mxfp8',
                                         'provider_commit': 'a' * 40, 'mlx_fork_revision': 'b' * 40}))
            header = dict(schema='macprovider.native-dsv4-dspark-run.v1', record_type='header',
                          runtime='native_swift_mlx', qualifies_r015=False,
                          policy_sha256=hashlib.sha256(frozen.read_bytes()).hexdigest(),
                          provider_commit='a' * 40, mlx_fork_revision='b' * 40,
                          target_sha256=self.policy['artifact']['target_sha256'],
                          tokenizer_sha256=self.policy['artifact']['tokenizer_sha256'],
                          requests_sha256=self.policy['dspark']['requests_sha256'],
                          requested_maximum_proposal_depth=1, long_prompt_token_counts=[8192, 32768])
            requests = json.loads((HARNESS / 'dsv4-dspark-requests.json').read_text())['requests']
            groups = [[r['name']] for r in requests]
            groups += [[r['name'] for r in requests if r['stratum'] == s] for s in ('prose', 'reasoning', 'code')]
            for count in (8192, 32768):
                groups += [[f'long-{count}'], [f'long-{count}-r{r}' for r in range(4)]]
            records = [header]
            for index, group in enumerate(groups):
                for path in ('ordinary', 'native_mtp'):
                    record = dict(header, record_type='run', path=path, group_index=index, rows=len(group),
                                  aggregate_decode_tps=45, peak_phys_footprint_bytes=200000000000,
                                  parity_pass=True, mtp_drafted_by_position=[8], mtp_accepted_by_position=[5],
                                  mtp_proposed_tokens=8, mtp_resolved_rounds=8)
                    record['request_metrics'] = [dict(name=name, token_sha256='c' * 64, completion_tokens=256,
                        ttft_seconds=1, decode_tps=40, prompt_tokens=8192 if index in (15, 16) else 32768 if index in (17, 18) else 100)
                        for name in group]
                    records.append(record)
            output = directory / 'd1.jsonl'
            output.write_text(''.join(json.dumps(r) + '\n' for r in records))
            result = helper.native_integrity(directory, 1, frozen, self.policy)
            self.assertEqual(result['decision'], 'PASS')
            self.assertFalse(result['qualifies_r015'])
            self.assertEqual(len(result['groups']), 19)
            output.write_text(''.join(json.dumps(r) + '\n' for r in records[:-1]))
            self.assertEqual(helper.native_integrity(directory, 1, frozen, self.policy)['decision'], 'INCOMPLETE')

    def test_plan_quotes_paths_and_has_no_side_effects(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'window output'
            env = dict(os.environ, LAB='/prepared workspace', NEWBIN='/candidate dir/macprovider-cli',
                       DSV4_MODEL_DIR='/verified model', PY=sys.executable, ORACLES='/oracle dir',
                       LIVE_URL='status-endpoint-supplied-by-controller',
                       DSV4_NATIVE_BENCH_ROOT='/native fixture', DSV4_NATIVE_POLICY_DIR='/depth policies',
                       DSV4_NATIVE_LONG_TOKEN_IDS='/oracle token ids.json', DSV4_PROVIDER_COMMIT='a' * 40)
            result = subprocess.run(['bash', str(HARNESS / 'dsv4_cb_dspark_addon.sh'), '--plan', str(output)],
                                    env=env, text=True, capture_output=True, check=True)
            self.assertFalse(output.exists())
            self.assertIn('/verified\\ model', result.stdout)
            self.assertIn('--rows 8', result.stdout)
            self.assertEqual(result.stderr, '')
            native = [line for line in result.stdout.splitlines() if ' native-mtp-bench ' in line]
            self.assertEqual(len(native), 8)
            integrity = [line for line in native if ' --requests ' in line]
            qualification = [line for line in native if ' --requests ' not in line]
            self.assertEqual(len(integrity), 4)
            self.assertEqual(len(qualification), 4)
            for depth in (1, 2, 3, 5):
                self.assertTrue(any(f'depth-{depth}.json' in line and '--long-token-ids' in line for line in integrity))
                self.assertTrue(any(f'r015-d{depth}.jsonl' in line and '--long-token-ids' not in line for line in qualification))
            self.assertIn('(6000 s)', result.stdout)


if __name__ == '__main__':
    unittest.main()
