"""Model-free wiring checks; fake verifier tests custody, never signature validity."""
import json
import importlib.util
import sys
import dataclasses
import os
import shutil
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

    def assemble(self, bundle=True, env=None):
        work = self.root / 'work'
        code = '''set -eu
WORK="$TEST_ROOT/work"; REL="$WORK/release"; COMMIT="$TEST_COMMIT"
REPO_ROOT="$TEST_REPO"; SCRIPT_DIR="$TEST_TOOLS"
NATIVE_BINDING_BUNDLE="$TEST_BUNDLE"; NATIVE_BINDING_RECIPE="$TEST_RECIPE"
NATIVE_BINDING_PROOF=""; NATIVE_BINDING_GATE_ARGS=()
record() { printf '%s %s\\n' "$1" "$2"; }
release_identity() { REL_ID=test; REL_BOUND=unbound; }
release_dirname() { echo test-release; }
'''
        code += function(CONTENT, 'pf_assemble')
        code += '\npf_assemble\nprintf "REL=%s\\n" "$REL"\nprintf "ARG=%s\\n" ${NATIVE_BINDING_GATE_ARGS[@]+"${NATIVE_BINDING_GATE_ARGS[@]}"}\n'
        values = dict(TEST_ROOT=str(self.root), TEST_REPO=str(self.repo), TEST_COMMIT=self.commit,
                      TEST_TOOLS=str(self.tools), TEST_BUNDLE=str(self.bundle) if bundle else '', TEST_RECIPE=RECIPE)
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

    def test_bundle_is_frozen_before_verification_and_derived_ledger_is_used(self):
        original = self.bundle / 'release/demand-rank.json'
        result, work = self.assemble(env={'MUTATE_ORIGINAL': str(original)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(original.read_text(), 'changed-after-freeze')
        frozen = work / 'binding/caller-bundle'
        self.assertEqual((frozen / 'release/demand-rank.json').read_text(), 'derived-demand')
        self.assertEqual((work / 'gate/release-ledger.json').read_text(), 'derived-ledger')
        self.assertEqual((work / 'gate/not-buyer-serving.json').read_text(), 'committed-not-buyer-serving.json')
        self.assertIn('ARG=' + str(frozen), result.stdout)
        self.assertIn('REL=' + str(frozen / 'release'), result.stdout)

    def test_legacy_path_assembles_git_bytes_and_ledger(self):
        result, work = self.assemble(bundle=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((work / 'release/demand-rank.json').read_text(), 'committed-demand-rank.json')
        self.assertEqual((work / 'gate/release-ledger.json').read_text(), 'committed-release-ledger.json')
        self.assertFalse((work / 'binding').exists())
        self.assertNotIn('ARG=--native-binding', result.stdout)

    def test_bundle_proof_failure_stops_assembly(self):
        result, _ = self.assemble(env={'REJECT_PROOF': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('release_assembled 0', result.stdout)

    def test_symlink_member_is_rejected_before_verification(self):
        (self.bundle / 'escape').symlink_to(self.repo)
        result, _ = self.assemble()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nonregular bundle member', result.stderr)

    def test_unknown_recipe_is_rejected(self):
        result, _ = self.assemble(env={'TEST_RECIPE': 'arbitrary.json'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('release_assembled 0', result.stdout)

    def test_both_content_gates_receive_frozen_bundle_arguments(self):
        for name in ['pf_content_gate', 'pf_pricing_gate']:
            text = function(CONTENT, name)
            self.assertIn('"${NATIVE_BINDING_GATE_ARGS[@]}"', text)
            self.assertIn('--commit "$COMMIT"', text)
            self.assertIn('--tier2-coordinator-config', text)

    def test_legacy_gates_run_under_macos_bash_nounset_with_zero_optional_args(self):
        work = self.root / 'gate-work'
        work.mkdir()
        (work / 'stage-summary.json').write_text('{}')
        (work / 'pinned-names.json').write_text('[]')
        for name in ['pf_content_gate', 'pf_pricing_gate']:
            with self.subTest(name=name):
                log = work / (name + '.json')
                code = 'set -eu\nWORK="$TEST_WORK"; SCRIPT_DIR="$TEST_TOOLS"; REL=release; LIVE=live; COMMIT=abc; LIVE_ID=old; NATIVE_BINDING_GATE_ARGS=(); PRICING_DIR="$TEST_WORK"; PRICING_DIFF_SHA=diff; COMMIT_BLOCK_SHA=block; PRIOR_RATE_SHA=x; PRIOR_SIGNED_SHA=x; PRIOR_SNAPSHOT_ID=1; CONFIG_DISK_SHA=x; OVERLAY_DISK_SHA=x; ACK_MOVES_SHA=x\n'
                code += 'record() { :; }; pf_pricing_detect() { :; }\n'
                code += function(CONTENT, name) + '\n' + name + '\n'
                result = self.shell(code, dict(TEST_WORK=str(work), TEST_TOOLS=str(self.tools), ARG_LOG=str(log)))
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(log.read_text())
                self.assertNotIn('', args)
                self.assertNotIn('--native-binding-bundle', args)
                self.assertEqual(args[:7], ['content-gate', '--release', 'release', '--live', 'live', '--commit', 'abc'])

    def test_ops_context_uses_verified_release_and_input_and_legacy_resets(self):
        code = '''set -eu
REPO_ROOT="$TEST_ROOT"; AUTOTUNE=catalog; OPS_TMP_DIR="$TEST_ROOT"
NATIVE_BINDING_RECIPE="$TEST_RECIPE"; CATALOG_NATIVE_BINDING_BUNDLE="$TEST_BUNDLE"
fact() { :; }
json_field() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))' "$1" "$2"; }
'''
        # Isolated fake CLI boundary: no live or remote command is reachable.
        shutil.copytree(self.tools, self.root / 'scripts')
        code += function(OPS, 'native_binding_context')
        code += '\nnative_binding_context abc\nprintf "%s\\n" "$CATALOG_TARGET_DIR" "$CATALOG_TARGET_INPUT"\nunset CATALOG_NATIVE_BINDING_BUNDLE\nnative_binding_context abc\nprintf "%s\\n" "$CATALOG_TARGET_DIR" "$CATALOG_TARGET_INPUT"\n'
        result = self.shell(code, dict(TEST_ROOT=str(self.root), TEST_RECIPE=RECIPE, TEST_BUNDLE=str(self.bundle)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.bundle / 'release'), str(self.bundle / 'derived/native-mtp-admission-release.json'), str(self.root / 'catalog'), str(self.root / 'catalog/native-mtp-admission-release.json')])

    def test_ops_context_reports_waiver_only_after_full_verification(self):
        shutil.copytree(self.tools, self.root / 'scripts')
        code = """set -eu
REPO_ROOT="$TEST_ROOT"; AUTOTUNE=catalog; OPS_TMP_DIR="$TEST_ROOT"
NATIVE_BINDING_RECIPE="$TEST_RECIPE"; CATALOG_NATIVE_BINDING_BUNDLE="$TEST_BUNDLE"
fact() { printf '%s: %s\n' "$1" "$2"; }
json_field() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))' "$1" "$2"; }
"""
        code += function(OPS, 'native_binding_context') + '\nnative_binding_context publication\n'
        log = self.root / 'verify-args.json'
        env = dict(TEST_ROOT=str(self.root), TEST_RECIPE=RECIPE,
                   TEST_BUNDLE=str(self.bundle), SERVING_JOURNEY='waived (operator, 2026-10-29)',
                   VERIFY_ARGS=str(log))
        result = self.shell(code, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('serving_journey: waived (operator, 2026-10-29)', result.stdout)
        args = json.loads(log.read_text())
        self.assertEqual(args[args.index('--commit') + 1], 'publication')
        result = self.shell(code, dict(env, REJECT_PROOF='1'))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('serving_journey:', result.stdout)

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

    def test_signed_pair_reverifies_bundle_before_publish_dispatch(self):
        text = function(OPS, 'signed_pair_internal')
        self.assertLess(text.index('native_binding_context "$commit"'), text.index('catalog-content-release.sh'))
        self.assertIn('--deploy --commit "$commit"', text)

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

    def test_native_release_match_is_before_fresh_steps_and_rechecks_signed_pair(self):
        gather = function(OPS, 'gather')
        gate = gather.index('native_mtp_release_preflight "$native_bound" || return 0')
        self.assertLess(gate, gather.index('set_next revocation_slots mutate'))
        self.assertLess(gate, gather.index('if [ "$live_rid" = "$R" ]; then'))
        self.assertLess(gate, gather.index('set_next signed_native_pair mutate'))
        # Recovery intentionally precedes candidate validation.
        self.assertLess(gather.index('set_next signed_native_pair_reconcile mutate'), gate)
        pair = function(OPS, 'signed_pair_internal')
        self.assertLess(pair.index('native_mtp_release_preflight true'),
                        pair.index('catalog-content-release.sh'))

    def test_final_byte_manifest_accepts_verified_derived_bundle(self):
        result, work = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = CONTENT.read_text()
        start = text.index('if [ -n "$NATIVE_BINDING_BUNDLE" ]; then', text.index('# Both assembly paths freeze'))
        end = text.index('\nIFS= read -r -d', start)
        code = 'set -eu\nWORK="$TEST_WORK"; REL="$TEST_RELEASE"; REPO_ROOT="$TEST_REPO"; COMMIT="$TEST_COMMIT"\n'
        code += 'SCRIPT_DIR="$TEST_TOOLS"; NATIVE_BINDING_BUNDLE="$TEST_BUNDLE"; NATIVE_BINDING_RECIPE="$TEST_RECIPE"; NATIVE_BINDING_PROOF="$WORK/native-binding-proof.json"\nfatal() { echo "$*" >&2; exit 61; }\n'
        code += text[start:end]
        result = self.shell(code, dict(TEST_WORK=str(work), TEST_RELEASE=str(work / 'binding/caller-bundle/release'), TEST_REPO=str(self.repo), TEST_COMMIT=self.commit, TEST_TOOLS=str(self.tools), TEST_BUNDLE=str(work / 'binding/caller-bundle'), TEST_RECIPE=RECIPE))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((work / 'release-bytes.sha256').exists())
        env = dict(TEST_WORK=str(work), TEST_RELEASE=str(work / 'binding/caller-bundle/release'), TEST_REPO=str(self.repo), TEST_COMMIT=self.commit, TEST_TOOLS=str(self.tools), TEST_BUNDLE=str(work / 'binding/caller-bundle'), TEST_RECIPE=RECIPE)
        (work / 'gate/release-ledger.json').write_text('changed-under-lease')
        result = self.shell(code, env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ledger changed', result.stderr)
        (work / 'gate/release-ledger.json').write_text('derived-ledger')
        proof = work / 'native-binding-proof.json'
        proof.write_text(proof.read_text() + ' ')
        result = self.shell(code, env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('receipt changed', result.stderr)


if __name__ == '__main__':
    unittest.main()
