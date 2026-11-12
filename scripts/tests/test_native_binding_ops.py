"""Model-free wiring checks; fake verifier tests custody, never signature validity."""
import json
import importlib.util
import sys
import dataclasses
import os
import subprocess
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
CONTENT = SCRIPTS / 'catalog-content-release.sh'
OPS = SCRIPTS / 'ops/catalog-activate.sh'
RECIPE = 'ops/recipes/native-mtp-glm53-binding.v1.json'


def function(path, name):
    text = path.read_text()
    start = text.index(name + '() {')
    return text[start:text.index('\n}', start) + 2]


class NativeBindingOpsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        static = self.repo / 'phase3-binary/dist/static'
        catalog = self.repo / 'phase3-binary/catalog/autotune'
        static.mkdir(parents=True)
        catalog.mkdir(parents=True)
        self.files = ['autotune-candidates.json', 'autotune-candidates.json.sig',
                      'demand-rank.json', 'demand-rank.json.sig', 'rate-card.json',
                      'rate-card.json.sig', 'continuous-batching-policy.json',
                      'continuous-batching-policy.json.sig']
        for name in self.files:
            (static / name).write_text('committed-' + name)
        for name in ['release.json', 'trusted-keys.json', 'tier2-catalog.json',
                     'release-ledger.json', 'not-buyer-serving.json']:
            (catalog / name).write_text('{"feeds":{}}' if name == 'release.json' else 'committed-' + name)
        config = self.repo / 'phase4-coordinator/dist/coordinator.yaml'
        config.parent.mkdir(parents=True)
        config.write_text('trusted: committed')
        for args in [('init', '-q'), ('add', '.'), ('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture')]:
            subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True)
        self.commit = subprocess.check_output(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        (self.tools / 'catalog-release.py').write_text('''import json,os,sys
if os.environ.get('ARG_LOG'):
 open(os.environ['ARG_LOG'],'w').write(json.dumps(sys.argv[1:]))
print(json.dumps(dict(lane='catalog-content',ok=True,commit_block_sha256='block',pricing_diff_sha256='diff')))
''')
        (self.tools / 'native_mtp_binding_bundle.py').write_text('''import json,os,pathlib,sys
args=sys.argv; b=pathlib.Path(args[args.index('--bundle')+1]);
if os.environ.get('REJECT_PROOF'):raise SystemExit(1)
if os.environ.get('VERIFY_ARGS'):open(os.environ['VERIFY_ARGS'],'w').write(json.dumps(args[1:]))
if os.environ.get('MUTATE_ORIGINAL'):pathlib.Path(os.environ['MUTATE_ORIGINAL']).write_text('changed-after-freeze')
print(json.dumps(dict(release_dir=str(b/'release'),ledger_path=str(b/'derived/release-ledger.json'),phase='identity_only_greedy',receipt_sha256='a'*64,release_input_path=str(b/'derived/native-mtp-admission-release.json'),serving_journey=os.environ.get('SERVING_JOURNEY','signed export required'))))
''')
        self.bundle = self.root / 'caller-bundle'
        (self.bundle / 'release').mkdir(parents=True)
        (self.bundle / 'derived').mkdir()
        (self.bundle / 'release/release.json').write_text('{"feeds":{}}')
        (self.bundle / 'release/demand-rank.json').write_text('derived-demand')
        (self.bundle / 'derived/release-ledger.json').write_text('derived-ledger')
        (self.bundle / 'derived/native-mtp-admission-release.json').write_text('{}')

    def shell(self, code, env=None):
        return subprocess.run(['bash', '-c', code], env=dict(os.environ, **(env or {})),
                              text=True, capture_output=True, timeout=8)

    def assemble(self, env=None):
        work = self.root / 'work'
        code = '''set -eu
WORK="$TEST_ROOT/work"; REL="$WORK/release"; COMMIT="$TEST_COMMIT"
REPO_ROOT="$TEST_REPO"; SCRIPT_DIR="$TEST_TOOLS"
record() { printf '%s %s\\n' "$1" "$2"; }
release_identity() { REL_ID=test; REL_BOUND=unbound; }
release_dirname() { echo test-release; }
'''
        code += function(CONTENT, 'pf_assemble')
        code += '\npf_assemble\nprintf "REL=%s\\n" "$REL"\n'
        values = dict(TEST_ROOT=str(self.root), TEST_REPO=str(self.repo), TEST_COMMIT=self.commit,
                      TEST_TOOLS=str(self.tools))
        values.update(env or {})
        return self.shell(code, values), work

    def test_core_helper_api_matches_ops_and_catalog_contract(self):
        spec = importlib.util.spec_from_file_location('native_binding_ops_api', SCRIPTS / 'native_mtp_binding_bundle.py')
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        try:
            spec.loader.exec_module(module)
            self.assertTrue(issubclass(module.BindingBundleError, ValueError))
            self.assertEqual(module.RECIPE_PATH, RECIPE)
            self.assertEqual({field.name for field in dataclasses.fields(module.VerifiedBundle)},
                             {'release_dir', 'ledger_path', 'release_input_path', 'source_commit',
                              'phase', 'recipe_sha256', 'receipt_sha256'})
            self.assertTrue(module.VerifiedBundle.__dataclass_params__.frozen)
        finally:
            sys.modules.pop(spec.name, None)

    def test_assembly_uses_committed_git_bytes_and_ledger(self):
        result, work = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((work / 'release/demand-rank.json').read_text(), 'committed-demand-rank.json')
        self.assertEqual((work / 'gate/release-ledger.json').read_text(), 'committed-release-ledger.json')
        self.assertFalse((work / 'binding').exists())
        # A release cut before SPEC-023 §3.8 carries no manifest signature.
        self.assertFalse((work / 'release/release.json.sig').exists())

    def test_assembly_carries_the_committed_release_manifest_signature(self):
        sig = self.repo / 'phase3-binary/catalog/autotune/release.json.sig'
        sig.write_text('committed-release.json.sig')
        for args in [('add', '.'), ('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'manifest sig')]:
            subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True)
        self.commit = subprocess.check_output(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        result, work = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((work / 'release/release.json.sig').read_text(), 'committed-release.json.sig')

    def test_legacy_gates_run_under_macos_bash_nounset_with_zero_optional_args(self):
        work = self.root / 'gate-work'
        work.mkdir()
        (work / 'stage-summary.json').write_text('{}')
        (work / 'pinned-names.json').write_text('[]')
        for name in ['pf_content_gate', 'pf_pricing_gate']:
            with self.subTest(name=name):
                log = work / (name + '.json')
                code = 'set -eu\nWORK="$TEST_WORK"; SCRIPT_DIR="$TEST_TOOLS"; REL=release; LIVE=live; COMMIT=abc; LIVE_ID=old; PRICING_DIR="$TEST_WORK"; PRICING_DIFF_SHA=diff; COMMIT_BLOCK_SHA=block; PRIOR_RATE_SHA=x; PRIOR_SIGNED_SHA=x; PRIOR_SNAPSHOT_ID=1; CONFIG_DISK_SHA=x; OVERLAY_DISK_SHA=x; ACK_MOVES_SHA=x\n'
                code += 'record() { :; }; pf_pricing_detect() { :; }\n'
                code += function(CONTENT, name) + '\n' + name + '\n'
                result = self.shell(code, dict(TEST_WORK=str(work), TEST_TOOLS=str(self.tools), ARG_LOG=str(log)))
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(log.read_text())
                self.assertNotIn('', args)
                self.assertNotIn('--native-binding-bundle', args)
                self.assertEqual(args[:7], ['content-gate', '--release', 'release', '--live', 'live', '--commit', 'abc'])

    def test_catalog_revalidates_waiver_after_full_bundle_verification(self):
        from scripts.tests.test_catalog_compare_live import cr
        (self.bundle / 'proof').mkdir()
        (self.bundle / 'proof/journey-waiver.json').write_text('{}')
        inputs = {'phase': 'expanded_glm_sampled'}
        proof = object()
        module = SimpleNamespace(
            read_json=mock.Mock(return_value=inputs),
            verify_bundle=mock.Mock(return_value=proof),
            validate_journey_waiver=mock.Mock(return_value='waived (operator, 2026-10-29)'),
            require=lambda condition, reason: None if condition else (_ for _ in ()).throw(ValueError(reason)),
        )
        with mock.patch.object(cr, '_native_mtp_binding_module', return_value=module):
            self.assertIs(cr._verify_native_binding_bundle(
                self.bundle, repo=self.repo, commit=self.commit, recipe_path=RECIPE), proof)
        module.verify_bundle.assert_called_once_with(
            self.bundle, repo=self.repo, commit=self.commit, recipe_path=RECIPE)
        module.validate_journey_waiver.assert_called_once_with(
            self.bundle, inputs, self.bundle / 'release/native-mtp-admission.json')
        module.validate_journey_waiver.return_value = 'signed export required'
        with mock.patch.object(cr, '_native_mtp_binding_module', return_value=module), \
             self.assertRaisesRegex(ValueError, 'exact operator journey waiver'):
            cr._verify_native_binding_bundle(
                self.bundle, repo=self.repo, commit=self.commit, recipe_path=RECIPE)
        module.validate_journey_waiver.reset_mock()
        module.verify_bundle.side_effect = ValueError('signature mismatch')
        with mock.patch.object(cr, '_native_mtp_binding_module', return_value=module), \
             self.assertRaisesRegex(ValueError, 'signature mismatch'):
            cr._verify_native_binding_bundle(
                self.bundle, repo=self.repo, commit=self.commit, recipe_path=RECIPE)
        module.validate_journey_waiver.assert_not_called()

    def release_match_preflight(self, bound='true', verdict='ok', exit_code=0, run=False):
        tools = self.root / 'matcher-repo/scripts'
        tools.mkdir(parents=True)
        (tools / 'native_mtp_release_match.py').write_text(
            'import json, os, sys\n'
            "open(os.environ['MATCH_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n"
            "print(os.environ['MATCH_VERDICT'])\n"
            "raise SystemExit(int(os.environ['MATCH_EXIT']))\n")
        code = '''set -eu
REPO_ROOT="$TEST_MATCH_REPO"; OPS_STATE_DIR="$TEST_ROOT/state"
CATALOG_TARGET_INPUT="$TEST_ROOT/input.json"; CATALOG_TARGET_DIR="$TEST_ROOT/release"
NEXT_ID=""; NEXT_KIND=""; NEXT_REASON=""; NEXT_CMD=""; NEXT_TITLE=""
fact() { printf 'FACT %s=%s\\n' "$1" "$2"; }
step() { printf 'STEP %s %s %s\\n' "$1" "$2" "$3"; }
'''
        common = SCRIPTS / 'ops/lib/common.sh'
        code += function(common, 'set_next') + '\n'
        code += function(OPS, 'native_mtp_release_preflight') + '\n'
        code += 'native_mtp_release_preflight "$TEST_BOUND" || true\n'
        code += 'printf "NEXT %s %s %s\\n" "$NEXT_ID" "$NEXT_KIND" "$NEXT_REASON"\n'
        if run:
            # Exercise only the shared blocked-step dispatcher with fake
            # effects. Never source or invoke an ops entry point or lock.
            code += '''
print_next() { :; }
refuse() { echo "REFUSED: $*" >&2; exit 3; }
acquire_live_lock_for_step() { echo LOCK_REACHED >&2; exit 90; }
'''
            code += function(common, 'run_next') + '\nrun_next\n'
        env = dict(TEST_ROOT=str(self.root), TEST_MATCH_REPO=str(tools.parent),
                   TEST_BOUND=bound, MATCH_ARGS=str(self.root / 'matcher-args.json'),
                   MATCH_VERDICT=verdict, MATCH_EXIT=str(exit_code))
        return self.shell(code, env)

    def test_native_release_match_preflight_reports_success_and_verified_input_paths(self):
        result = self.release_match_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('FACT native_mtp_release_match_gate=ok', result.stdout)
        self.assertIn('STEP native_mtp_release_match done', result.stdout)
        self.assertNotIn('NEXT native_mtp_release_match blocked', result.stdout)
        self.assertEqual(json.loads((self.root / 'matcher-args.json').read_text()),
                         ['--release-input', str(self.root / 'input.json'), '--admission',
                          str(self.root / 'release/native-mtp-admission.json'), '--repo',
                          str(self.root / 'matcher-repo'), '--state-dir', str(self.root / 'state')])

    def test_native_release_match_preflight_blocks_next_run_without_reaching_lock(self):
        result = self.release_match_preflight(
            verdict='blocked: runtime_revision differs from signed release', exit_code=1, run=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('STEP native_mtp_release_match blocked', result.stdout)
        self.assertIn('runtime_revision', result.stderr)
        self.assertNotIn('LOCK_REACHED', result.stderr)

    def test_native_release_match_preflight_fails_closed_on_unexpected_output(self):
        result = self.release_match_preflight(verdict='unknown', exit_code=0)
        self.assertIn('NEXT native_mtp_release_match blocked', result.stdout)

    def test_native_release_match_preflight_fails_closed_on_nonzero_even_if_output_is_ok(self):
        result = self.release_match_preflight(verdict='ok', exit_code=1)
        self.assertIn('NEXT native_mtp_release_match blocked', result.stdout)

    def test_non_native_release_skips_matcher(self):
        result = self.release_match_preflight(bound='false', exit_code=99)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('release is not native-bound', result.stdout)
        self.assertFalse((self.root / 'matcher-args.json').exists())

    def test_native_release_match_is_before_fresh_steps(self):
        gather = function(OPS, 'gather')
        gate = gather.index('native_mtp_release_preflight "$native_bound" || return 0')
        self.assertLess(gate, gather.index('set_next revocation_slots mutate'))
        self.assertLess(gate, gather.index('if [ "$live_rid" = "$R" ]; then'))


if __name__ == '__main__':
    unittest.main()
