import contextlib
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('privacy_buyer_confirm', Path(__file__).resolve().parents[1] / 'ops/lib/privacy-buyer-confirm.py')
buyer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(buyer)


class BuyerConfirmationTests(unittest.TestCase):
    def run_case(self, failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('client', 'key', 'pin'):
                (root / name).write_text('private-test-fixture')
            (root / 'key').chmod(0o600)
            env = {'MACPROVIDER_OPS_ENTRYPOINT': '1', 'PRIVACY_BUYER_CLIENT': str(root / 'client'),
                   'BUYER_TOKEN_FILE': str(root / 'key'), 'PRIVACY_BUYER_PIN': str(root / 'pin'),
                   'PRIVACY_DIRECTORY_PUBLIC_KEY': 'public-test-fixture', 'GATEWAY_URL': 'https://api.malibu.tech'}
            output = io.StringIO()
            result = subprocess.CompletedProcess([], 1 if failure else 0, 'private response content',
                                                 'failure' if failure else 'privacy class satisfied;')
            with patch.dict(os.environ, env, clear=True), patch.object(buyer, 'CLIENT_SHA256', hashlib.sha256(b'private-test-fixture').hexdigest()), patch.object(buyer.subprocess, 'run', return_value=result) as run, contextlib.redirect_stdout(output):
                rc = buyer.main()
            self.assertNotIn('private response content', output.getvalue())
            self.assertNotIn('private-test-fixture', output.getvalue())
            self.assertEqual(rc, 1 if failure else 0)
            self.assertEqual(run.call_count, 1 if failure else 4)
            self.assertEqual(json.loads(output.getvalue())['accepted'], not failure)
            for call in run.call_args_list:
                args = call.args[0]
                request = json.loads(call.kwargs['input'])
                self.assertEqual(request['max_tokens'], int(args[args.index('--max-output-tokens') + 1]))
                self.assertIn('--privacy-class', args)
                self.assertEqual(set(call.kwargs['env']), {'MACPROVIDER_API_KEY'})
            if not failure:
                self.assertEqual(sum('--stream' in call.args[0] for call in run.call_args_list), 2)
                self.assertEqual(sum('--directory-public-key' in call.args[0] for call in run.call_args_list), 2)

    def test_pin_and_directory_stream_matrix(self):
        self.run_case()

    def test_failed_private_request_is_not_retried_or_downgraded(self):
        self.run_case(failure=True)

    def test_refuses_direct_invocation(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
            buyer.main()
