import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / 'catalog-content-release.sh'


def function(name):
    text = CONTENT.read_text()
    start = text.index(name + '() {')
    end = text.index('\n}', start) + 2
    return text[start:end]


class SignedPairContentTests(unittest.TestCase):
    def run_function(self, name, *, decision=0, studio=1, fail='', terminal=0):
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            code = '''set -u
WORK="$1"; TRACE="$WORK/trace"; : > "$TRACE"
SIGNED_PAIR_TXID=test; SIGNED_PAIR_ARMED=1; SIGNED_PAIR_STUDIO_ARMED="$2"; SIGNED_PAIR_TERMINAL="$3"
record() { printf '%s\\n' "$1" >> "$TRACE"; [ "$1" != "$FAIL" ]; }
aa_signed_pair_recover() { record recover; return "$DECISION"; }
aa_signed_pair_runner_restore() { record runner_restore; }
aa_signed_pair_commit() { record pearl_commit; }
aa_signed_pair_runner_retire() { record runner_retire; }
aa_signed_pair_reader_retire() { record reader_retire; }
ccr_signed_pair_action() { record "studio_$1"; }
ccr_signed_pair_state() { record "state_$1"; }
'''
            code += function(name)
            code += '\n' + name + '\nrc=$?\nprintf "rc=%s\\n" "$rc"\ncat "$TRACE"\n'
            result = subprocess.run(['bash', '-c', code, 'test', raw, str(studio), str(terminal)],
                                    env={'HOME': raw, 'PATH': '/usr/bin:/bin', 'DECISION': str(decision), 'FAIL': fail},
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.splitlines()

    def test_commit_preserves_decision_order(self):
        self.assertEqual(self.run_function('ccr_signed_pair_finish'), [
            'rc=0', 'studio_prepare-commit', 'runner_restore', 'pearl_commit',
            'studio_commit', 'runner_retire', 'reader_retire', 'state_terminal'])

    def test_commit_relay_failure_converges_to_target(self):
        result = self.run_function('ccr_signed_pair_cleanup', decision=2)
        self.assertIn('studio_commit', result)
        self.assertNotIn('studio_rollback', result)
        self.assertEqual(result[0], 'rc=0')

    def test_prior_restore_precedes_binary_restore(self):
        self.assertEqual(self.run_function('ccr_signed_pair_cleanup'), [
            'rc=0', 'recover', 'studio_rollback', 'runner_restore',
            'runner_retire', 'reader_retire', 'state_terminal'])

    def test_unresolved_decision_keeps_recovery_custody(self):
        result = self.run_function('ccr_signed_pair_cleanup', decision=1)
        self.assertEqual(result, ['rc=1', 'recover', 'runner_restore'])

    def test_before_studio_arm_never_dispatches_binary_rollback(self):
        result = self.run_function('ccr_signed_pair_cleanup', studio=0)
        self.assertNotIn('studio_rollback', result)
        self.assertEqual(result[0], 'rc=0')

    def test_retirement_failure_does_not_acknowledge_terminal(self):
        result = self.run_function('ccr_signed_pair_cleanup', fail='reader_retire')
        self.assertEqual(result[0], 'rc=1')
        self.assertNotIn('state_terminal', result)

    def test_terminal_cleanup_does_not_repeat_remote_mutations(self):
        self.assertEqual(self.run_function('ccr_signed_pair_cleanup', terminal=1), ['rc=0'])

    def test_target_policy_proof_precedes_install(self):
        text = CONTENT.read_text()
        start = text.index('if [ -n "$SIGNED_PAIR_PLAN" ]; then\n  # Loaded target')
        branch = text[start:text.index('\nelse\n  aa_post_activation_evidence', start)]
        self.assertLess(branch.index('ev_a_served_bytes && ev_b_journal'), branch.index('aa_signed_pair_activation_verified'))
        self.assertLess(branch.index('aa_signed_pair_activation_verified'), branch.index('ccr_signed_pair_action install'))


if __name__ == '__main__':
    unittest.main()
