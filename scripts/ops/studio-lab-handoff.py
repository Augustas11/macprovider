#!/usr/bin/env python3
"""Recover the one retained, unloaded Studio lab handoff without changing it.

Only a private, hash-pinned manifest can arm this controller.  ``status`` and
``next`` inspect state; ``next --run`` performs one recovery transaction.  It
never swaps a payload or configuration, removes the inherited handoff marker,
releases the campaign lock, or restarts Pearl's coordinator.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
OPS = ROOT / "scripts" / "ops"
NAME = "studio-lab-handoff"
SCHEMA = "macprovider.studio_lab_handoff_recovery.v1"
EXPECTED_VERSION = "1.8.274"
EXPECTED_MODEL = "zai-org/glm-5.3-flash"
EXPECTED_STUDIO = "Mac15,14"
RUNNER = "malibu-buyer-runner.service"
READY_STALL_SECONDS = 30 * 60
STABLE_SECONDS = 120


class Refusal(RuntimeError):
    """A deliberate fail-closed operational refusal."""


def refuse(message: str) -> None:
    raise Refusal(message)


def strict_json(raw: bytes, what: str) -> dict[str, Any]:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in items:
            if key in value:
                refuse(f"duplicate {what} key: {key}")
            value[key] = item
        return value

    try:
        value = json.loads(raw, object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (TypeError, ValueError) as exc:
        raise Refusal(f"invalid {what} JSON") from exc
    if not isinstance(value, dict):
        refuse(f"{what} must be an object")
    return value


def private_regular(path: Path, what: str, maximum: int = 256 * 1024) -> bytes:
    try:
        before = path.lstat()
    except OSError as exc:
        raise Refusal(f"{what} is missing") from exc
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or
            before.st_uid != os.getuid() or before.st_mode & 0o077):
        refuse(f"{what} must be a private regular file owned by this user")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            refuse(f"{what} changed while opening")
        data = os.read(fd, maximum + 1)
    finally:
        os.close(fd)
    if len(data) > maximum or len(data) != before.st_size:
        refuse(f"{what} size is unsafe")
    return data


def plain_absolute(value: object, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"/[A-Za-z0-9._/-]+", value):
        refuse(f"{field} must be an absolute plain path")
    if "//" in value or value.endswith("/..") or "/../" in value:
        refuse(f"{field} contains an unsafe path component")
    return value


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha_field(value: object, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        refuse(f"{field} must be a lowercase sha256")
    return value


def exact_keys(value: dict[str, Any], allowed: set[str], what: str) -> None:
    if set(value) != allowed:
        refuse(f"{what} fields differ")


def load_manifest(path: Path) -> tuple[dict[str, Any], str]:
    raw = private_regular(path, "private recovery manifest")
    manifest = strict_json(raw, "private recovery manifest")
    exact_keys(manifest, {"schema_version", "all_cells_complete", "root_arm", "lock_owner",
                          "studio", "pearl"}, "private recovery manifest")
    if manifest["schema_version"] != SCHEMA:
        refuse("private recovery manifest schema differs")
    if manifest["all_cells_complete"] is not True or manifest["root_arm"] is not True:
        refuse("private recovery manifest is not explicitly all-cells complete and root-armed")
    if (not isinstance(manifest["lock_owner"], str) or
            not re.fullmatch(r"[A-Za-z0-9._@:/+-]+", manifest["lock_owner"])):
        refuse("private recovery manifest lock owner is invalid")
    studio = manifest["studio"]
    if not isinstance(studio, dict):
        refuse("private recovery manifest studio must be an object")
    exact_keys(studio, {"handoff_path", "journal_path", "install_dir", "config_path",
                        "provider_plist_path", "watchdog_plist_path", "control_socket",
                        "status_port", "launch_label", "watchdog_label", "hardware_model",
                        "binary_version", "model", "binary_sha256", "config_sha256",
                        "provider_plist_sha256", "watchdog_plist_sha256", "handoff_sha256"}, "private recovery manifest studio")
    for field in ("handoff_path", "journal_path", "install_dir", "config_path",
                  "provider_plist_path", "watchdog_plist_path", "control_socket"):
        studio[field] = plain_absolute(studio[field], f"studio.{field}")
    if (not isinstance(studio["status_port"], int) or isinstance(studio["status_port"], bool)
            or not 1 <= studio["status_port"] <= 65535):
        refuse("studio.status_port is invalid")
    if studio["hardware_model"] != EXPECTED_STUDIO:
        refuse(f"studio.hardware_model must be {EXPECTED_STUDIO}")
    if studio["binary_version"] != EXPECTED_VERSION:
        refuse(f"studio.binary_version must be {EXPECTED_VERSION}")
    if studio["model"] != EXPECTED_MODEL:
        refuse(f"studio.model must be {EXPECTED_MODEL}")
    for field in ("launch_label", "watchdog_label"):
        if not isinstance(studio[field], str) or not re.fullmatch(r"[A-Za-z0-9._-]+", studio[field]):
            refuse(f"studio.{field} is invalid")
    for field in ("binary_sha256", "config_sha256", "provider_plist_sha256", "watchdog_plist_sha256", "handoff_sha256"):
        studio[field] = sha_field(studio[field], f"studio.{field}")
    pearl = manifest["pearl"]
    if not isinstance(pearl, dict) or set(pearl) != {"runner_unit"} or pearl["runner_unit"] != RUNNER:
        refuse(f"private recovery manifest pearl.runner_unit must be {RUNNER}")
    return manifest, sha256(raw)


def source_ops_profile() -> None:
    """Load the ordinary private ops profile, just as shell entrypoints do."""
    path = Path(os.environ.get("MACPROVIDER_OPS_ENV", str(Path.home() / ".config/macprovider/ops.env")))
    if path == Path("/dev/null") or not path.exists():
        return
    private_regular(path, "private ops profile", maximum=256 * 1024)
    result = subprocess.run(["bash", "-c", 'set -a; . "$1"; env -0', "bash", str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        refuse("private ops profile could not be loaded")
    allowed = {"STUDIO_SSH", "STUDIO_SSH_KEY", "PEARL_SSH", "PEARL_SSH_IDENTITY",
               "PEARL_SSH_KNOWN_HOSTS", "STUDIO_LAB_HANDOFF_MANIFEST",
               "MACPROVIDER_OPS_STATE_DIR", "MACPROVIDER_GH_REPO", "MACPROVIDER_LIVE_LOCK"}
    for item in result.stdout.split(b"\0"):
        key, separator, value = item.partition(b"=")
        name = key.decode("ascii", "ignore")
        if separator and name in allowed:
            os.environ[name] = value.decode("utf-8", "surrogateescape")


def env_host(name: str) -> str:
    value = os.environ.get(name, "")
    if not re.fullmatch(r"[A-Za-z0-9._@:-]+", value or "") or value == "local":
        refuse(f"{name} must name the designated remote host, not local")
    return value


def ssh(host: str, program: str, payload: dict[str, Any], *, identity_env: str,
        known_hosts_env: str = "", timeout: int | None = 45) -> dict[str, Any]:
    """Run fixed Python supplied on stdin; none of the manifest becomes argv."""
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    identity = os.environ.get(identity_env, "")
    if identity:
        if not Path(identity).is_absolute():
            refuse(f"{identity_env} must be an absolute path")
        command.extend(["-i", identity, "-o", "IdentitiesOnly=yes"])
    known_hosts = os.environ.get(known_hosts_env, "") if known_hosts_env else ""
    if known_hosts:
        if not Path(known_hosts).is_absolute():
            refuse(f"{known_hosts_env} must be an absolute path")
        command.extend(["-o", f"UserKnownHostsFile={known_hosts}", "-o", "StrictHostKeyChecking=yes"])
    command.extend([host, "python3 -I -"])
    try:
        result = subprocess.run(command, input=(program + "\n__PAYLOAD__=" + repr(json.dumps(payload, sort_keys=True)) + "\nmain(__PAYLOAD__)\n").encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refusal(f"remote operation failed: {type(exc).__name__}") from exc
    if result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["remote refusal"]
        raise Refusal(f"remote operation refused: {detail[0]}")
    value = strict_json(result.stdout, "remote response")
    if value.get("ok") is not True:
        refuse("remote operation did not return ok")
    return value


REMOTE = r'''
import hashlib,json,os,plistlib,re,socket,stat,subprocess,sys,time
from pathlib import Path
def bad(m): raise RuntimeError(m)
def strict(raw,what):
 def pairs(xs):
  d={}
  for k,v in xs:
   if k in d: bad("duplicate %s key"%what)
   d[k]=v
  return d
 x=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:bad("nonfinite %s"%what))
 if not isinstance(x,dict): bad("%s object required"%what)
 return x
def regular(p,limit):
 p=Path(p); s=p.lstat()
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_uid!=os.getuid() or s.st_mode&0o022: bad("unsafe file: "+p.name)
 f=os.open(str(p),os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
 try:
  t=os.fstat(f)
  if (s.st_dev,s.st_ino)!=(t.st_dev,t.st_ino): bad("file changed: "+p.name)
  b=os.read(f,limit+1)
 finally: os.close(f)
 if len(b)>limit or len(b)!=s.st_size: bad("unsafe file size: "+p.name)
 return b
def digest(p,limit=8*1024*1024):
 p=Path(p); s=p.lstat()
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_uid!=os.getuid() or s.st_mode&0o022: bad("unsafe file: "+p.name)
 if s.st_size>limit: bad("unsafe file size: "+p.name)
 def identity(v): return (v.st_dev,v.st_ino,v.st_size,v.st_mtime_ns,v.st_ctime_ns,v.st_mode,v.st_nlink,v.st_uid)
 f=os.open(str(p),os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
 try:
  if identity(os.fstat(f))!=identity(s): bad("file changed: "+p.name)
  h=hashlib.sha256(); total=0
  while True:
   chunk=os.read(f,min(1024*1024,limit-total+1))
   if not chunk: break
   total+=len(chunk)
   if total>limit: bad("unsafe file size: "+p.name)
   h.update(chunk)
  if total!=s.st_size or identity(os.fstat(f))!=identity(s) or identity(p.lstat())!=identity(s): bad("file changed: "+p.name)
  return h.hexdigest()
 finally: os.close(f)
def binary_digest(p): return digest(p,512*1024*1024)
def put(p,d):
 p=Path(p); p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 tmp=p.with_name("."+p.name+".tmp")
 fd=os.open(str(tmp),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,"w") as f: json.dump(d,f,sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
 os.replace(tmp,p)
def load_journal(p,expect):
 q=Path(p)
 if not q.exists(): return None
 d=strict(regular(q,128*1024),"recovery journal")
 if set(d)!={"schema_version","manifest_sha256","phase","provider_pid","provider_start_us"}: bad("recovery journal fields differ")
 if d["schema_version"]!="macprovider.studio_lab_handoff_recovery.v1" or d["manifest_sha256"]!=expect: bad("recovery journal does not belong to this manifest")
 if d["phase"] not in {"armed","provider_bootstrapped","provider_stable","restored"}: bad("recovery journal phase invalid")
 for k in ("provider_pid","provider_start_us"):
  if d[k] is not None and (type(d[k]) is not int or d[k]<=0): bad("recovery journal process invalid")
 return d
def launch_loaded(label): return subprocess.run(["launchctl","print","gui/%s/%s"%(os.getuid(),label)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
def cli_processes(binary):
 out=subprocess.run(["ps","-axo","pid=,uid=,command="],stdout=subprocess.PIPE,text=True,check=True).stdout
 found=[]
 for line in out.splitlines():
  parts=line.strip().split(None,2)
  if len(parts)==3 and parts[1]==str(os.getuid()) and parts[2].split(" ",1)[0]==binary: found.append(int(parts[0]))
 return found
def status(port):
 p=subprocess.run(["curl","-fsS","--max-time","5","http://127.0.0.1:%s/v1/status"%port],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 if p.returncode: return None
 return strict(p.stdout,"provider status")
def get(d,path):
 for k in path.split("."): d=d.get(k) if isinstance(d,dict) else None
 return d
def ready(s,x):
 return (get(s,"binary_version")==x["binary_version"] and get(s,"model")==x["model"] and get(s,"model_loaded") is True and get(s,"lifecycle.operator_paused") is not True and
         get(s,"network_state")=="buyer_serving" and get(s,"continuous_batching.active") is True and
         get(s,"continuous_batching.policy.cached_turns_authorized") is True and
         type(get(s,"service_instance.pid")) is int and get(s,"service_instance.pid")>0 and
         type(get(s,"service_instance.process_start_us")) is int and get(s,"service_instance.process_start_us")>0)
def check_static(x):
 if subprocess.run(["sysctl","-n","hw.model"],stdout=subprocess.PIPE,text=True,check=True).stdout.strip()!=x["hardware_model"]: bad("wrong hardware model")
 b=x["install_dir"]+"/macprovider-cli"
 for p,k in ((b,"binary_sha256"),(x["config_path"],"config_sha256"),(x["provider_plist_path"],"provider_plist_sha256"),(x["watchdog_plist_path"],"watchdog_plist_sha256")):
  # Released CLI bytes exceed the metadata cap; hash them in bounded chunks.
  actual=binary_digest(p) if k=="binary_sha256" else digest(p)
  if actual!=x[k]: bad("immutable %s hash differs"%k)
 subprocess.run(["codesign","--verify","--strict",b],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
 return b
def handoff(x):
 raw=regular(x["handoff_path"],4096); d=strict(raw,"handoff")
 if set(d)!={"from","at","studio_state","runner"} or d["studio_state"]!="paused_live_unloaded" or d["runner"]!="stopped": bad("handoff is not paused_live_unloaded with runner stopped")
 if not isinstance(d["from"],str) or not isinstance(d["at"],str): bad("handoff identity invalid")
 if hashlib.sha256(raw).hexdigest()!=x["handoff_sha256"]: bad("handoff hash differs")
 return d
def resume(sock):
 c=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); c.settimeout(5)
 try:
  c.connect(sock); c.sendall(b'{"type":"resume_request"}\n'); r=c.recv(65536)
 finally: c.close()
 try: d=strict(r,"resume response")
 except Exception: bad("invalid resume response")
 if d.get("type") not in {"resume_ack","resumed"}: bad("provider rejected resume")
def inspect(x,msha):
 b=check_static(x); h=handoff(x); j=load_journal(x["journal_path"],msha)
 return {"ok":True,"handoff":h,"journal_phase":None if j is None else j["phase"],"provider_loaded":launch_loaded(x["launch_label"]),"watchdog_loaded":launch_loaded(x["watchdog_label"]),"provider_processes":cli_processes(b)}
def provider_log_progress(x):
 p=plistlib.loads(regular(x["provider_plist_path"],8*1024*1024)); stamps=[]
 for k in ("StandardOutPath","StandardErrorPath"):
  name=p.get(k)
  if not isinstance(name,str): continue
  try:
   s=Path(name).stat()
   if stat.S_ISREG(s.st_mode): stamps.append((s.st_dev,s.st_ino,s.st_size))
  except FileNotFoundError: pass
 return tuple(stamps)
def recover(x,msha):
 b=check_static(x); handoff(x); j=load_journal(x["journal_path"],msha)
 pl=launch_loaded(x["launch_label"]); wl=launch_loaded(x["watchdog_label"]); procs=cli_processes(b)
 if j is None:
  if pl or wl or procs: bad("foreign or unexpected provider state before journal arm")
  j={"schema_version":"macprovider.studio_lab_handoff_recovery.v1","manifest_sha256":msha,"phase":"armed","provider_pid":None,"provider_start_us":None}; put(x["journal_path"],j)
 if j["phase"] in {"provider_stable","restored"}:
  s=status(x["status_port"])
  if not (pl and wl and s and ready(s,x)): bad("stable journal does not match stable provider")
  if (get(s,"service_instance.pid"),get(s,"service_instance.process_start_us"))!=(j["provider_pid"],j["provider_start_us"]) or procs!=[j["provider_pid"]]: bad("stable journal provider identity differs")
  return {"ok":True,"phase":j["phase"],"status":s}
 if wl: bad("watchdog loaded before provider stability journal")
 if not pl:
  if procs: bad("foreign provider process before bootstrap")
  subprocess.run(["launchctl","bootstrap","gui/%s"%os.getuid(),x["provider_plist_path"]],check=True)
  j.update(phase="provider_bootstrapped"); put(x["journal_path"],j)
 stable_since=None; seen=None; resumed=False; last_progress=time.monotonic(); states=set(); logs=provider_log_progress(x); process_seen=None
 while True:
  processes=cli_processes(b)
  if len(processes)>1: bad("unexpected provider processes during recovery")
  if process_seen is not None and processes!=[process_seen]: bad("provider process died or changed during recovery")
  if processes and process_seen is None: process_seen=processes[0]; last_progress=time.monotonic()
  s=status(x["status_port"])
  if s is not None:
   # Repeated polling/telemetry is not progress; only previously unseen lifecycle states count.
   state=tuple(json.dumps(get(s,k),sort_keys=True) for k in ("model_loaded","network_state","lifecycle.operator_paused","continuous_batching.active","continuous_batching.policy.cached_turns_authorized","service_instance.pid","service_instance.process_start_us"))
   if state not in states: states.add(state); last_progress=time.monotonic()
  current_logs=provider_log_progress(x)
  if current_logs!=logs: logs=current_logs; last_progress=time.monotonic()
  if not resumed and os.path.exists(x["control_socket"]):
   resume(x["control_socket"]); resumed=True; last_progress=time.monotonic()
  if resumed and s and ready(s,x):
   pid=get(s,"service_instance.pid"); start=get(s,"service_instance.process_start_us")
   if cli_processes(b)!=[pid]: bad("provider process identity differs")
   stamp=(pid,start)
   if stamp!=seen or stable_since is None: seen=stamp; stable_since=time.monotonic(); j.update(phase="provider_bootstrapped",provider_pid=pid,provider_start_us=start); put(x["journal_path"],j)
   if time.monotonic()-stable_since>=120: break
  else: stable_since=None
  if time.monotonic()-last_progress>=1800: bad("provider made no lifecycle or log progress for 30 minutes")
  time.sleep(5)
 if not launch_loaded(x["watchdog_label"]): subprocess.run(["launchctl","bootstrap","gui/%s"%os.getuid(),x["watchdog_plist_path"]],check=True)
 s=status(x["status_port"])
 if not (ready(s,x) and launch_loaded(x["watchdog_label"]) and (get(s,"service_instance.pid"),get(s,"service_instance.process_start_us"))==seen): bad("provider changed while watchdog started")
 j.update(phase="provider_stable",provider_pid=seen[0],provider_start_us=seen[1]); put(x["journal_path"],j)
 return {"ok":True,"phase":"provider_stable","status":s}
def finish(x,msha):
 j=load_journal(x["journal_path"],msha); s=status(x["status_port"])
 if not j or j["phase"] not in {"provider_stable","restored"} or not (ready(s,x) and launch_loaded(x["launch_label"]) and launch_loaded(x["watchdog_label"])): bad("provider is not stable for recovery completion")
 if (get(s,"service_instance.pid"),get(s,"service_instance.process_start_us"))!=(j["provider_pid"],j["provider_start_us"]): bad("provider changed after stability")
 j["phase"]="restored"; put(x["journal_path"],j)
 return {"ok":True,"phase":"restored","status":s}
def provenance(x,msha):
 b=check_static(x); j=load_journal(x["journal_path"],msha); s=status(x["status_port"])
 if not j or j["phase"] not in {"provider_stable","restored"} or not (ready(s,x) and launch_loaded(x["launch_label"])): bad("provider is not stable for provenance")
 pid=get(s,"service_instance.pid")
 if (pid,get(s,"service_instance.process_start_us"))!=(j["provider_pid"],j["provider_start_us"]) or cli_processes(b)!=[pid]: bad("provider process identity differs for provenance")
 # The shared release helper consumes a flat dotted PID key. Keep the native
 # nested status, and adapt only this independently verified process identity.
 release_status=dict(s); release_status["service_instance.pid"]=pid
 return {"ok":True,"installed":installed_identity(b),"launch":{"pid":pid,"executable_path":b},"status":release_status}
def installed_identity(b):
 out=subprocess.run(["codesign","-d","--arch","arm64","-vvv",b],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,check=True).stdout
 fields={}
 for line in out.splitlines():
  k,sep,v=line.partition("=")
  if sep and k in {"Identifier","TeamIdentifier","CDHash"}: fields[k]=v.strip()
 if set(fields)!={"Identifier","TeamIdentifier","CDHash"}: bad("installed code identity incomplete")
 version=subprocess.run([b,"--version"],stdout=subprocess.PIPE,text=True,check=True).stdout.strip()
 return {"binary_version":version,"binary_sha256":binary_digest(b),"identifier":fields["Identifier"],"team_id":fields["TeamIdentifier"],"cdhash":fields["CDHash"].lower()}
def static_provenance(x):
 b=check_static(x)
 # No process exists yet: null PIDs explicitly make no running-provider claim.
 return {"ok":True,"stage":"prelaunch_static","installed":installed_identity(b),"launch":{"pid":None,"executable_path":b},"status":{"service_instance":{"pid":None},"service_instance.pid":None}}
def main(raw):
 p=strict(raw.encode(),"payload"); x=p["studio"]; a=p["action"]
 if a=="inspect": return print(json.dumps(inspect(x,p["manifest_sha256"]),sort_keys=True))
 if a=="recover": return print(json.dumps(recover(x,p["manifest_sha256"]),sort_keys=True))
 if a=="finish": return print(json.dumps(finish(x,p["manifest_sha256"]),sort_keys=True))
 if a=="provenance": return print(json.dumps(provenance(x,p["manifest_sha256"]),sort_keys=True))
 if a=="static_provenance": return print(json.dumps(static_provenance(x),sort_keys=True))
 bad("invalid action")
'''


PEARL = r'''
import json,subprocess,sys
def main(raw):
 p=json.loads(raw)
 if set(p)!={"action","unit"} or p["unit"]!="malibu-buyer-runner.service" or p["action"] not in {"status","start"}: raise RuntimeError("invalid runner request")
 state=subprocess.run(["systemctl","is-active",p["unit"]],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True).stdout.strip()=="active"
 if p["action"]=="status": return print(json.dumps({"ok":True,"runner_active":state}))
 if not state: subprocess.run(["systemctl","start",p["unit"]],check=True,stdout=subprocess.DEVNULL)
 if subprocess.run(["systemctl","is-active",p["unit"]],check=True,stdout=subprocess.PIPE,text=True).stdout.strip()!="active": raise RuntimeError("runner inactive")
 print(json.dumps({"ok":True,"runner_active":True}))
'''


def remote_action(studio_host: str, manifest: dict[str, Any], manifest_sha: str, action: str,
                  *, timeout: int | None = 45) -> dict[str, Any]:
    return ssh(studio_host, REMOTE, {"action": action, "studio": manifest["studio"],
                                     "manifest_sha256": manifest_sha}, identity_env="STUDIO_SSH_KEY", timeout=timeout)


def verify_published(version: str, probe: dict[str, Any], install_dir: str) -> None:
    """Use the release-train identity gate after launch, before Pearl is resumed."""
    common = OPS / "lib" / "common.sh"
    helper = OPS / "lib" / "published-provider-identity.sh"
    script = '. "$1"; . "$2"; p="$(cat)"; published_provider_identity_ok "$3" "$p" "$4"'
    result = subprocess.run(["bash", "-c", script, "bash", str(common), str(helper), version, install_dir],
                            input=json.dumps(probe, sort_keys=True).encode(), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=150, check=False)
    if result.returncode:
        refuse("published signed-release provenance could not be verified")


def acquire_lock(owner: str) -> None:
    result = subprocess.run([str(OPS / "live-lock.sh"), "acquire", owner,
                             "--purpose", f"{NAME}:restore"], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, check=False)
    if result.returncode:
        refuse("could not acquire or refresh the retained live-ops lock")


def write_local_journal(manifest_sha: str, phase: str) -> None:
    state = Path(os.environ.get("MACPROVIDER_OPS_STATE_DIR", str(Path.home() / ".config/macprovider/ops-state")))
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = state / "studio-lab-handoff-recovery.json"
    data = {"schema_version": "macprovider.studio_lab_handoff_recovery_local.v1",
            "manifest_sha256": manifest_sha, "phase": phase}
    fd, temp = tempfile.mkstemp(prefix=".studio-lab-handoff-", dir=state)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def local_phase(manifest_sha: str) -> str | None:
    state = Path(os.environ.get("MACPROVIDER_OPS_STATE_DIR", str(Path.home() / ".config/macprovider/ops-state")))
    path = state / "studio-lab-handoff-recovery.json"
    if not path.exists():
        return None
    record = strict_json(private_regular(path, "local recovery journal"), "local recovery journal")
    exact_keys(record, {"schema_version", "manifest_sha256", "phase"}, "local recovery journal")
    if (record["schema_version"] != "macprovider.studio_lab_handoff_recovery_local.v1" or
            record["manifest_sha256"] != manifest_sha or
            record["phase"] not in {"armed", "provider_stable", "runner_starting", "runner_active", "restored"}):
        refuse("local recovery journal does not belong to this manifest")
    return record["phase"]


def status(manifest: dict[str, Any], manifest_sha: str) -> dict[str, Any]:
    studio = env_host("STUDIO_SSH")
    inspected = remote_action(studio, manifest, manifest_sha, "inspect")
    complete = inspected["journal_phase"] == "restored"
    ready = (not complete and inspected["handoff"]["studio_state"] == "paused_live_unloaded" and
             inspected["handoff"]["runner"] == "stopped")
    return {"train": NAME, "manifest_sha256": manifest_sha, "all_cells_complete": True,
            "root_armed": True, "studio": inspected,
            "next": {"id": "recovery_complete" if complete else "restore_inherited_handoff",
                     "kind": "done" if complete else ("mutate" if ready else "blocked"),
                     "command": "" if complete else f"MACPROVIDER_OPS_OWNER={manifest['lock_owner']} scripts/ops/{NAME}.py next --run",
                     "reason": "recovery journal is durable; handoff and lock remain retained" if complete else
                               ("restores original signed provider before runner" if ready else "handoff no longer matches retained state")}}


def run_restore(manifest: dict[str, Any], manifest_sha: str) -> dict[str, Any]:
    owner = os.environ.get("MACPROVIDER_OPS_OWNER", "")
    if owner != manifest["lock_owner"]:
        refuse("MACPROVIDER_OPS_OWNER does not match the root-armed manifest owner")
    studio = env_host("STUDIO_SSH")
    pearl = env_host("PEARL_SSH")
    # This is deliberately non-PID-bound: recovery remains serialized if the local controller dies.
    acquire_lock(owner)
    previous = local_phase(manifest_sha)
    runner_before = ssh(pearl, PEARL, {"action": "status", "unit": RUNNER},
                        identity_env="PEARL_SSH_IDENTITY", known_hosts_env="PEARL_SSH_KNOWN_HOSTS")
    if runner_before.get("runner_active") is True and previous not in {"runner_starting", "runner_active", "restored"}:
        refuse("buyer runner is already active outside this recovery journal")
    if previous is None:
        write_local_journal(manifest_sha, "armed")
    probe = remote_action(studio, manifest, manifest_sha, "static_provenance")
    verify_published(EXPECTED_VERSION, probe, manifest["studio"]["install_dir"])
    # The remote loop owns the progress stall detector; recovery has no elapsed-time ceiling.
    recovered = remote_action(studio, manifest, manifest_sha, "recover", timeout=None)
    if recovered.get("phase") not in {"provider_stable", "restored"}:
        refuse("provider did not reach a durable stable recovery phase")
    if previous not in {"runner_starting", "runner_active", "restored"}:
        write_local_journal(manifest_sha, "provider_stable")
    probe = remote_action(studio, manifest, manifest_sha, "provenance")
    verify_published(EXPECTED_VERSION, probe, manifest["studio"]["install_dir"])
    if previous not in {"runner_active", "restored"}:
        write_local_journal(manifest_sha, "runner_starting")
    runner = ssh(pearl, PEARL, {"action": "start", "unit": RUNNER}, identity_env="PEARL_SSH_IDENTITY",
                 known_hosts_env="PEARL_SSH_KNOWN_HOSTS")
    if runner.get("runner_active") is not True:
        refuse("Pearl buyer runner did not become active")
    if previous != "restored":
        write_local_journal(manifest_sha, "runner_active")
    finished = remote_action(studio, manifest, manifest_sha, "finish")
    if finished.get("phase") != "restored":
        refuse("remote recovery journal did not reach restored")
    write_local_journal(manifest_sha, "restored")
    return {"ok": True, "phase": "restored", "buyer_runner": "active",
            "handoff_retained": True, "lock_retained": True}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "next"))
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args(argv)
    source_ops_profile()
    if args.command == "status" and args.run:
        parser.error("status is read-only")
    manifest_path = args.manifest or Path(os.environ.get("STUDIO_LAB_HANDOFF_MANIFEST", ""))
    if not os.environ.get("STUDIO_LAB_HANDOFF_MANIFEST") and args.manifest is None:
        refuse("STUDIO_LAB_HANDOFF_MANIFEST is required")
    manifest, manifest_sha = load_manifest(manifest_path)
    if args.command == "next" and args.run:
        print(json.dumps(run_restore(manifest, manifest_sha), sort_keys=True))
    else:
        print(json.dumps(status(manifest, manifest_sha), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Refusal as exc:
        print(f"{NAME}: REFUSED: {exc}", file=sys.stderr)
        raise SystemExit(3)
