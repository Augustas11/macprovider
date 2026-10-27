#!/usr/bin/env python3
"""Reevaluate frozen observations and assemble one genuine serving journey.

Raw hardware/log/SQLite/CI/audit material stays in private inputs. Only a closed
public-safe projection can enter the output. prepare never completes step15;
finalize requires a durable actual review bound to the prepared byte inventory.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 'macprovider.native-mtp-serving-assembly.v1'
STEP_SCHEMA = 'macprovider.native-mtp-journey-step.v1'
MAX_FILE = 8 << 20
CATEGORIES = sorted(['credentials','payout_material','model_weights','model_tensors','raw_prompts',
                     'raw_completions','private_paths','operator_identity'])
CAPABILITY_CASES = {
    'NativeMTPAdmissionSidecarTests': ['testUnknownAndMissingFieldsReject','testDuplicateKeysRejectBeforeAdmission',
        'testDetachedSignatureAndExactSignerAreRequiredBeforeParsing','testTupleAndManifestDigestsAreRecomputed',
        'testRevocationUnavailableOrRevokedRejects','testArtifactDigestMismatchRejects'],
    'NativeMTPArtifactObservationTests': ['testUnquantizedObservationRejectsMissingFloat32AndGarbageDType',
        'testAffineFourRejectsUnpairedMismatchedAndPaddedHeaders','testTargetObservesEveryLoaderConsumedTensorName',
        'testSeparateArtifactTensorNamespacesRejectEmbeddedOrExtraWeights','testTargetAndDrafterLayerDriftFailsClosed',
        'testObserverAcceptsOnlyTheLoaderQuantizationGrammar'],
    'NativeMTPRevocationFeedTests': ['testRejectsSignerMismatchBadSignatureAndFutureButAcceptsAgedBodies',
        'testRejectsRollbackReplayAndRevokedSetRegression','testNetworkFirstFailsClosedWhenNoCurrentAuthenticatedStateExists'],
}
SECURITY_CASES = {
    'NativeMTPAdmissionSidecarTests': ['testArtifactPathsRejectAbsoluteTraversalNetworkBackslashAndMissing',
        'testArtifactSymlinkRejectsEvenInsideSnapshot','testSymlinkDirectoryComponentRejects','testHardlinkedArtifactRejects',
        'testCaptureRejectsPathSwapAfterValidation','testCaptureRejectsRenameReplacementAfterValidation'],
    'NativeMTPArtifactObservationTests': ['testConfigReadIsBoundedNoFollowAndRejectsDuplicateKeys',
        'testSafetensorsHeadersRejectDuplicatesAndBoundCumulativeBytes','testSafetensorsOffsetsAndFileSizeMustBeConsistent',
        'testSafetensorsShapeAndArithmeticBoundsFailClosed',
        'testCompressedContainerIsRejectedBeforeAnyTensorAllocation',
        'testExternalTensorReferenceCannotReplaceRequiredInlineOffsets'],
}
INPUT_KEYS = {'schema','entry_index','sidecar','lab_records','environment','qualification_bundle',
              'w3_policy','w3_runs','w3_analysis','accounting_ordinary','accounting_native','canary_observations','diagnostic_observations',
              'captured_at','custody_repo','custody_commit','custody_record'}


def require(ok, message):
    if not ok: raise ValueError(message)


def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()


def sha(data):return hashlib.sha256(data).hexdigest()


def read(path,limit=MAX_FILE):
    path=Path(path);s=path.lstat()
    require(stat.S_ISREG(s.st_mode) and s.st_nlink==1 and s.st_size<=limit,'input not bounded regular file')
    return path.read_bytes()


def strict(data):
    def pairs(items):
        value={}
        for key,item in items:
            require(key not in value,'duplicate JSON key');value[key]=item
        return value
    return json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))


def load(path):return strict(read(path))


def module(root,name):
    spec=importlib.util.spec_from_file_location('serving_assembly_'+name,Path(root)/'scripts'/(name+'.py'))
    value=importlib.util.module_from_spec(spec);sys.modules[spec.name]=value;spec.loader.exec_module(value)
    return value


def step(number,name,checks,details):
    require(checks and all(type(v) is bool and v for v in checks.values()),'failed canonical checks')
    return {'schema_version':STEP_SCHEMA,'step_id':f'step-{number}-{name}','status':'pass','checks':checks,'details':details}


def cases(mapping):return {cls+'.'+name for cls,names in mapping.items() for name in names}


def security_cases(q,*,core,repo,source,entry):
    frozen=load(q/'security-actions.json')
    security_source=frozen['source_commit']
    require(core.git(repo,'rev-parse',f'{source}^{{tree}}')==core.git(repo,'rev-parse',f'{security_source}^{{tree}}'),
            'negative tests are not the exact reviewed source tree')
    required=cases(CAPABILITY_CASES)|cases(SECURITY_CASES)
    recipe={'security_artifact_name':'swift-xunit-shard-{shard}-{sha}','security_required_cases':sorted(required)}
    security=load(q/'security-evidence.json')
    require(sha(read(q/'security-evidence.json'))==entry['security_negative_evidence_sha256'],'sidecar security aggregate differs')
    evidence_sha=core.validate_security_artifact(q,repo=repo,source={'source_commit':security_source},recipe=recipe,
                                               prior_evidence=security['prior_hardware_negative_evidence_sha256'])
    # Existing core verifier authenticates fresh CI metadata + all4 ZIP digests,
    # closed XML and zero failed/skipped required cases + actual frozen audit.
    return {'ci_run_id':frozen['run_id'],'source_commit':security_source,
            'security_evidence_sha256':evidence_sha,'verified_cases':[{'class':c.split('.',1)[0],'method':c.split('.',1)[1]} for c in sorted(required)],
            'artifacts':frozen['artifacts']}


def validate_environment(value,entry,lab):
    expected={'schema','source_commit','lab_binary_sha256','decode_path_digest','machine','toolchain'}
    require(set(value)==expected and value['schema']=='macprovider.native-mtp-lab-environment.v1','environment schema')
    require(isinstance(value['source_commit'],str) and re.fullmatch('[0-9a-f]{40}',value['source_commit']) is not None,'environment source commit')
    require(value['lab_binary_sha256']==lab['lab_binary_sha256'] and value['decode_path_digest']==lab['lab_decode_path_digest'],
            'environment does not describe actual LAB executable')
    machine=value['machine'];tools=value['toolchain']
    require(set(machine)=={'hardware_model','chip','ram_bytes','os_version','os_build'} and set(tools)=={'xcode_build_version','swift_version'},'machine/toolchain keys')
    require(machine['chip']=='Apple M3 Ultra' and machine['ram_bytes']==256*(1<<30)==entry['ram_bytes'], 'unqualified hardware tier')
    require(re.fullmatch(r'Mac[0-9]+,[0-9]+',machine['hardware_model']) is not None,'hardware model')
    for observation in [machine['os_version'],machine['os_build'],*tools.values()]:
        require(isinstance(observation,str) and 1<=len(observation)<=240 and re.fullmatch(r'[A-Za-z0-9 .,+()_\-]+',observation) is not None,'unsafe toolchain observation')
    foundation_version=f"Version {machine['os_version']} (Build {machine['os_build']})"
    require(lab['machine']['chip']==machine['chip'] and lab['machine']['ram_gb']==256
            and lab['machine']['os_version'] in (machine['os_version'],foundation_version), 'LAB machine mismatch')
    return {'machine':machine,'toolchain':tools,'lab_source_commit':value['source_commit']}


def benchmark(root,config,entry,core):
    q=Path(config['qualification_bundle'])/'qualification'
    result=core.validate_serving_qualification(Path(config['qualification_bundle']),repo=root,
        source_commit=entry['source_commit'],sidecar_path=Path(config['sidecar']),entry_index=config['entry_index'])
    require(isinstance(result,dict),'qualification verifier returned no proof')
    analyzer=module(root,'native_mtp_r015_analyze')
    policy=load(config['w3_policy']);runs=Path(config['w3_runs'])
    actual=analyzer.analyze(runs,Path(config['w3_policy']))
    require(actual.get('overall_status')=='PASS' and load(config['w3_analysis'])==actual,'original W3 matrix did not rederive PASS')
    require(policy.get('schema')=='macprovider.native-mtp-r015-policy.v1' and policy.get('ram_gb')==256
            and policy.get('qualified_slots')==entry['qualified_slots']==4
            and policy.get('max_native_active_rows')==entry['max_native_active_rows']==1
            and policy.get('proposal_depth')==entry['proposal_depth']==1
            and policy.get('maximum_prompt_tokens')==entry['max_prompt_tokens']==4096,
            'W3 matrix scope differs from advertised scope')
    for key,value in [('model_id',entry['model_key']),('target_sha256',entry['ordinary_baseline']['artifact_hash']),
                      ('mtp_sha256',entry['artifact_hash']),('tokenizer_sha256',entry['tokenizer_sha256'])]:
        require(policy.get(key)==value,'W3 identity differs: '+key)
    contract=module(root,'native_mtp_journey_evidence')
    equivalence=module(root,'native_mtp_source_equivalence')
    # Never relabel original policy.provider_commit. Only actual reviewed-source
    # equivalence can permit reuse; helper supplied by the shared contract.
    measured_digest=equivalence.source_decode_digest(root,policy['provider_commit'])
    source_proof=equivalence.verify_source_equivalence(root,policy['provider_commit'],entry['source_commit'],measured_digest,entry['decode_path_digest'],
        request_feature_profile=entry['request_feature_profile'])
    if policy.get('mlx_fork_revision')!=entry['runtime_revision']:
        require(policy['provider_commit']==equivalence.W3_SOURCE and policy.get('mlx_fork_revision')==equivalence.OLD_FORK
                and entry['runtime_revision']==equivalence.NEW_FORK and source_proof is not None,
                'W3 runtime fork differs without exact product-source proof')
    require(result.get('benchmark_policy_sha256')==sha(read(q/'replay-policy.json')),'representative qualification hash differs')
    return step('14','studio-and-tier-benchmark',{'benchmark_preregistered':True,'material_production_economics_gate':True,
        'all_advertised_hardware_tiers':True},{'advertised_scope':[{'hardware_class':entry['hardware_class'],'ram_bytes':entry['ram_bytes'],
        'qualified_slots':entry['qualified_slots']}],'w3_provider_commit':policy['provider_commit'],
        'w3_policy_sha256':sha(read(config['w3_policy'])),'w3_runs_sha256':sha(read(runs)),
        'w3_analysis_sha256':sha(read(config['w3_analysis'])),'qualification_sha256':result,
        'w3_source_equivalence_contract_sha256':source_proof,
        'lower_tier_qualification_claimed':False}),actual


def assert_candidate(observation,entry):
    candidate=observation.get('candidate',{})
    require(candidate.get('binary_sha256')==entry['reproducible_build_sha256']
            and candidate.get('cdhash')==entry['live_executable_cdhash'],'protocol observation binary/CDHash differs')


def prepare(root,config,output):
    require(set(config)==INPUT_KEYS and config['schema']==SCHEMA,'assembly inputs fields')
    require(type(config['entry_index']) is int,'entry index')
    require(not output.exists(),'immutable assembly output exists')
    contract=module(root,'native_mtp_journey_evidence');core=module(root,'native_mtp_binding_bundle')
    lab_adapter=module(root,'native_mtp_journey_lab_steps');collector=module(root,'native_mtp_serving_collect')
    sidecar=read(config['sidecar']);entry,tuple_sha=contract.validated_sidecar_entry(sidecar,config['entry_index'])
    require(entry['model_key']=='zai-org/glm-5.3-flash' and entry['quantization']['kind']!='mlx_mxfp8','unsupported assembly model/format')
    files={'native-mtp-admission.json':sidecar};steps={};labs=[]
    for path in config['lab_records']:
        data=read(path);document=strict(data);labs.append(document)
        for key,value in lab_adapter.adapt_record(document,sha(data),entry,tuple_sha,sha(sidecar)).items():
            require(key not in steps,'duplicate LAB step');steps[key]=value
    require(set(steps)==set(lab_adapter.CANON.values()),'all actual LAB04–10 cells required')
    environment=load(config['environment']);machine=validate_environment(environment,entry,labs[0])
    require(all(lab['machine']==labs[0]['machine'] and lab['lab_binary_sha256']==environment['lab_binary_sha256'] for lab in labs),'mixed LAB machines/binaries')
    equivalence=module(root,'native_mtp_source_equivalence')
    lab_source_proof=equivalence.verify_source_equivalence(root,environment['source_commit'],entry['source_commit'],
        environment['decode_path_digest'],entry['decode_path_digest'],request_feature_profile=entry['request_feature_profile'])
    first=step('01','bind-tuple',{'native_mtp_evidence_only':True,'no_unreleased_local_binary_on_live_coordinator':True},
        {'entry_index':config['entry_index'],'evidence_class':'lab_isolated_no_join','lab_binary_release_candidate':False,
         'signed_policy_tuple_sha256':tuple_sha,'lab_source_equivalence_contract_sha256':lab_source_proof,'lab_binary_sha256':environment['lab_binary_sha256'],**machine,
         'bound_entry':entry,'lab_raw_sha256':[sha(read(p)) for p in config['lab_records']]})
    steps[first['step_id']]=first
    q=Path(config['qualification_bundle'])/'qualification'
    negatives=security_cases(q,core=core,repo=root,source=entry['source_commit'],entry=entry)
    # Actual ordinary controls in every accepted step04 record, not merely a
    # parser test's successful exit, establish otherwise available decode.
    ordinary=steps['step-04-serial-token-oracle']['checks'].get('exact_greedy_token_parity') is True
    second=step('02','capability-negatives',{'artifact_manifest_fail_closed':True,'emergency_tuple_revocation':True,
        'ordinary_decode_remained_available':ordinary},{**negatives,'ordinary_control_raw_sha256':steps['step-04-serial-token-oracle']['details']['raw_result_sha256']})
    third=step('03','artifact-security-negatives',{'path_traversal_rejected':True,'external_reference_rejected':True,
        'allocation_and_decompression_bounds':True},{**negatives,'compressed_format':'rejected_before_tensor_allocation',
        'external_tensor_data':'inline_offsets_required'})
    steps[second['step_id']]=second;steps[third['step_id']]=third
    ordinary_sample=load(config['accounting_ordinary']);native_sample=load(config['accounting_native'])
    samples=[load(p) for p in config['canary_observations']]
    diagnostics=load(config['diagnostic_observations'])
    for sample in [ordinary_sample,native_sample,*samples,diagnostics]:assert_candidate(sample,entry)
    for value in (collector.compare_accounting(ordinary_sample,native_sample),collector.compare_canary(samples,diagnostics)):
        require(value.get('status')=='pass' and all(value['checks'].values()),'actual protocol comparison pending/failed')
        steps[value['step_id']]=value
    fourteenth,analysis=benchmark(root,config,entry,core);steps[fourteenth['step_id']]=fourteenth
    numeric=module(root,'native_mtp_r005_redacted')
    expected={key:sha(read(config[key],64*(1<<20))) for key in ('w3_policy','w3_runs','w3_analysis','environment')}
    for index,path in enumerate(config['lab_records']):expected[f'lab_record_{index}']=sha(read(path))
    for key in ('accounting_ordinary','accounting_native','diagnostic_observations'):expected[key]=sha(read(config[key]))
    for index,path in enumerate(config['canary_observations']):expected[f'canary_observation_{index}']=sha(read(path))
    for name in ('acceptance.json','acceptance-policy.json','acceptance-corpus.json'):
        expected[name]=sha(read(q/name,64*(1<<20)))
    custody=numeric.verify_private_custody(Path(config['custody_repo']),config['custody_commit'],config['custody_record'],expected)
    projection=numeric.project_acceptance(*(strict(read(q/name,64*(1<<20))) for name in ('acceptance.json','acceptance-policy.json','acceptance-corpus.json')),entry,
        raw_result_sha256=expected['acceptance.json'],policy_sha256=expected['acceptance-policy.json'],
        corpus_sha256=expected['acceptance-corpus.json'],custody=custody)
    files['observations/r005-numeric-projection.json']=canonical(projection)
    steps['step-04-serial-token-oracle']['details'].update({
        'sampled_acceptance_result_sha256':projection['raw_result_sha256'],
        'r005_result_sha256':projection['raw_result_sha256'],'r005_policy_sha256':projection['policy_sha256'],
        'r005_corpus_sha256':projection['corpus_sha256'],'r005_numeric_projection_sha256':sha(canonical(projection))})
    # Original policies and frozen qualification source proofs stay truthful.
    files['r015-policy.json']=read(q/'replay-policy.json')
    for name in ('qualification-reuse.json','qualification-origin-native-mtp-admission.json'):
        candidate=q/name
        if candidate.exists():files[name]=read(candidate)
    files['observations/w3-analysis.json']=read(config['w3_analysis'])
    files['observations/w3-policy.json']=read(config['w3_policy'])
    files['observations/w3-runs.jsonl']=read(config['w3_runs'])
    for name in ('capture.json','tuple-bounds.json','projection-plan.json','privacy-review.json','preregistration.json',
                 'bench-policy.json','bench.jsonl','bench-analysis.json','replay.json','replay-policy.json','analysis.json','source.json'):
        files['observations/representative/'+name]=read(q/name)
    files['observations/negative-cases.json']=canonical(negatives)
    for key,value in steps.items():files['steps/'+key+'.json']=canonical(value)
    privacy=module(root,'privacy_class_beta_journey_evidence')
    privacy.assert_bundle_redacted(privacy.Bundle('serving',files,b''))
    require(len(files)<=contract.MAX_BUNDLE_FILES and all(len(data)<=MAX_FILE for data in files.values()),'assembly bounds')
    inventory={name:sha(data) for name,data in sorted(files.items())}
    receipt={'schema':'macprovider.native-mtp-serving-review-inventory.v1','files':inventory,
             'inventory_sha256':sha(canonical(inventory)),'captured_at':config['captured_at'],
             'review_categories':CATEGORIES,'journey_complete':False}
    output.mkdir(parents=True)
    for name,data in files.items():
        path=output/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    (output/'REVIEW-INVENTORY.json').write_bytes(canonical(receipt))
    return receipt


def finalize(root,prepared,review_path,review_record,stage):
    require(not stage.exists(),'immutable final stage exists')
    contract=module(root,'native_mtp_journey_evidence');privacy=module(root,'privacy_class_beta_journey_evidence')
    inventory=load(prepared/'REVIEW-INVENTORY.json');review=load(review_path)
    fields={'schema','inventory_sha256','reviewed_at','reviewer_fingerprint','review_record_sha256','reviewed_categories','findings'}
    require(set(review)==fields and review['schema']=='macprovider.native-mtp-serving-privacy-review.v1','durable review schema')
    require(review['inventory_sha256']==inventory['inventory_sha256'] and review['reviewed_categories']==CATEGORIES
            and review['findings']==[],'review incomplete or unresolved findings')
    require(re.fullmatch('[0-9a-f]{64}',review['reviewer_fingerprint']) is not None and review['review_record_sha256']==sha(read(review_record))
            and len(read(review_record))>=80,'actual durable review record missing')
    contract.parse_timestamp(review['reviewed_at'],'reviewed_at')
    require(contract.parse_timestamp(review['reviewed_at'],'reviewed_at')>=contract.parse_timestamp(inventory['captured_at'],'captured_at'),'review predates evidence')
    files={}
    for path in prepared.rglob('*'):
        require(not path.is_symlink(),'prepared symlink')
        if path.is_file() and path.name!='REVIEW-INVENTORY.json':files[path.relative_to(prepared).as_posix()]=read(path)
    actual={name:sha(data) for name,data in sorted(files.items())}
    require(actual==inventory['files'] and sha(canonical(actual))==inventory['inventory_sha256'],'reviewed byte inventory changed')
    fifteenth=step('15','redaction-review',{'no_secret_or_model_private_material':True},review)
    files['steps/'+fifteenth['step_id']+'.json']=canonical(fifteenth)
    files['privacy-review.json']=canonical(review)
    privacy.assert_bundle_redacted(privacy.Bundle('serving',files,b''))
    stamp=contract.parse_timestamp(inventory['captured_at'],'captured_at').strftime('%Y%m%dT%H%M%SZ')
    relative='journeys/evidence/native-mtp-serving-'+stamp
    bundle=contract.Bundle(relative,files,contract.manifest_bytes(files))
    evidence=contract.compose_serving(bundle,captured_at=inventory['captured_at'])
    target=stage/relative;target.mkdir(parents=True)
    for name,data in files.items():
        path=target/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    (target/'MANIFEST.sha256').write_bytes(bundle.manifest)
    evidence_path=stage/(relative+'.redacted.json');evidence_path.write_bytes(canonical(evidence))
    contract.validate_evidence(stage,contract.SERVING,relative+'.redacted.json',evidence)
    return {'redacted_evidence_path':str(evidence_path),'sha256':sha(evidence_path.read_bytes()),'journey_complete':True}


def binary_sha(path):
    path=Path(path);st=path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink==1 and st.st_size<=2*(1<<30),'unsafe LAB executable')
    h=hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda:handle.read(1<<20),b''):h.update(chunk)
    return h.hexdigest()


def collect_environment(repo,binary):
    def command(*args):return subprocess.check_output(args,text=True).strip()
    require(sys.platform=='darwin','Studio environment collection requires Darwin')
    chip=command('sysctl','-n','machdep.cpu.brand_string');ram=int(command('sysctl','-n','hw.memsize'))
    require(chip=='Apple M3 Ultra' and ram==256*(1<<30),'environment collector requires designated Studio tier')
    digest=command(sys.executable,str(repo/'scripts/decode_path_digest.py'),'--binary',str(binary))
    require(re.fullmatch('[0-9a-f]{64}',digest) is not None,'actual embedded LAB decode identity unavailable')
    xcode=command('xcodebuild','-version').splitlines();swift=command('swift','--version').splitlines()[0]
    return {'schema':'macprovider.native-mtp-lab-environment.v1','source_commit':command('git','-C',str(repo),'rev-parse','HEAD'),
        'lab_binary_sha256':binary_sha(binary),'decode_path_digest':digest,'machine':{
            'hardware_model':command('sysctl','-n','hw.model'),'chip':chip,'ram_bytes':ram,
            'os_version':command('sw_vers','-productVersion'),'os_build':command('sw_vers','-buildVersion')},
        'toolchain':{'xcode_build_version':' '.join(xcode),'swift_version':swift}}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT)
    sub=p.add_subparsers(dest='command',required=True)
    c=sub.add_parser('collect-environment');c.add_argument('--binary',type=Path,required=True);c.add_argument('--output',type=Path,required=True)
    c=sub.add_parser('prepare');c.add_argument('--inputs',type=Path,required=True);c.add_argument('--output',type=Path,required=True)
    c=sub.add_parser('finalize');c.add_argument('--prepared',type=Path,required=True);c.add_argument('--review',type=Path,required=True);c.add_argument('--review-record',type=Path,required=True);c.add_argument('--stage',type=Path,required=True)
    args=p.parse_args();root=args.root.resolve()
    if args.command=='prepare':result=prepare(root,load(args.inputs),args.output)
    elif args.command=='finalize':result=finalize(root,args.prepared,args.review,args.review_record,args.stage)
    else:
        require(not args.output.exists(),'environment output exists');result=collect_environment(root,args.binary)
        args.output.write_bytes(canonical(result))
    print(json.dumps(result,sort_keys=True))


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError,subprocess.CalledProcessError) as error:
        raise SystemExit('serving assembly refused: '+str(error))
