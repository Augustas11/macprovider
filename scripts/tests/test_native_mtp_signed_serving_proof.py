"""Small offline checks; no signing, hardware or GitHub access."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPT = Path(__file__).resolve().parents[1]/'native_mtp_signed_serving_proof.py'
spec = importlib.util.spec_from_file_location('serving_proof',SCRIPT)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
SOURCE = 'a'*40
CONTROL = 'b'*40


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.receipt = dict(schema=p.SCHEMA,run_id=7,artifact_id=8,export_sha256='c'*64)
        self.run = dict(id=7,status='completed',conclusion='success',event='workflow_dispatch',head_branch='main',path=p.WORKFLOW,
                        repository={'full_name':p.REPOSITORY},head_repository={'full_name':p.REPOSITORY},head_sha=CONTROL,run_attempt=2)
        self.compare = dict(status='ahead',merge_base_commit={'sha':CONTROL})
        self.artifact = dict(id=8,name=f'signed-native-mtp-serving-journey-evidence-{SOURCE}',expired=False,
                             digest='sha256:'+'c'*64,workflow_run={'id':7,'head_sha':CONTROL})

    def auth(self):
        with mock.patch.object(p,'gh',side_effect=[self.run,self.compare,self.artifact]):
            return p.authenticate(self.receipt,SOURCE)

    def test_authenticated_metadata(self):
        self.assertEqual(self.auth(),(self.run,self.artifact))

    def test_reject_metadata_mutations(self):
        cases = [('run','conclusion','failure'),('run','path','.github/workflows/other.yml'),
                 ('run','head_branch','feature'),('run','event','push'),('artifact','expired',True),
                 ('artifact','digest','sha256:'+'d'*64),('artifact','id',9),('compare','status','diverged')]
        for obj,key,value in cases:
            with self.subTest(obj=obj,key=key):
                target = getattr(self,obj); old=target[key]; target[key]=value
                with self.assertRaises(ValueError):self.auth()
                target[key]=old

    def test_reject_fork_and_wrong_artifact_run(self):
        self.run['head_repository']['full_name']='attacker/macprovider'
        with self.assertRaises(ValueError):self.auth()
        self.run['head_repository']['full_name']=p.REPOSITORY
        self.artifact['workflow_run']['id']=99
        with self.assertRaises(ValueError):self.auth()

    def test_receipt_closed_and_ids_not_boolean(self):
        self.receipt['callback']='true'
        with self.assertRaises(ValueError):self.auth()
        del self.receipt['callback']; self.receipt['run_id']=True
        with self.assertRaises(ValueError):self.auth()

    def archive(self,items):
        stream=io.BytesIO()
        with zipfile.ZipFile(stream,'w') as z:
            for name,data in items:z.writestr(name,data)
        return stream.getvalue()

    def unpack(self,data,digest=None):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'export.zip';path.write_bytes(data)
            return p.export_bytes(path,digest or p.sha(data))

    def test_bounded_archive(self):
        data=self.archive([('evidence-manifest.json',b'{}'),('journeys/evidence/a.json',b'{}')])
        self.assertEqual(len(self.unpack(data)),2)
        with self.assertRaises(ValueError):self.unpack(data,'0'*64)

    def test_archive_traversal_and_alias_rejected(self):
        for name in ('../bad','/bad','journeys//bad','journeys/./bad','journeys/bad/'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                self.unpack(self.archive([('evidence-manifest.json',b'{}'),(name,b'{}')]))

    def test_archive_symlink_rejected(self):
        info=zipfile.ZipInfo('journeys/link');info.external_attr=0o120777<<16
        with self.assertRaises(ValueError):self.unpack(self.archive([('evidence-manifest.json',b'{}'),(info,b'x')]))

    def manifest_fixture(self):
        prefix='journeys/evidence/native-mtp-serving-20261026T000000Z'
        m=dict(schema_version='macprovider.signed-native-mtp-serving-journey-evidence.v1',source_sha=SOURCE,evidence_sha=CONTROL,
               requirement_ids=['SPEC-048:R001'],journey_id='JOURNEY-NATIVE-MTP-SERVING',redacted_artifact=prefix+'.redacted.json',
               redaction_manifest=prefix+'/MANIFEST.sha256',signed_envelope=prefix+'.journey-result.signed.json',
               workflow_run_id='7',workflow_run_attempt='2')
        files={m['redacted_artifact']:b'{}',m['redaction_manifest']:b'manifest',m['signed_envelope']:b'{}'}
        for key,digest in [('redacted_artifact','redacted_sha256'),('redaction_manifest','redaction_manifest_sha256'),('signed_envelope','signed_envelope_sha256')]:
            m[digest]=p.sha(files[m[key]])
        files['evidence-manifest.json']=json.dumps(m).encode()
        return files,m

    def test_export_manifest_bindings(self):
        files,m=self.manifest_fixture()
        self.assertEqual(p.validate_manifest(files,self.receipt,self.run,SOURCE),m)
        files[m['redacted_artifact']]=b'changed'
        with self.assertRaises(ValueError):p.validate_manifest(files,self.receipt,self.run,SOURCE)

    def test_export_run_attempt_and_extra_files_rejected(self):
        files,m=self.manifest_fixture();m['workflow_run_attempt']='1'
        files['evidence-manifest.json']=json.dumps(m).encode()
        with self.assertRaises(ValueError):p.validate_manifest(files,self.receipt,self.run,SOURCE)
        files,m=self.manifest_fixture();files['run.sh']=b'exit 0'
        with self.assertRaises(ValueError):p.validate_manifest(files,self.receipt,self.run,SOURCE)

    def test_duplicate_json_rejected(self):
        with self.assertRaises(ValueError):p.parse(b'{"run_id":1,"run_id":2}')

    def test_sidecar_exact_and_trusted_key_required(self):
        files,m=self.manifest_fixture()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'security').mkdir()
            (root/'security/acceptance-candidate-signing-public.pem').write_bytes(b'fake')
            with self.assertRaisesRegex(ValueError,'key changed'):
                p.validate_checkout(root,files,m,self.run,b'{}')
            with mock.patch.object(p,'PUBLIC_KEY_SHA256',p.sha(b'fake')):
                with self.assertRaisesRegex(ValueError,'sidecar differs'):
                    p.validate_checkout(root,files,m,self.run,b'{}')

    def test_projection_and_signed_validator_both_mandatory(self):
        for tampered in (False, True):
            files,m=self.manifest_fixture()
            bundle=m['redacted_artifact'].removesuffix('.redacted.json')
            files[bundle+'/native-mtp-admission.json']=b'exact-sidecar'
            files[bundle+'/postcut-provenance.json']=b'{}'
            payload={'requirement_ids':m['requirement_ids'],'steps':[{'id':'genuine'}]}
            envelope={'signed':payload if not tampered else {},'signatures':[{'verifier':f'{p.WORKFLOW}:7:2'}]}
            files[m['signed_envelope']]=json.dumps(envelope).encode()
            with tempfile.TemporaryDirectory() as d:
                root=Path(d);(root/'security').mkdir()
                (root/'security/acceptance-candidate-signing-public.pem').write_bytes(b'key')
                def command(argv,**kwargs):
                    if 'payload' in argv:(root/'serving-proof-payload.json').write_text(json.dumps(payload))
                with mock.patch.object(p,'PUBLIC_KEY_SHA256',p.sha(b'key')), mock.patch.object(p.subprocess,'run',side_effect=command) as run:
                    if tampered:
                        with self.assertRaisesRegex(ValueError,'complete builder projection'):
                            p.validate_checkout(root,files,m,self.run,b'exact-sidecar')
                        self.assertEqual(run.call_count,2)
                    else:
                        self.assertEqual(p.validate_checkout(root,files,m,self.run,b'exact-sidecar'),payload)
                        self.assertEqual(run.call_count,3)
                        self.assertTrue(str(run.call_args.args[0][1]).endswith('validate-signed-journey-result.py'))

    def test_orchestration_requires_fresh_auth_before_extraction(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'receipt.json').write_text(json.dumps(self.receipt))
            with mock.patch.object(p,'authenticate',side_effect=ValueError('offline')) as auth, mock.patch.object(p,'export_bytes') as unpack:
                with self.assertRaisesRegex(ValueError,'offline'):
                    p.verify_serving_proof(root,root,SOURCE,root/'sidecar')
                auth.assert_called_once();unpack.assert_not_called()


if __name__=='__main__':unittest.main()
