#!/usr/bin/env python3
"""Actual step-11/12 observations from an owned isolated signed-provider window.

The ops controller owns host identity, pause/watchdog, signed candidate launch,
mode changes, and restoration. This collector never restarts a process or joins
live serving. Unsupported observations remain pending; it cannot complete the
other thirteen journey steps or promote a partial journey to complete.
"""
from __future__ import annotations
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
from urllib.parse import urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler
from urllib.error import HTTPError
import uuid

SCHEMA = "macprovider.native-mtp-serving-observation.v1"
STEP_SCHEMA = "macprovider.native-mtp-journey-step.v1"
EXPECTED = {"good": "passed", "wrong_digest": "expected_value_mismatch", "actual_path": "unsupported_path_fallback", "fallback": "unsupported_path_fallback", "drop": "timeout", "expiry": "expired_result"}
MONEY_PATTERNS = ("request", "usage", "receipt", "settlement", "billing", "payout", "ledger", "credit", "quota", "reward")
TABLES = ("ledger_request_credits", "settlement_route_snapshots", "settlement_attempt_outputs", "settlement_receipt_verdicts")
FIELDS = {
    "ledger_request_credits": ("model", "prompt_tokens", "charged_prompt_tokens", "provider_reported_prompt_tokens", "cached_prompt_tokens", "completion_tokens", "estimated_completion_tokens", "usage_source", "prompt_rate_per_mtok", "completion_rate_per_mtok", "global_multiplier_ppm", "gross_credits", "provider_share_bps", "provider_credits", "fault_flag", "attestation_class", "settled", "quarantined", "quarantine_reason", "settlement_policy_mode", "settlement_policy_version", "requested_privacy_mode", "effective_privacy_outcome", "positive_verification_excluded", "rewards_excluded"),
    "settlement_route_snapshots": ("paid_entrypoint", "provider_receipt_key_id", "provider_receipt_key_source", "model_id", "provider_reported_model_hash", "expected_catalog_model_hash", "catalog_id", "catalog_body_digest", "catalog_signature_key_id", "spec008_hash_status", "route_snapshot_policy_version", "route_snapshot_mode", "prompt_hash_basis", "prompt_hash", "compute_integrity_capture_required", "compute_integrity_sampling_profile_covered"),
    "settlement_attempt_outputs": ("terminal_state", "output_available", "output_prefix_start_byte", "output_prefix_end_byte", "output_hash", "usage_hash", "usage_canonical_json", "usage_source", "overlapping_or_duplicate"),
    "settlement_receipt_verdicts": ("receipt_present", "receipt_version", "receipt_result", "settlement_outcome", "reason", "closed", "terminal_state", "route_snapshot_policy_version", "route_snapshot_mode", "paid_entrypoint", "spec008_hash_status", "provider_reported_model_hash", "provider_receipt_key_fingerprint", "catalog_id", "catalog_body_digest", "expected_catalog_model_hash", "model_id", "model_hash", "receipt_profile", "buyer_debit_outcome", "provider_settlement_outcome", "payout_exclusion_outcome", "prompt_hash", "output_hash", "usage_digest"),
}

class CollectionError(ValueError): pass

def require(ok, message):
    if not ok: raise CollectionError(message)

def _pairs(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "duplicate JSON field")
        value[key] = item
    return value

def read(path):
    p = Path(path); require(p.is_file() and not p.is_symlink(), "regular input file required")
    return json.loads(p.read_bytes(), object_pairs_hook=_pairs)

def canonical(value): return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()

def sha(path):
    p=Path(path); require(p.is_file() and not p.is_symlink(), "regular proof input required")
    h=hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""): h.update(block)
    return h.hexdigest()

def write(path, value):
    p=Path(path);require(not p.exists() and not p.is_symlink(), "observation output already exists")
    p.parent.mkdir(parents=True,exist_ok=True)
    with p.open("xb") as f:
        os.fchmod(f.fileno(),0o600);f.write(canonical(value));f.flush();os.fsync(f.fileno())

def token(path):
    p=Path(path);require(p.is_file() and not p.is_symlink() and p.stat().st_mode & 0o077 == 0,"token file permissions")
    result=p.read_text().strip();require(bool(result) and not any(c in result for c in '\r\n"'),"token format")
    return result

def endpoint(url):
    u=urlparse(url)
    require(u.scheme=="http" and u.hostname in {"127.0.0.1","localhost","::1"} and u.port is not None and 19300<=u.port<=19399 and not u.username and not u.password and not u.query and not u.fragment,"collector requires the isolated loopback 193xx stack")
    return url.rstrip("/")

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): raise CollectionError("HTTP redirect forbidden")

def http(url, *, bearer=None, body=None, request_id=None):
    headers={"Content-Type":"application/json"}
    if bearer is not None:headers["Authorization"]="Bearer "+bearer
    if request_id:headers["X-Request-ID"]=request_id
    request=Request(url,data=canonical(body) if body is not None else None,headers=headers,method="POST" if body is not None else "GET")
    opener=build_opener(ProxyHandler({}),NoRedirect())
    try:
        with opener.open(request,timeout=120) as response:
            raw=response.read(4*1024*1024+1);require(len(raw)<=4*1024*1024,"HTTP observation exceeds bound")
            return {"status":response.status,"headers":dict(response.headers.items()),"body":json.loads(raw,object_pairs_hook=_pairs)}
    except HTTPError as error:
        return {"status":error.code,"headers":{},"body":{}}

def connection(path):
    p=Path(path).resolve();require(p.is_file() and not Path(path).is_symlink(),"existing isolated SQLite database required")
    db=sqlite3.connect(p.as_uri()+"?mode=ro",uri=True);db.row_factory=sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    return db

def _tables(db):return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
def _quote(name):return '"'+name.replace('"','""')+'"'

def money_snapshot(config):
    result={}
    for name in ("coordinator","gateway"):
        tables={}
        with connection(config[name+"_db"]) as db:
            for table in sorted(_tables(db)):
                if table not in {"accounts","api_keys"} and not any(p in table.lower() for p in MONEY_PATTERNS):continue
                columns=[r[1] for r in db.execute("PRAGMA table_info("+_quote(table)+")")]
                q=", ".join(_quote(c) for c in columns);h=hashlib.sha256();count=0
                for row in db.execute("SELECT "+q+" FROM "+_quote(table)+" ORDER BY "+q):
                    h.update(canonical([bytes(x).hex() if isinstance(x,bytes) else x for x in row]));count+=1
                tables[table]={"count":count,"sha256":h.hexdigest()}
        require(bool(tables),"money snapshot has no actual tables")
        result[name]=tables
    return result

def request_rows(config,request_id):
    result={}
    with connection(config["coordinator_db"]) as db:
        rows=[dict(r) for r in db.execute("SELECT * FROM request_log WHERE external_request_id=? ORDER BY id",(request_id,))]
        result["request_log"]=rows
        internal={r["request_id"] for r in rows}
        for table in TABLES:
            require(table in _tables(db),"required accounting table unavailable: "+table)
            selected=[]
            for rid in sorted(internal): selected += [dict(r) for r in db.execute("SELECT * FROM "+_quote(table)+" WHERE request_id=? ORDER BY id",(rid,))]
            result[table]=selected
    with connection(config["gateway_db"]) as db:
        result["usage_events"]=[dict(r) for r in db.execute("SELECT * FROM usage_events WHERE request_id=?",(request_id,))]
    return result

def code_identity(config):
    p=Path(config["binary_path"])
    require(sha(p)==config["binary_sha256"],"candidate binary bytes changed")
    verified=subprocess.run(["codesign","--verify","--strict",str(p)],capture_output=True,check=False)
    require(verified.returncode==0,"candidate code signature invalid")
    shown=subprocess.run(["codesign","-dv","--verbose=4",str(p)],capture_output=True,text=True,check=False)
    identity={}
    for line in (shown.stdout+shown.stderr).splitlines():
        if "=" in line:
            key,value=line.split("=",1);identity[key]=value
    require(shown.returncode==0 and identity.get("TeamIdentifier")==config["team_id"] and identity.get("Identifier")==config["signing_identifier"] and identity.get("CDHash")==config["cdhash"] and config["team_id"] not in {"","not set"},"candidate signed code identity mismatch")
    return {key:config[key] for key in ("binary_sha256","team_id","signing_identifier","cdhash","compatibility_set_id")}

def _status(config):return http(endpoint(config["provider_url"])+"/v1/status",bearer=token(config["provider_token_file"]))

def require_status(config,response):
    require(response["status"]==200,"provider status unavailable")
    value=response["body"]
    require(value.get("compatibility_set_id")==config["compatibility_set_id"] and value.get("safety_telemetry",{}).get("provider_id")==config["provider_id"],"provider candidate/session identity mismatch")
    require(value.get("continuous_batching",{}).get("active") is True,"ordinary CB must remain active")
    return value

def _log(path,offset):
    p=Path(path)
    if not p.exists():return ""
    require(not p.is_symlink() and p.stat().st_size>=offset,"provider log replaced/truncated")
    with p.open("rb") as f:f.seek(offset);raw=f.read(8*1024*1024+1)
    require(len(raw)<=8*1024*1024,"bounded log observation exceeded")
    return raw.decode(errors="replace")

def capture_accounting(config,phase):
    require(phase in {"ordinary","native"},"accounting phase")
    candidate=code_identity(config);before=require_status(config,_status(config))
    require(before["native_mtp"]["enabled"] is (phase=="native"),"provider mode differs from controlled phase")
    request=config["request"]
    require(request.get("stream",False) is False and request.get("temperature")==0 and request.get("top_p",1)==1 and type(request.get("max_tokens")) is int and 1<=request["max_tokens"]<=256,"accounting pair requires identical bounded greedy production requests")
    rid=str(uuid.uuid4());log=Path(config["provider_log"]);offset=log.stat().st_size
    response=http(endpoint(config["gateway_url"])+"/v1/chat/completions",bearer=token(config["buyer_token_file"]),body=request,request_id=rid)
    actual_rid=next((v for k,v in response["headers"].items() if k.lower()=="x-request-id"),None)
    require(response["status"]==200 and actual_rid==rid,"gateway response attribution failed")
    rows={};end=time.monotonic()+min(int(config.get("settlement_wait_seconds",30)),120)
    while True:
        rows=request_rows(config,rid)
        verdict=rows.get("settlement_receipt_verdicts",[])
        if verdict and all(x.get("closed")==1 for x in verdict):break
        if time.monotonic()>=end:break
        time.sleep(1)
    after=require_status(config,_status(config));traces=_log(log,offset)
    return {"schema_version":SCHEMA,"kind":"accounting","phase":phase,"candidate":candidate,"request":request,"request_id":rid,"gateway":response,"provider_before":before,"provider_after":after,"rows":rows,"provider_trace":traces}

def forbidden_fields(value):
    if isinstance(value,dict):return any("native_mtp" in str(k).lower() or "nativemtp" in str(k).lower() or forbidden_fields(v) for k,v in value.items())
    if isinstance(value,list):return any(forbidden_fields(x) for x in value)
    if isinstance(value,str) and value.lstrip().startswith(("{","[")):
        try:return forbidden_fields(json.loads(value,object_pairs_hook=_pairs))
        except (ValueError,TypeError):return True
    return False

def accounting_projection(sample):
    rows=sample["rows"];require(len(rows["request_log"])==len(rows["usage_events"])==1,"request/usage must be singular")
    request=rows["request_log"][0];usage=rows["usage_events"][0]
    require(request.get("external_request_id")==sample["request_id"] and usage.get("request_id")==sample["request_id"],"accounting request ID mismatch")
    session=sample["provider_before"].get("safety_telemetry",{}).get("coordinator_session_id")
    require(bool(session) and request.get("provider_assigned_id")==session,"request was served by another provider")
    require(request.get("status")==200 and request.get("retried")==0,"accounting pair must be one successful attempt")
    internal=request["request_id"];trace=sample["provider_trace"]
    completed=re.search(r"rid="+re.escape(internal)+r" ev=sch_complete\b",trace) is not None
    native=any(internal in line.split("rows=",1)[1].split(",") for line in trace.splitlines() if "ev=native_round phase=propose rows=" in line)
    require(completed and native is (sample["phase"]=="native"),"request-specific actual scheduler path not observed")
    for key in ("prompt_tokens","completion_tokens","total_tokens"):
        require(type(usage.get(key)) is int and usage[key]>=0 and request.get(key)==usage[key] and sample["gateway"]["body"].get("usage",{}).get(key)==usage[key],"usage/receipt token mismatch")
    result={"usage":{k:usage[k] for k in ("prompt_tokens","completion_tokens","total_tokens","token_source","outcome")}}
    for table,fields in FIELDS.items():
        selected=rows[table];require(len(selected)==1,"exact one actual accounting row required: "+table)
        row=selected[0];require(row.get("request_id")==internal,"unrelated accounting row")
        require(all(k in row for k in fields),"accounting schema missing required fields: "+table)
        result[table]={k:row[k] for k in fields}
    ledger=result["ledger_request_credits"];verdict=result["settlement_receipt_verdicts"]
    require(ledger["settled"]==1 and ledger["quarantined"]==0 and ledger["gross_credits"]>=0 and ledger["provider_credits"]>=0,"ledger not settled normally")
    require(verdict["receipt_present"]==1 and verdict["receipt_result"]=="valid" and verdict["settlement_outcome"]=="verified" and verdict["closed"]==1,"actual coordinator receipt verification/settlement missing")
    require(not forbidden_fields(rows),"native-MTP field entered receipt/billing schema")
    choice=sample["gateway"]["body"]["choices"][0]
    result["response"]={"message":choice["message"],"finish_reason":choice["finish_reason"]}
    return result

def compare_accounting(ordinary,native):
    reasons=[];checks={"receipt_and_accounting_invariance":False,"no_native_mtp_field_in_receipt_or_billing":False}
    try:
        require(ordinary["schema_version"]==native["schema_version"]==SCHEMA and ordinary["kind"]==native["kind"]=="accounting" and ordinary["phase"]=="ordinary" and native["phase"]=="native","ordinary/native actual observation pair required")
        require(ordinary["candidate"]==native["candidate"] and ordinary["request"]==native["request"],"same signed candidate and production request required")
        left,right=accounting_projection(ordinary),accounting_projection(native)
        require(left==right,"receipt/billing/reward/routing/settlement basis changed")
        checks={key:True for key in checks}
    except (ValueError,KeyError,TypeError) as error:reasons.append(str(error))
    return {"schema_version":STEP_SCHEMA,"step_id":"step-11-accounting","status":"pass" if all(checks.values()) else "pending","checks":checks,"details":{"pending_reasons":reasons,"observation_sha256":{"ordinary":hashlib.sha256(canonical(ordinary)).hexdigest(),"native":hashlib.sha256(canonical(native)).hexdigest()},"scope":"actual isolated gateway/SQLite observations; other journey steps remain separate"}}

def capture_canary(config,fault,relay_status=None):
    require(fault in EXPECTED,"unsupported canary case")
    candidate=code_identity(config);before=money_snapshot(config);started=time.time()
    log=Path(config["provider_log"]);offset=log.stat().st_size if log.exists() else 0
    observed={};end=time.monotonic()+min(int(config.get("canary_wait_seconds",210)),900)
    while time.monotonic()<end:
        response=http(endpoint(config["coordinator_url"])+"/poolz",bearer=token(config["operator_token_file"]))
        require(response["status"]==200,"operator pool diagnostics unavailable")
        matches=[p for p in response["body"].get("pool",[]) if p.get("provider_id")==config["provider_id"]]
        require(len(matches)<=1,"ambiguous provider pool identity")
        if matches:
            observed=matches[0];diag=observed.get("native_mtp_canary") or {}
            if fresh_diagnostic(diag,started) and (diag.get("last_reason")==EXPECTED[fault] or diag.get("disabled_reason")==EXPECTED[fault]):break
        time.sleep(1)
    after=money_snapshot(config)
    trace=_log(log,offset)
    # A real paid fallback request comes AFTER the diagnostic-only money fence.
    # Never turn its expected accounting changes into a no-money canary claim.
    fallback=None;fallback_error=None
    if fault!="good" and observed.get("native_mtp_canary",{}).get("status")=="disabled":
        try:
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                if require_status(config,_status(config)).get("native_mtp",{}).get("enabled") is False:break
                time.sleep(1)
            fallback=capture_accounting(config,"ordinary")
        except (ValueError,OSError,KeyError,TypeError) as error:fallback_error=str(error)
    return {"schema_version":SCHEMA,"kind":"canary","fault":fault,"candidate":candidate,"started_at_unix":started,"provider":observed,"money_before":before,"money_after":after,"provider_log":trace,"relay":read(relay_status) if relay_status else None,"ordinary_fallback":fallback,"ordinary_fallback_error":fallback_error,"diagnostic_disposition":{"losslessness":"pending:no_existing_native_claimed_path_result_observed","compute_integrity":"pending:no_existing_native_claimed_path_result_observed"}}

def fresh_diagnostic(diag,started):
    # Both times originate in the coordinator's actual tuple state. Collection
    # starts before provider launch; stale outcomes from an earlier case fail.
    try:
        return all(datetime.fromisoformat(diag[k].replace("Z","+00:00")).timestamp()>=started for k in ("offered_at","last_checked_at"))
    except (KeyError,ValueError,TypeError,AttributeError):return False

def compare_canary(samples):
    checks={"native_path_canary":False,"native_path_selftest":False,"losslessness_claimed_path_diagnostic_inconclusive":False,"compute_integrity_claimed_path_diagnostic_inconclusive":False}
    reasons=[];cases={}
    try:
        require(len(samples)==len(EXPECTED) and {s["fault"] for s in samples}==set(EXPECTED),"good plus all five actual negative cases required")
        require(all(s["schema_version"]==SCHEMA and s["kind"]=="canary" and s["candidate"]==samples[0]["candidate"] for s in samples),"same signed candidate actual canary observations required")
        for s in samples:
            fault=s["fault"];diag=s["provider"].get("native_mtp_canary",{})
            require(diag.get("provider_binary_sha256")==s["candidate"]["binary_sha256"] and diag.get("runtime_cdhash")==s["candidate"]["cdhash"],"canary runtime identity mismatch")
            require(fresh_diagnostic(diag,s["started_at_unix"]),"stale canary observation")
            require(s["money_before"]==s["money_after"],"canary diagnostic changed money tables")
            require(diag.get("last_reason")==EXPECTED[fault] or diag.get("disabled_reason")==EXPECTED[fault],"actual canary reason missing: "+fault)
            if fault=="good":
                require(diag.get("last_outcome")=="pass" and diag.get("status")=="fresh","good native canary not fresh/pass")
                checks["native_path_selftest"]=bool(re.search(r"event=native_mtp_self_check result=passed\b",s["provider_log"]))
            else:
                relay=s["relay"] or {}
                require(relay.get("canary_results_faulted",0)>0 and relay.get("last_fault")==("delay" if fault=="expiry" else fault) and diag.get("status")=="disabled","physical relay/tuple disable missing")
                fallback=s.get("ordinary_fallback")
                require(fallback and fallback["candidate"]==s["candidate"] and fallback["phase"]=="ordinary","ordinary fallback probe missing")
                accounting_projection(fallback)
            cases[fault]={"reason":diag.get("disabled_reason") or diag.get("last_reason"),"money_unchanged":True}
        checks["native_path_canary"]=True
    except (ValueError,KeyError,TypeError) as error:reasons.append(str(error))
    # Current production surfaces do not export a claimed-native-path SPEC030/
    # SPEC036 result. Never infer it from observe_only source or tuple disable.
    reasons.append("SPEC030/SPEC036 native claimed-path inconclusive result is not exported by existing collection APIs/log events")
    return {"schema_version":STEP_SCHEMA,"step_id":"step-12-native-canary","status":"pass" if all(checks.values()) else "pending","checks":checks,"details":{"cases":cases,"pending_reasons":reasons,"observation_sha256":[hashlib.sha256(canonical(s)).hexdigest() for s in samples],"journey_complete":False}}

def relay_main(args):
    """Run the reviewed relay, unchanged; expiry delays actual result frames.

    The relay cannot sign or delay a coordinator challenge. A deadline race can
    therefore produce timeout, which comparison correctly refuses as expiry.
    """
    require(os.environ.get("MACPROVIDER_OPS_ENTRYPOINT")=="1" and bool(os.environ.get("MACPROVIDER_OPS_OWNER")),"owning paused-window ops controller required")
    # Exact repo-relative reviewed script; no caller-selected executable.
    script=Path(args.repo).resolve()/"scripts/native_mtp_canary_negative_rehearsal.py"
    require(script.is_file() and not script.is_symlink(),"reviewed fault relay unavailable")
    upstream=urlparse(args.upstream_url)
    require(upstream.scheme=="ws" and upstream.path in {"","/ws/provider"} and not upstream.query and not upstream.fragment,"isolated provider websocket required")
    endpoint("http://"+upstream.netloc)
    require(19300<=args.listen_port<=19399 and args.listen_port!=upstream.port,"isolated distinct relay port required")
    require(0<=args.delay_seconds<=900 and (args.fault!="expiry" or args.delay_seconds>0),"bounded expiry delay required")
    return subprocess.call([sys.executable,str(script),"--listen-host","127.0.0.1","--listen-port",str(args.listen_port),"--upstream-url",args.upstream_url,"--fault","delay" if args.fault=="expiry" else args.fault,"--delay-seconds",str(args.delay_seconds),"--status-path",str(args.status_path)])

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest="command",required=True)
    for verb in ("accounting-capture","canary-capture"):
        p=sub.add_parser(verb);p.add_argument("--config",type=Path,required=True);p.add_argument("--out",type=Path,required=True)
        if verb=="accounting-capture":p.add_argument("--phase",choices=("ordinary","native"),required=True)
        else:p.add_argument("--fault",choices=tuple(EXPECTED),required=True);p.add_argument("--relay-status",type=Path)
    p=sub.add_parser("accounting-compare");p.add_argument("--ordinary",type=Path,required=True);p.add_argument("--native",type=Path,required=True);p.add_argument("--out",type=Path,required=True)
    p=sub.add_parser("canary-compare");p.add_argument("--observation",type=Path,action="append",required=True);p.add_argument("--out",type=Path,required=True)
    p=sub.add_parser("relay");p.add_argument("--repo",type=Path,required=True);p.add_argument("--listen-port",type=int,required=True);p.add_argument("--upstream-url",required=True);p.add_argument("--fault",choices=tuple(f for f in EXPECTED if f!="good"),required=True);p.add_argument("--delay-seconds",type=float,default=0);p.add_argument("--status-path",type=Path,required=True)
    args=parser.parse_args(argv)
    try:
        if args.command=="relay":return relay_main(args)
        if args.command.endswith("capture"):
            require(os.environ.get("MACPROVIDER_OPS_ENTRYPOINT")=="1" and bool(os.environ.get("MACPROVIDER_OPS_OWNER")),"owning paused-window ops controller required")
            config=read(args.config)
            result=capture_accounting(config,args.phase) if args.command=="accounting-capture" else capture_canary(config,args.fault,args.relay_status)
        elif args.command=="accounting-compare":result=compare_accounting(read(args.ordinary),read(args.native))
        else:result=compare_canary([read(p) for p in args.observation])
        write(args.out,result);print(json.dumps({"status":result.get("status","collected"),"artifact_sha256":sha(args.out)},sort_keys=True))
        return 0 if result.get("status") in (None,"pass") else 2
    except (ValueError,OSError,KeyError,TypeError) as error:
        print(json.dumps({"status":"FAIL","reason":str(error)},sort_keys=True));return 1

if __name__=="__main__":raise SystemExit(main())
