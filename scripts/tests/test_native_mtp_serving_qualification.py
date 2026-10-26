"""No-hardware public qualification revalidation boundary tests."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('public_serving_qualification',HERE/'native_mtp_binding_bundle.py')
M=importlib.util.module_from_spec(spec);sys.modules[spec.name]=M;spec.loader.exec_module(M)

class PublicQualificationTests(unittest.TestCase):
    def fixture(self,root):
        source='a'*40;bundle=root/'bundle';(bundle/'release').mkdir(parents=True)
        identity=dict(source_commit=source,provider_revision=source,reproducible_build_sha256='b'*64,live_executable_cdhash='c'*40,metallib_sha256='d'*64)
        result={name:'e'*64 for name in ('security_negative_evidence_sha256','correctness_evidence_sha256','batch_evidence_sha256','performance_evidence_sha256','benchmark_policy_sha256')}
        bounds=dict(request_feature_profile='native_mtp_sampled_text_v1',proposal_depth=1,max_native_active_rows=1,max_prompt_tokens=4096,qualified_slots=4)
        reused=['fit_evidence_sha256','quality_evidence_sha256','state_rollback_evidence_sha256']
        entry=dict(model_key='zai-org/glm-5.3-flash',**identity,**bounds,**result,**{name:'f'*64 for name in reused})
        original=dict(entry,security_negative_evidence_sha256='0'*64)
        recipe=dict(model_key=entry['model_key'],source_inputs={},phases={'expanded_glm_sampled':bounds},reused_evidence_keys=reused)
        (bundle/'inputs.json').write_text(json.dumps(dict(phase='expanded_glm_sampled',identity=identity)))
        sidecar=bundle/'release/native-mtp-admission.json';sidecar.write_text(json.dumps({'entries':[entry]}))
        def archive(repo,commit,stage):
            path=stage/M.CATALOG/'native-mtp-admission-tuple.json';path.parent.mkdir(parents=True);path.write_text(json.dumps([{'entry':original}]))
        return bundle,source,sidecar,recipe,result,archive

    def test_reopens_actual_qualification_without_serving_proof_or_global_env_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);bundle,source,sidecar,recipe,result,archive=self.fixture(root)
            generator=SimpleNamespace(strict_json_loads=json.loads,validate_sidecar=lambda value:value)
            before=dict(os.environ)
            with patch.object(M,'_recipe',return_value=(recipe,'x')),patch.object(M,'_archive',side_effect=archive),patch.object(M,'_module',return_value=generator),patch.object(M,'_run',return_value=b'') as run,patch.object(M,'_qualification',return_value=result) as qualify:
                self.assertEqual(M.validate_serving_qualification(bundle,repo=root,source_commit=source,sidecar_path=sidecar,entry_index=0),result)
            self.assertEqual(os.environ,before)
            self.assertEqual(qualify.call_args.args[2]['security_negative_evidence_sha256'],'0'*64)
            self.assertEqual(qualify.call_args.kwargs,{'repo':root.resolve()})
            self.assertIn('verify-directory',run.call_args.args[0])
            self.assertIn('env',run.call_args.kwargs)

    def test_actual_recomputed_digest_must_equal_sidecar(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);bundle,source,sidecar,recipe,result,archive=self.fixture(root)
            generator=SimpleNamespace(strict_json_loads=json.loads,validate_sidecar=lambda value:value)
            changed=dict(result,performance_evidence_sha256='1'*64)
            with patch.object(M,'_recipe',return_value=(recipe,'x')),patch.object(M,'_archive',side_effect=archive),patch.object(M,'_module',return_value=generator),patch.object(M,'_run',return_value=b''),patch.object(M,'_qualification',return_value=changed):
                with self.assertRaisesRegex(M.BindingBundleError,'actual evidence'):
                    M.validate_serving_qualification(bundle,repo=root,source_commit=source,sidecar_path=sidecar,entry_index=0)

if __name__=='__main__':unittest.main()
