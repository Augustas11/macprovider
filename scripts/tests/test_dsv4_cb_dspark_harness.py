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

    def test_plan_quotes_paths_and_has_no_side_effects(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'window output'
            env = dict(os.environ, LAB='/prepared workspace', NEWBIN='/candidate dir/macprovider-cli',
                       DSV4_MODEL_DIR='/verified model', PY=sys.executable, ORACLES='/oracle dir',
                       LIVE_URL='status-endpoint-supplied-by-controller')
            result = subprocess.run(['bash', str(HARNESS / 'dsv4_cb_dspark_addon.sh'), '--plan', str(output)],
                                    env=env, text=True, capture_output=True, check=True)
            self.assertFalse(output.exists())
            self.assertIn('/verified\\ model', result.stdout)
            self.assertIn('--rows 8', result.stdout)
            self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
