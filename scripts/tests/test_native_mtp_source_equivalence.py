"""Model-free proof of reviewed LAB-only source equivalence; no hardware claim."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('source_equivalence_contract', HERE / 'native_mtp_source_equivalence.py')
M = importlib.util.module_from_spec(spec); sys.modules[spec.name] = M; spec.loader.exec_module(M)

def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'))+'\n').encode()

class ProjectionTests(unittest.TestCase):
    def test_lab_addition_removed_with_every_other_byte_preserved(self):
        before = b'let value = 1\n\nlet next = 2\n'
        after = b'let value = 1\n#if DEBUG || MACPROVIDER_LAB_HARNESS\nthrow Fault()\n#endif\n\nlet next = 2\n'
        self.assertEqual(M.release_projection(before), M.release_projection(after))

    def test_else_preserves_original_body_and_whitespace(self):
        before = b'  let value = 1\n\n'
        after = b'#if DEBUG || MACPROVIDER_LAB_HARNESS\nlet value = 2\n#else\n  let value = 1\n#endif\n\n'
        self.assertEqual(M.release_projection(before), M.release_projection(after))
        self.assertNotEqual(M.release_projection(before), M.release_projection(after.replace(b'1\n',b'1\n\n')))

    def test_unknown_conditionals_are_preserved(self):
        data = b'#if canImport(MLX)\nlet value = 1\n#else\nlet value = 2\n#endif\n'
        self.assertEqual(M.release_projection(data), data)

    def test_altered_or_negated_guard_is_never_exempted(self):
        for guard in (b'DEBUG', b'MACPROVIDER_LAB_HARNESS', b'!DEBUG || MACPROVIDER_LAB_HARNESS', b'DEBUG || MACPROVIDER_LAB_HARNESS || OTHER'):
            value = b'#if '+guard+b'\nlet changed = 1\n#endif\n'
            self.assertEqual(M.release_projection(value), value)

    def test_elseif_or_unbalanced_group_refused(self):
        for data in (b'#if DEBUG || MACPROVIDER_LAB_HARNESS\na\n#elseif OTHER\nb\n#endif\n', b'#if DEBUG || MACPROVIDER_LAB_HARNESS\na\n', b'#endif\n'):
            with self.assertRaises(M.SourceEquivalenceError): M.release_projection(data)

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.measured=M.MEASURED_SOURCE; self.current='b'*40
        self.manifest=encoded({'schema_version':'macprovider.decode-path-manifest.v1','files':['Sources/test.swift'],'dependencies':['mlx-swift']})
        self.resolved=encoded({'pins':[{'identity':'mlx-swift','state':{'revision':'a'*40}}]})
        self.old=b'let value = 1\n'
        self.new=b'#if DEBUG || MACPROVIDER_LAB_HARNESS\nlet lab = 1\n#endif\n'+self.old
        self.build={'phase3-binary/Package.swift':b'// package\n',
            'phase3-binary/dist/package.sh':b"xcodebuild -configuration Release SWIFT_ACTIVE_COMPILATION_CONDITIONS='' OTHER_SWIFT_FLAGS=''\n",
            '.github/workflows/acceptance-candidate.yml':b'./package.sh "$TAG"\n'}
        self.contract={'schema_version':M.SCHEMA,'measured_source_commit':self.measured,'lab_patch_sha256':'e'*64,
            'manifest_sha256':M.sha(self.manifest),'package_resolved_sha256':M.sha(self.resolved),
            'files':{'Sources/test.swift':{'measured_sha256':M.sha(self.old),'current_sha256':M.sha(self.new)}},
            'build_inputs':{key:M.sha(value) for key,value in self.build.items()}}
        self.blobs={}
        for source,code in ((self.measured,self.old),(self.current,self.new)):
            self.blobs[source,'phase3-binary/decode-path-manifest.json']=self.manifest
            self.blobs[source,'phase3-binary/Package.resolved']=self.resolved
            self.blobs[source,'phase3-binary/Sources/test.swift']=code
            for key,value in self.build.items(): self.blobs[source,key]=value
        self.repin()

    def repin(self):
        self.raw=encoded(self.contract)
        self.blobs[self.current,M.CONTRACT_PATH]=self.raw
        self.blobs[self.current,M.RECIPE_PATH]=encoded({'schema_version':'macprovider.native-mtp-binding-recipe.v1','model_key':'zai-org/glm-5.3-flash','source_inputs':{M.CONTRACT_PATH:M.sha(self.raw)}})

    def blob(self,root,source,path):
        try:return self.blobs[source,path]
        except KeyError:raise M.SourceEquivalenceError('missing blob')

    def run_proof(self):
        with patch.object(M,'git_blob',side_effect=self.blob):
            old=M.source_decode_digest(Path('.'),self.measured)
            new=M.source_decode_digest(Path('.'),self.current)
            return M.verify_source_equivalence(Path('.'),self.measured,self.current,old,new)

    def test_exact_reviewed_lab_delta_passes_and_keeps_raw_digests_distinct(self):
        self.assertEqual(self.run_proof(),M.sha(self.raw))

    def test_production_edit_refused_even_with_re_pinned_blob(self):
        value=self.new.replace(b'value = 1',b'value = 2')
        self.blobs[self.current,'phase3-binary/Sources/test.swift']=value
        self.contract['files']['Sources/test.swift']['current_sha256']=M.sha(value); self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'production decode'):self.run_proof()

    def test_changed_guard_refused_even_when_re_pinned(self):
        value=self.new.replace(b'DEBUG || MACPROVIDER_LAB_HARNESS',b'!DEBUG || MACPROVIDER_LAB_HARNESS')
        self.blobs[self.current,'phase3-binary/Sources/test.swift']=value
        self.contract['files']['Sources/test.swift']['current_sha256']=M.sha(value); self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'production decode'):self.run_proof()

    def test_changed_dependency_or_manifest_refused(self):
        for path,value,reason in (
            ('phase3-binary/Package.resolved',self.resolved.replace(b'a'*40,b'c'*40),'dependency'),
            ('phase3-binary/decode-path-manifest.json',self.manifest+b' ','manifest')):
            with self.subTest(path=path):
                old=self.blobs[self.current,path];self.blobs[self.current,path]=value
                with self.assertRaisesRegex(M.SourceEquivalenceError,reason):self.run_proof()
                self.blobs[self.current,path]=old

    def test_blob_or_recipe_pin_mismatch_refused(self):
        self.blobs[self.current,'phase3-binary/Sources/test.swift']+=b'\n'
        with self.assertRaisesRegex(M.SourceEquivalenceError,'blob mismatch'):self.run_proof()
        self.blobs[self.current,'phase3-binary/Sources/test.swift']=self.new
        self.blobs[self.current,M.CONTRACT_PATH]+=b' '
        with self.assertRaisesRegex(M.SourceEquivalenceError,'not recipe pinned'):self.run_proof()

    def test_unreviewed_flags_refused_even_with_re_pinned_build_input(self):
        key='phase3-binary/dist/package.sh'
        value=self.build[key]+b'xcodebuild -DDEBUG\n'
        self.blobs[self.current,key]=value
        self.contract['build_inputs'][key]=M.sha(value);self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'enables LAB or DEBUG'):self.run_proof()

    def test_missing_explicit_release_flags_refused(self):
        key='phase3-binary/dist/package.sh';value=b'xcodebuild -configuration Release\n'
        self.blobs[self.current,key]=value;self.contract['build_inputs'][key]=M.sha(value);self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'explicitly exclude'):self.run_proof()

    def test_false_waiver_or_unknown_contract_field_refused(self):
        self.contract['unchanged']=True;self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'fields differ'):self.run_proof()

    def test_package_settings_change_refused(self):
        key='phase3-binary/Package.swift';value=b'.define("DEBUG")\n'
        self.blobs[self.current,key]=value;self.contract['build_inputs'][key]=M.sha(value);self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'package settings'):self.run_proof()

    def test_older_measurement_source_requires_exact_byte_bridge_to_anchor(self):
        alias='c'*40
        for (source,path),value in list(self.blobs.items()):
            if source==self.measured:self.blobs[alias,path]=value
        self.measured=alias
        self.assertEqual(self.run_proof(),M.sha(self.raw))
        # Even an equal parsed manifest/raw digest cannot hide byte differences
        # on the bridge into the reviewed frozen campaign anchor.
        self.blobs[alias,'phase3-binary/decode-path-manifest.json']+=b' '
        with self.assertRaisesRegex(M.SourceEquivalenceError,'frozen equivalence anchor'):self.run_proof()

    def test_equal_raw_digest_preserves_existing_path_without_contract(self):
        self.blobs[self.current,'phase3-binary/Sources/test.swift']=self.old
        self.blobs.pop((self.current,M.CONTRACT_PATH));self.blobs.pop((self.current,M.RECIPE_PATH))
        self.assertIsNone(self.run_proof())


class HistoricalSampledBridgeTests(unittest.TestCase):
    def setUp(self):
        self.decoder=(b'static let sampledRequestFeatureProfile = "native_mtp_sampled_text_v1"\n'
                      b'sampling: selected.entry.requestFeatureProfile == Self.sampledRequestFeatureProfile\n'
                      b'supportsSampling: parsed.requestProfile.sampling\n')
        self.old_package=('// 3.32.3-macprovider.10.12\nrevision: "'+M.OLD_FORK+'"\n').encode()
        self.new_package=self.old_package.replace(M.OLD_FORK.encode(),M.NEW_FORK.encode()).replace(b'10.12',b'10.13')
        old_resolved=encoded({'pins':[{'identity':'mlx-swift-lm','state':{'revision':M.OLD_FORK}}]})
        new_resolved=encoded({'pins':[{'identity':'mlx-swift-lm','state':{'revision':M.NEW_FORK}}]})
        self.before=(b'manifest',old_resolved,{M.SELECTOR_PATH:M.OLD_SELECTOR+b'let tokens = 1\n'},'oldraw')
        self.anchor=(b'manifest',new_resolved,{M.SELECTOR_PATH:M.NEW_SELECTOR+b'let tokens = 1\n'},'newraw')
        self.proof={'measured_source_commit':M.W3_SOURCE,'files':{key:M.sha(value) for key,value in self.before[2].items()},
            'package_resolved_sha256':M.sha(old_resolved),'package_swift_sha256':M.sha(self.old_package),
            'profile_decoder_sha256':M.sha(self.decoder),'fork_inventory_sha256':'e'*64}
        self.recipe={'phases':{'expanded_glm_sampled':{'request_feature_profile':M.PROFILE}}}

    def run_bridge(self,profile=M.PROFILE):
        def blob(root,source,path):
            if path==M.PROFILE_DECODER_PATH:return self.decoder
            if path=='phase3-binary/Package.swift':return self.old_package if source==M.W3_SOURCE else self.new_package
            raise AssertionError(path)
        with patch.object(M,'git_blob',side_effect=blob),patch.object(M,'verify_test_only_fork_bridge') as fork:
            M.validate_historical_sampled_bridge(Path('.'),M.W3_SOURCE,self.before,self.anchor,self.proof,profile,self.recipe,current_source='b'*40)
        return fork

    def test_exact_sampled_profile_specialization_requires_real_fork_verifier(self):
        self.run_bridge().assert_called_once_with('e'*64)

    def test_greedy_profile_never_borrows_sampled_bridge(self):
        with self.assertRaisesRegex(M.SourceEquivalenceError,'frozen equivalence anchor'):
            self.run_bridge('native_mtp_greedy_text_v1')

    def test_token_change_or_changed_selector_span_refused(self):
        self.anchor[2][M.SELECTOR_PATH]+=b'let changed_token = 2\n'
        with self.assertRaisesRegex(M.SourceEquivalenceError,'production decode changed'):self.run_bridge()
        self.anchor[2][M.SELECTOR_PATH]=M.NEW_SELECTOR.replace(b'supportsSampling',b'otherFlag')
        with self.assertRaisesRegex(M.SourceEquivalenceError,'selector span differs'):self.run_bridge()

    def test_other_dependency_delta_refused(self):
        changed=copy.deepcopy(self.anchor);resolved=json.loads(changed[1]);resolved['pins'].append({'identity':'other','state':{'revision':'f'*40}})
        self.anchor=(changed[0],encoded(resolved),changed[2],changed[3])
        with self.assertRaisesRegex(M.SourceEquivalenceError,'dependency delta'):self.run_bridge()

    def test_changed_production_profile_decoder_refused(self):
        self.decoder=self.decoder.replace(b'== Self.sampledRequestFeatureProfile',b'!= Self.sampledRequestFeatureProfile')
        with self.assertRaisesRegex(M.SourceEquivalenceError,'profile decoder changed'):self.run_bridge()



class IntegrationReuseTests(unittest.TestCase):
    """The new bridge is a closed reviewed merge, not a generic waiver."""
    def setUp(self):
        ContractTests.setUp(self)
        self.measured = M.INTEGRATION_MEASURED_SOURCE
        self.reviewed = M.INTEGRATION_REVIEWED_SOURCE
        self.manifest = encoded({'schema_version':'macprovider.decode-path-manifest.v1',
            'files':['Sources/test.swift'],'dependencies':['mlx-swift-lm']})
        self.old_resolved = encoded({'pins':[{'identity':'mlx-swift-lm','state':{'revision':M.NEW_FORK}}]})
        self.new_resolved = encoded({'pins':[{'identity':'mlx-swift-lm','state':{'revision':M.INTEGRATION_FORK}}]})
        self.scope = copy.deepcopy(M.INTEGRATION_SCOPE)
        self.old = b'let reviewedTokenPath = 1\n'
        self.new = b'let reviewedTokenPath = 1\nlet unrelatedAdmissionOwnership = 2\n'
        self.blobs = {}
        for source, code, resolved in ((self.measured,self.old,self.old_resolved),
                (self.reviewed,self.new,self.new_resolved),(self.current,self.new,self.new_resolved)):
            self.blobs[source,'phase3-binary/decode-path-manifest.json'] = self.manifest
            self.blobs[source,'phase3-binary/Package.resolved'] = resolved
            self.blobs[source,'phase3-binary/Sources/test.swift'] = code
            for path, value in self.build.items(): self.blobs[source,path] = value
        self.contract = {'schema_version':M.INTEGRATION_SCHEMA,
            'measured_source_commit':self.measured,'reviewed_source_commit':self.reviewed,
            'tuple':self.scope,'measured_runtime_revision':M.NEW_FORK,
            'current_runtime_revision':M.INTEGRATION_FORK,'manifest_sha256':M.sha(self.manifest),
            'package_resolved':{'measured_sha256':M.sha(self.old_resolved),'current_sha256':M.sha(self.new_resolved)},
            'files':{'Sources/test.swift':{'measured_sha256':M.sha(self.old),'current_sha256':M.sha(self.new)}},
            'build_inputs':{path:{'measured_sha256':M.sha(value),'current_sha256':M.sha(value)}
                for path,value in self.build.items()},'reviewed_behavior':['Exact isolated GLM tuple, no contention claim.']}
        self.repin()

    blob = ContractTests.blob

    def repin(self):
        self.raw = encoded(self.contract)
        self.blobs[self.current,M.INTEGRATION_CONTRACT_PATH] = self.raw
        self.blobs[self.current,M.RECIPE_PATH] = encoded({'schema_version':'macprovider.native-mtp-binding-recipe.v1',
            'model_key':'zai-org/glm-5.3-flash','source_inputs':{M.INTEGRATION_CONTRACT_PATH:M.sha(self.raw)}})

    def run_proof(self, profile=M.PROFILE):
        with patch.object(M,'git_blob',side_effect=self.blob), patch.object(M,'integration_scope',return_value=self.scope):
            old = M.source_decode_digest(Path('.'),self.measured)
            new = M.source_decode_digest(Path('.'),self.current)
            return M.verify_source_equivalence(Path('.'),self.measured,self.current,old,new,
                request_feature_profile=profile)

    def entry(self):
        with patch.object(M,'git_blob',side_effect=self.blob):
            digest = M.source_decode_digest(Path('.'),self.current)
        return dict(self.scope, runtime_revision=M.INTEGRATION_FORK,decode_path_digest=digest,
            ordinary_baseline={'artifact_hash':self.scope['artifact_hash'],'qualified_slots':4,'decode_path':'ordinary'})

    def measured_tuple(self, entry):
        with patch.object(M,'git_blob',side_effect=self.blob), patch.object(M,'integration_scope',return_value=self.scope):
            digest = M.source_decode_digest(Path('.'),self.measured)
            return M.measurement_tuple(Path('.'),self.measured,self.current,digest,entry,M.NEW_FORK)

    def test_exact_reviewed_integration_passes_and_preserves_raw_runtime(self):
        self.assertEqual(self.run_proof(),M.sha(self.raw))
        entry = self.entry(); original = copy.deepcopy(entry)
        measured = self.measured_tuple(entry)
        self.assertEqual(entry, original)
        self.assertEqual(measured, dict(entry,runtime_revision=M.NEW_FORK))

    def test_changed_production_cannot_be_waived_even_by_repinning_contract(self):
        value = self.new+b'let changedVerify = true\n'
        self.blobs[self.current,'phase3-binary/Sources/test.swift'] = value
        self.contract['files']['Sources/test.swift']['current_sha256'] = M.sha(value); self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'reviewed merge'): self.run_proof()

    def test_changed_dependency_cannot_be_waived_even_by_repinning_contract(self):
        value = self.new_resolved.replace(M.INTEGRATION_FORK.encode(),b'f'*40)
        self.blobs[self.current,'phase3-binary/Package.resolved'] = value
        self.contract['package_resolved']['current_sha256'] = M.sha(value); self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'reviewed merge'): self.run_proof()

    def test_scope_change_or_foreign_artifacts_refused(self):
        for field, value in [('max_native_active_rows',2),('proposal_depth',2),('qualified_slots',8),
                ('max_prompt_tokens',8192),('artifact_hash','f'*64),('tokenizer_sha256','e'*64),
                ('request_feature_profile','native_mtp_greedy_text_v1')]:
            entry = self.entry(); entry[field] = value
            with self.subTest(field=field), self.assertRaises(M.SourceEquivalenceError): self.measured_tuple(entry)

    def test_profile_reuse_is_not_a_greedy_or_unknown_profile_exemption(self):
        for profile in (None,'native_mtp_greedy_text_v1','unknown'):
            with self.subTest(profile=profile), self.assertRaisesRegex(M.SourceEquivalenceError,'source/profile'):
                self.run_proof(profile)

    def test_new_release_build_flags_cannot_be_waived(self):
        path = 'phase3-binary/Package.swift'; value = b'.define("DEBUG")\n'
        self.blobs[self.current,path] = value
        self.contract['build_inputs'][path]['current_sha256'] = M.sha(value); self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'reviewed merge'): self.run_proof()

    def test_contract_pin_and_closed_shape_required(self):
        self.blobs[self.current,M.INTEGRATION_CONTRACT_PATH] += b' '
        with self.assertRaisesRegex(M.SourceEquivalenceError,'not recipe pinned'): self.run_proof()
        self.contract['waiver'] = True; self.repin()
        with self.assertRaisesRegex(M.SourceEquivalenceError,'fields differ'): self.run_proof()


if __name__ == '__main__':
    unittest.main()
