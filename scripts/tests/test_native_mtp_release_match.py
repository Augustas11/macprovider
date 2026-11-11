"""Exact provider matcher and independent release provenance regressions."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_mtp_release_match', ROOT / 'scripts/native_mtp_release_match.py')
MATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATCH)


class ReleaseMatchTests(unittest.TestCase):
    def setUp(self):
        self.entry = dict(model_key='glm/test', artifact_hash='a' * 64,
            hardware_class='apple-m3-ultra', ram_bytes=256 * 1024**3,
            qualified_slots=4, runtime_revision='b' * 40,
            decode_path_digest='c' * 64, metallib_sha256='d' * 64)
        self.admission = {'entries': [self.entry]}
        self.scope = {'entries': []}
        self.identity = {field: self.entry[field] for field in MATCH.IDENTITY_FIELDS}

    def test_signed_entries_need_no_packaged_scope_or_release_identity(self):
        # SPEC-048 0.1.81: a new tuple's admission activates without a CLI cut,
        # and a CLI cut with a different runtime identity needs no rebind.
        MATCH.verify_entries(self.admission)
        for field, wrong in dict(runtime_revision='0' * 40, decode_path_digest='0' * 64,
                                 metallib_sha256='0' * 64).items():
            with self.subTest(field=field):
                admission = copy.deepcopy(self.admission)
                admission['entries'][0][field] = wrong
                MATCH.verify_entries(admission)

    def test_missing_scope_field_refuses_and_names_it(self):
        for field in MATCH.SCOPE_FIELDS:
            with self.subTest(field=field):
                admission = copy.deepcopy(self.admission)
                del admission['entries'][0][field]
                with self.assertRaisesRegex(MATCH.MatchError, field):
                    MATCH.verify_entries(admission)

    def test_duplicate_matching_context_rejected_even_with_distinct_sort_keys(self):
        self.admission['entries'].append(dict(self.entry, artifact_id='other', proposal_depth=2))
        with self.assertRaisesRegex(MATCH.MatchError, 'entries.*ambiguous'):
            MATCH.verify_entries(self.admission)

    def test_empty_admission_fails_closed(self):
        for admission in ({}, {'entries': []}, {'entries': ['x']}):
            with self.subTest(admission=admission), self.assertRaises(MATCH.MatchError):
                MATCH.verify_entries(admission)

    def test_integer_fields_do_not_accept_booleans_or_strings(self):
        for field in ('ram_bytes', 'qualified_slots'):
            for value in (True, '4', None):
                with self.subTest(field=field, value=value):
                    admission = copy.deepcopy(self.admission)
                    admission['entries'][0][field] = value
                    with self.assertRaisesRegex(MATCH.MatchError, field):
                        MATCH.verify_entries(admission)

    def test_source_identity_reads_package_pin_at_release_commit(self):
        commit = 'a' * 40
        resolved = {'pins': [{'identity': 'mlx-swift-lm', 'state': {'revision': 'b' * 40}}]}
        with mock.patch.object(MATCH, 'run', side_effect=[json.dumps(resolved), 'let binaryVersion = "1.8.277"']) as run:
            self.assertEqual(MATCH.source_identity(ROOT, commit), ('b' * 40, '1.8.277'))
        self.assertEqual(run.call_args_list[0].args[0][-1], f'{commit}:phase3-binary/Package.resolved')

    def test_source_requires_unique_pin_and_full_commit(self):
        with self.assertRaisesRegex(MATCH.MatchError, 'source_commit'):
            MATCH.source_identity(ROOT, 'main')
        for pins in ([], [{'identity': 'mlx-swift-lm', 'state': {'revision': 'b' * 40}}] * 2):
            with mock.patch.object(MATCH, 'run', return_value=json.dumps({'pins': pins})):
                with self.assertRaisesRegex(MATCH.MatchError, 'runtime_revision'):
                    MATCH.source_identity(ROOT, 'a' * 40)

    def test_duplicate_json_fields_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'admission.json'
            path.write_text('{"entries":[],"entries":[{}]}')
            with self.assertRaisesRegex(MATCH.MatchError, 'duplicate key'):
                MATCH.load_json(path)

    def test_unknown_signer_and_invalid_signature_refused(self):
        tool = mock.Mock()
        tool.parse_sidecar.return_value = ('untrusted', b'signature')
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'admission.json'
            path.write_text('{}')
            with self.assertRaisesRegex(MATCH.MatchError, 'admission_signature'):
                MATCH.verify_admission_signature(tool, path, path, {})
            tool.verify_ed25519.side_effect = RuntimeError('signature invalid')
            with self.assertRaisesRegex(RuntimeError, 'signature invalid'):
                MATCH.verify_admission_signature(tool, path, path, {'untrusted': b'key'})

    def test_unsigned_target_cannot_borrow_static_signature_for_different_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            static = root / 'phase3-binary/dist/static/native-mtp-admission.json'
            static.parent.mkdir(parents=True)
            static.write_text('{"entries":[]}')
            admission = root / 'admission.json'
            admission.write_text('{"entries":[{}]}')
            release = root / 'release.json'
            release.write_text(json.dumps({'entry': {'source_commit': 'a' * 40}}))
            args = argparse.Namespace(repo=root, release_input=release, admission=admission,
                state_dir=root, release_dir=root)
            with mock.patch.object(MATCH, 'source_identity', return_value=('a' * 40, '1.8.277')), \
                 mock.patch.object(MATCH, 'verify_release', return_value=(self.scope, self.identity, {})):
                with self.assertRaisesRegex(MATCH.MatchError, 'admission_signature'):
                    MATCH.verify(args)

    def test_explicit_artifact_directory_is_still_verified(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp)
            # Choosing a cache only resolves a location; absent signed release
            # provenance is rejected by verify_release before any matcher runs.
            selected = MATCH.release_directory(ROOT, path, path, '1.8.277')
            with self.assertRaises(FileNotFoundError):
                MATCH.verify_release(ROOT, selected, 'a' * 40, '1.8.277')


if __name__ == '__main__':
    unittest.main()
