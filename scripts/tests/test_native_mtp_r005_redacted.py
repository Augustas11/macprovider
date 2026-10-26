import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO=next(p for p in Path(__file__).resolve().parents if (p/'AGENTS.md').is_file())
sys.path.insert(0,str(REPO/'scripts'));sys.path.insert(0,str(REPO))
spec=importlib.util.spec_from_file_location('r005_redacted',Path(__file__).resolve().parents[1]/'native_mtp_r005_redacted.py')
n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
from scripts.tests import test_native_mtp_binding_bundle as coretests


class ProjectionTests(unittest.TestCase):
    def raw(self):
        result,policy,corpus,entry=coretests.BindingCoreTests().fixture()
        for i,case in enumerate(result['cases']):
            terminal=('eos','stopSequence','maxTokens','toolBoundary')[i%4]
            case['ordinary_terminal']=case['native_terminal']=terminal
        result.update(accepted=100,rejected=100,near_tied_positions=6400)
        entry['correctness_evidence_sha256']='f'*64
        return result,policy,corpus,entry

    def project(self,raw=None):
        r,p,c,e=raw or self.raw()
        return n.project_acceptance(r,p,c,e,raw_result_sha256='f'*64,policy_sha256='e'*64,corpus_sha256='d'*64,
            custody={'commit':'a'*40,'record_sha256':'b'*64}),e

    def test_actual_full_private_gate_and_closed_public_projection(self):
        value,entry=self.project()
        proof=n.validate_projection(value,entry)
        self.assertEqual(proof['raw_result_sha256'],'f'*64)
        self.assertFalse(value['private_data_reopened_by_public_validator'])
        self.assertFalse(value['independent_hardware_attestation'])
        encoded=n.canonical(value)
        for forbidden in (b'ordinary_token',b'native_token',b'ordinary_top1"',b'native_top1"',b'prompt"',b'messages',b'completion_text'):
            self.assertNotIn(forbidden,encoded)
        self.assertEqual(len(value['cases']),200)

    def test_raw_mismatch_cannot_project_even_if_pass_true(self):
        raw=self.raw();raw[0]['cases'][0]['positions'][0]['native_token']=999
        with self.assertRaises(ValueError):self.project(raw)

    def test_private_numeric_failure_cannot_project(self):
        raw=self.raw();raw[0]['cases'][0]['positions'][0]['max_abs_difference']=0.051
        with self.assertRaises(ValueError):self.project(raw)

    def test_public_mutations_rejected(self):
        original,entry=self.project()
        changes=[lambda v:v.update(private_data_reopened_by_public_validator=True),
                 lambda v:v.update(raw_result_sha256='0'*64),
                 lambda v:v['cases'][0]['positions'][0].update(max_abs_difference=0.1),
                 lambda v:v['cases'][0]['positions'][0].update(ordinary_gap=float('nan')),
                 lambda v:v['cases'][0]['positions'][0].update(ordinary_token=1),
                 lambda v:v['cases'][0]['selected_sequences'].update(native_sha256='0'*64),
                 lambda v:v['coverage'].update(accepted=0),
                 lambda v:v['coverage'].update(near_tied_positions=1),
                 lambda v:v['custody'].update(private_path='/Users/private'),
                 lambda v:v.update(native_compared_positions=6399)]
        for change in changes:
            value=copy.deepcopy(original);change(value)
            with self.subTest(change=change),self.assertRaises(ValueError):n.validate_projection(value,entry)

    def test_missing_case_or_duplicate_case_rejected(self):
        value,entry=self.project();value['cases'].pop()
        with self.assertRaises(ValueError):n.validate_projection(value,entry)
        value,entry=self.project();value['cases'][1]['id']=value['cases'][0]['id']
        with self.assertRaises(ValueError):n.validate_projection(value,entry)

    def test_custody_checks_actual_committed_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            def git(*args):return subprocess.check_output(['git',*args],cwd=root,stderr=subprocess.DEVNULL).decode().strip()
            git('init','-q');git('config','user.name','test');git('config','user.email','test@example.invalid')
            raw=b'actual private window log';(root/'raw.json').write_bytes(raw)
            record={'schema':'macprovider.native-mtp-serving-private-custody.v1','artifacts':{'result':{'path':'raw.json','sha256':n.sha(raw)}}}
            (root/'custody.json').write_bytes(n.canonical(record));git('add','.');git('commit','-qm','fixture')
            commit=git('rev-parse','HEAD')
            public=n.verify_private_custody(root,commit,'custody.json',{'result':n.sha(raw)})
            self.assertEqual(set(public),{'commit','record_sha256'})
            with self.assertRaises(ValueError):n.verify_private_custody(root,commit,'custody.json',{'result':'0'*64})
            (root/'raw.json').write_bytes(b'changed uncommitted')
            self.assertEqual(n.verify_private_custody(root,commit,'custody.json',{'result':n.sha(raw)}),public)


if __name__=='__main__':unittest.main()
