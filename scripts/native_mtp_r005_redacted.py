#!/usr/bin/env python3
"""Closed public numeric R005 projection, with explicit private-data custody.

Projection is a deterministic report of a producer's full private validation.
Public validation checks numeric gates/coverage/identity and commitments; it does
not reopen private token sequences or attest independently to hardware execution.
"""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

SCHEMA='macprovider.native-mtp-r005-numeric-projection.v1'
IDENTITY={'model_id','target_sha256','mtp_sha256','tokenizer_sha256','proposal_depth','qualified_slots','max_native_active_rows','max_prompt_tokens'}
FIELDS={'schema','identity','measured_source_commit','raw_result_sha256','policy_sha256','corpus_sha256','custody','cases',
        'native_compared_positions','coverage','private_data_reopened_by_public_validator','independent_hardware_attestation'}
CASE_FIELDS={'id','stratum','expected_native','ordinary_terminal','native_terminal','completion_tokens','selected_count',
             'positions','selected_positions','visible_sequences','selected_sequences'}
POSITION_FIELDS={'position','max_abs_difference','ordinary_gap','native_gap'}
SEQUENCE_FIELDS={'ordinary_sha256','native_sha256','ordinary_top1_sha256','native_top1_sha256'}


def require(ok,message):
    if not ok:raise ValueError(message)


def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def sha(data):return hashlib.sha256(data).hexdigest()
def hexvalue(value,size=64):return isinstance(value,str) and re.fullmatch('[0-9a-f]{'+str(size)+'}',value) is not None


def verify_private_custody(repo:Path,commit:str,record:str,expected:dict[str,str])->dict:
    require(hexvalue(commit,40),'custody commit')
    def blob(path):
        require(isinstance(path,str) and re.fullmatch('[A-Za-z0-9._/-]+',path) is not None
                and all(p not in ('','.','..') for p in path.split('/')),'custody path')
        tree=subprocess.check_output(['git','ls-tree','-z',commit,'--',path],cwd=repo)
        require(tree.startswith(b'100644 blob ') or tree.startswith(b'100755 blob '),'custody blob is not regular tracked data')
        data=subprocess.check_output(['git','show',f'{commit}:{path}'],cwd=repo)
        require(len(data)<=64*(1<<20),'custody blob size')
        return data
    raw=blob(record)
    def unique(items):
        value={}
        for key,item in items:
            require(key not in value,'duplicate custody key');value[key]=item
        return value
    document=json.loads(raw,object_pairs_hook=unique)
    require(isinstance(document,dict) and set(document)=={'schema','artifacts'}
            and document['schema']=='macprovider.native-mtp-serving-private-custody.v1','custody record schema')
    require(isinstance(document['artifacts'],dict) and set(expected)<=document['artifacts'].keys(),'missing private window log records')
    for name,digest in expected.items():
        item=document['artifacts'][name]
        require(isinstance(item,dict) and set(item)=={'path','sha256'} and item['sha256']==digest
                and sha(blob(item['path']))==digest,'actual committed private window log differs: '+name)
    return {'commit':commit,'record_sha256':sha(raw)}


def sequences(positions):
    return {key:sha(canonical([p[field] for p in positions])) for key,field in (
        ('ordinary_sha256','ordinary_token'),('native_sha256','native_token'),
        ('ordinary_top1_sha256','ordinary_top1'),('native_top1_sha256','native_top1'))}


def project_acceptance(result,policy,corpus,entry,*,raw_result_sha256,policy_sha256,corpus_sha256,custody):
    # No pass flag or redacted substitute can enter this producer gate.
    from native_mtp_binding_bundle import validate_acceptance
    validate_acceptance(result,policy,corpus,entry,policy_sha=policy_sha256,corpus_sha=corpus_sha256)
    output=[]
    for case in result['cases']:
        selected=case['selected_positions'];positions=case['positions']
        for row in [*positions,*selected]:
            require(row['ordinary_token']==row['native_token'] and row['ordinary_top1']==row['native_top1'],'actual private token mismatch')
        def numeric(rows):return [{key:row[key] for key in sorted(POSITION_FIELDS)} for row in rows]
        output.append({'id':case['id'],'stratum':case['stratum'],'expected_native':case['expected_native'],
            'ordinary_terminal':case['ordinary_terminal'],'native_terminal':case['native_terminal'],
            'completion_tokens':len(positions),'selected_count':len(selected),'positions':numeric(positions),
            'selected_positions':numeric(selected),'visible_sequences':sequences(positions),'selected_sequences':sequences(selected)})
    value={'schema':SCHEMA,'identity':{key:policy[key] if key in policy else entry[key] for key in sorted(IDENTITY)},
        'measured_source_commit':policy['provider_commit'],'raw_result_sha256':raw_result_sha256,
        'policy_sha256':policy_sha256,'corpus_sha256':corpus_sha256,'custody':custody,'cases':output,
        'native_compared_positions':result['native_compared_positions'],
        'coverage':{'accepted':result['accepted'],'rejected':result['rejected'],
            'near_tied_positions':result['near_tied_positions'],
            'generated_reasoning_close_observed':result['checks']['generated_reasoning_close'],
            'generated_tool_boundary_observed':result['checks']['generated_tool_boundary']},
        'private_data_reopened_by_public_validator':False,'independent_hardware_attestation':False}
    validate_projection(value,entry)
    return value


def validate_projection(value,entry):
    require(isinstance(value,dict) and set(value)==FIELDS and value['schema']==SCHEMA,'R005 projection fields')
    require(value['private_data_reopened_by_public_validator'] is False and value['independent_hardware_attestation'] is False,'R005 custody limit')
    for key in ('raw_result_sha256','policy_sha256','corpus_sha256'):require(hexvalue(value[key]),'R005 raw digest')
    require(hexvalue(value['measured_source_commit'],40),'R005 original source')
    require(value['raw_result_sha256']==entry['correctness_evidence_sha256'],'R005 original result differs from admission')
    custody=value['custody']
    require(isinstance(custody,dict) and set(custody)=={'commit','record_sha256'}
            and hexvalue(custody['commit'],40) and hexvalue(custody['record_sha256']),'R005 opaque custody identity')
    identity=value['identity']
    require(isinstance(identity,dict) and set(identity)==IDENTITY,'R005 identity fields')
    expected={'model_id':entry['model_key'],'target_sha256':entry['ordinary_baseline']['artifact_hash'],
              'mtp_sha256':entry['artifact_hash'],'tokenizer_sha256':entry['tokenizer_sha256'],
              **{key:entry[key] for key in ('proposal_depth','qualified_slots','max_native_active_rows','max_prompt_tokens')}}
    require(identity==expected and all(type(identity[k]) is int for k in ('proposal_depth','qualified_slots','max_native_active_rows','max_prompt_tokens')),'R005 tuple identity differs')
    records=value['cases'];require(isinstance(records,list) and 200<=len(records)<=400,'R005 complete case count')
    seen=set();visible=0;strata=set();terminals=set();native=0;near_tied=0
    for case in records:
        require(isinstance(case,dict) and set(case)==CASE_FIELDS,'R005 case fields')
        name=case['id'];require(isinstance(name,str) and re.fullmatch('[A-Za-z0-9_.-]{1,128}',name) is not None and name not in seen,'R005 case ID')
        seen.add(name)
        require(isinstance(case['stratum'],str) and case['stratum'] in {'short','1.5k','4k','8k','near_boundary'} and type(case['expected_native']) is bool,'R005 stratum/admission')
        strata.add(case['stratum'])
        require(isinstance(case['native_terminal'],str) and case['ordinary_terminal']==case['native_terminal'] and case['native_terminal'] in {'eos','stopSequence','maxTokens','toolBoundary','other'},'R005 terminal parity')
        terminals.add(case['native_terminal'])
        for key in ('completion_tokens','selected_count'):require(type(case[key]) is int and 0<=case[key]<=256,'R005 count')
        require(case['selected_count']>0 and case['completion_tokens']<=case['selected_count'],'R005 visible/selected counts')
        for key,count in (('positions',case['completion_tokens']),('selected_positions',case['selected_count'])):
            rows=case[key];require(isinstance(rows,list) and len(rows)==count,'R005 numeric count mismatch')
            for index,row in enumerate(rows):
                require(isinstance(row,dict) and set(row)==POSITION_FIELDS and type(row['position']) is int and row['position']==index,'R005 numeric position order')
                for field in POSITION_FIELDS-{'position'}:
                    x=row[field];require(type(x) in (int,float) and math.isfinite(x) and x>=0,'R005 numeric finite bound')
                require(row['max_abs_difference']<=0.05,'R005 numeric error gate')
        require(case['selected_positions'][:case['completion_tokens']]==case['positions'],'R005 numeric visible prefix')
        for key in ('visible_sequences','selected_sequences'):
            commitments=case[key]
            require(isinstance(commitments,dict) and set(commitments)==SEQUENCE_FIELDS and all(hexvalue(x) for x in commitments.values()),'R005 sequence commitments')
            require(commitments['ordinary_sha256']==commitments['native_sha256'] and commitments['ordinary_top1_sha256']==commitments['native_top1_sha256'],'R005 sequence parity commitment')
        if case['expected_native']:
            visible+=case['completion_tokens'];native+=1
            near_tied+=sum(row['ordinary_gap']<=0.05 for row in case['positions'])
    require(strata=={'short','1.5k','4k','8k','near_boundary'},'R005 strata coverage')
    require({'eos','stopSequence','maxTokens','toolBoundary'}<=terminals,'R005 terminal coverage')
    coverage=value['coverage']
    require(isinstance(coverage,dict) and set(coverage)=={'accepted','rejected','near_tied_positions','generated_reasoning_close_observed','generated_tool_boundary_observed'},'R005 coverage fields')
    require(all(type(coverage[k]) is int and coverage[k]>0 for k in ('accepted','rejected','near_tied_positions'))
            and coverage['near_tied_positions']==near_tied,'R005 realized acceptance/near-tie coverage')
    require(identity['proposal_depth']==1 and coverage['generated_reasoning_close_observed'] is True
            and coverage['generated_tool_boundary_observed'] is True,'R005 depth/control coverage')
    require(native>0 and visible>=6400 and type(value['native_compared_positions']) is int and value['native_compared_positions']==visible,'R005 compared position floor')
    return {key:value[key] for key in ('raw_result_sha256','policy_sha256','corpus_sha256','measured_source_commit','custody')} | {'projection_sha256':sha(canonical(value))}
