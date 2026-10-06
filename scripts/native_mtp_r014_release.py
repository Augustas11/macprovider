"""Release-asset and updater phases of the SPEC-048-R014 rehearsal runner.

`release_asset_identity` downloads the immutable published assets, verifies
the signed provider code identity, and runs the repository's
`scripts/verify-malibu-release-artifacts.sh` byte-identity check between the
Malibu.app-embedded CLI and the standalone tarball CLI.

`updater_path` installs the previous stable CLI into a private home and runs
its own `update` against the public release feed. The process runs with
`CFFIXED_USER_HOME` (Foundation's home override) pointing at that private
home, so there is no LaunchAgents plist and the updater's launchd reload is
skipped by its own guard (SelfUpdate.swift `restartLaunchdIfInstalled`). As a
second layer, `sandbox-exec` denies every `launchctl` exec and every write
under the operator's real install, config, LaunchAgents, live pool, and
/Applications paths.

Called from native_mtp_r014_journey.Runner.
"""

from __future__ import annotations

import json
import re
import shutil
import tarfile
import urllib.request
from pathlib import Path

from native_mtp_r014_journey import FAIL, PASS, run, sha256_file

BASE = "https://github.com/Augustas11/macprovider/releases/download"


def _download(tag: str, name: str, dest: Path) -> Path:
    path = dest / name
    if not path.exists():
        with urllib.request.urlopen(f"{BASE}/{tag}/{name}", timeout=600) as resp, open(path, "wb") as out:
            shutil.copyfileobj(resp, out)
    return path


def _checksums(path: Path) -> dict:
    out = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2:
            out[parts[1].lstrip("*")] = parts[0]
    return out


def release_asset_identity(r) -> dict:
    cfg = r.cfg
    tag = cfg["release_tag"]
    version = tag.lstrip("v")
    d = r.work / "release-assets"
    d.mkdir(parents=True, exist_ok=True)
    names = ["checksums.txt", "checksums.txt.sig", "pearl-release.json", "pearl-release.json.sig",
             f"macprovider-cli-{tag}-darwin-arm64.tar.gz", f"Malibu-{tag}.dmg"]
    for name in names:
        _download(tag, name, d)
    sums = _checksums(d / "checksums.txt")
    sub, details = {}, {}
    for name in names[4:]:
        sub[f"checksum_matches.{name}"] = sums.get(name) == sha256_file(d / name)
    pem = r.source / "ops/pearl-updater/release-signing-public.pem"
    v = run(["openssl", "dgst", "-sha256", "-verify", str(pem), "-signature", str(d / "pearl-release.json.sig"),
             str(d / "pearl-release.json")])
    sub["pearl_release_signature_verified"] = v.returncode == 0 and "Verified OK" in v.stdout
    cli_dir = d / "cli-check"
    cli_dir.mkdir(exist_ok=True)
    with tarfile.open(d / f"macprovider-cli-{tag}-darwin-arm64.tar.gz") as tf:
        member = tf.getmember("macprovider-cli")
        tf.extract(member, cli_dir)
    tar_cli = cli_dir / "macprovider-cli"
    tar_sha = sha256_file(tar_cli)
    cs = run(["codesign", "-d", "--arch", "arm64", "-vvv", str(tar_cli)]).stderr
    ident = json.loads((d / "pearl-release.json").read_text()).get("provider_code_identity", {})
    cd = re.search(r"^CDHash=(\S+)", cs, re.M)
    team = re.search(r"^TeamIdentifier=(\S+)", cs, re.M)
    ident_id = re.search(r"^Identifier=(\S+)", cs, re.M)
    slices = ident.get("slices") or [{}]
    sub["code_identity.binary_sha256"] = ident.get("binary_sha256") == tar_sha
    sub["code_identity.cdhash"] = bool(cd) and slices[0].get("code_cdhash") == cd.group(1)
    sub["code_identity.team_id"] = bool(team) and ident.get("team_id") == team.group(1)
    sub["code_identity.signing_identifier"] = bool(ident_id) and ident.get("signing_identifier") == ident_id.group(1)
    sub["tarball_cli_equals_lab_host_signed_copy"] = tar_sha == cfg["expected_signed_sha256"]
    verify = run(["bash", str(r.source / "scripts/verify-malibu-release-artifacts.sh"), str(d / f"Malibu-{tag}.dmg"),
                  "--provider-tarball", str(d / f"macprovider-cli-{tag}-darwin-arm64.tar.gz")],
                 timeout=1800, log=r.logs / "verify-malibu-release-artifacts.log")
    sub["verify_malibu_release_artifacts_script_passed"] = verify.returncode == 0
    # Independent recomputation: the embedded CLI inside the DMG's Malibu.app.
    mnt = d / "mnt"
    mnt.mkdir(exist_ok=True)
    app_sha = None
    att = run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mnt), str(d / f"Malibu-{tag}.dmg")], timeout=300)
    try:
        if att.returncode == 0:
            hits = [p for p in mnt.rglob("macprovider-cli") if p.is_file() and not p.is_symlink()]
            details["app_embedded_cli_paths"] = [str(p.relative_to(mnt)) for p in hits]
            if hits:
                app_sha = sha256_file(hits[0])
    finally:
        run(["hdiutil", "detach", str(mnt)], timeout=120)
    sub["app_embedded_cli_equals_tarball_cli"] = app_sha is not None and app_sha == tar_sha
    details.update({"tarball_cli_sha256": tar_sha, "app_embedded_cli_sha256": app_sha,
                    "cdhash": cd.group(1) if cd else None, "provider_code_identity": ident,
                    "checksums": {k: sums.get(k) for k in names[4:]}})
    r.keep(r.logs / "verify-malibu-release-artifacts.log", "verify-malibu-release-artifacts.log")
    (r.evidence / "records").mkdir(exist_ok=True)
    (r.evidence / "records/release-asset-identity.json").write_text(json.dumps({"sub": sub, "details": details}, indent=2, sort_keys=True) + "\n")
    ok = all(sub.values())
    r.record("item8-release-asset-identity", PASS if ok else FAIL,
             f"published {tag}: Malibu.app-embedded CLI and tarball CLI are byte-identical ({tar_sha[:12]}…), "
             "signed code identity matches, checksums match" if ok else "release asset identity check failed",
             evidence=["records/release-asset-identity.json", "raw/verify-malibu-release-artifacts.log"], sub=sub,
             binary=f"published {tag} assets")
    return {"sub": sub, "details": details}


def _latest_transport() -> dict:
    """Newest release-discovery-v1-<sequence> transport and its signed target."""
    api = "https://api.github.com/repos/Augustas11/macprovider/releases?per_page=100"
    with urllib.request.urlopen(urllib.request.Request(api, headers={"Accept": "application/vnd.github+json"}), timeout=60) as resp:
        releases = json.loads(resp.read())
    transports = [x for x in releases if re.match(r"^release-discovery-v1-\d+$", x.get("tag_name", ""))]
    if not transports:
        return {}
    top = max(transports, key=lambda x: int(x["tag_name"].rsplit("-", 1)[1]))
    asset = next(a for a in top["assets"] if a["name"] == "macprovider-release-discovery.json")
    with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as resp:
        signed = json.loads(resp.read()).get("signed", {})
    return {"tag": top["tag_name"], "created_at": top.get("created_at"),
            "target_compatibility_set_id": signed.get("target_compatibility_set_id"),
            "issued_at": signed.get("issued_at"), "expires_at": signed.get("expires_at")}


SANDBOX = """(version 1)
(allow default)
(deny process-exec (literal "/bin/launchctl"))
(deny process-exec (literal "/usr/bin/sudo"))
{denies}
"""


def updater_path(r) -> dict:
    cfg = r.cfg
    prev = cfg["previous_tag"]
    tag = cfg["release_tag"]
    u = r.work / "updater"
    if u.exists():
        shutil.rmtree(u)
    home = u / "home"
    (home / "macprovider").mkdir(parents=True)
    (home / ".config/macprovider").mkdir(parents=True)
    (u / "tmp").mkdir()
    dl = r.work / "release-assets"
    dl.mkdir(parents=True, exist_ok=True)
    tarball = _download(prev, f"macprovider-cli-{prev}-darwin-arm64.tar.gz", dl)
    sub, details = {}, {}
    with tarfile.open(tarball) as tf:
        tf.extractall(home / "macprovider")
    prev_cli = home / "macprovider/macprovider-cli"
    details["previous_cli_sha256"] = sha256_file(prev_cli)
    details["previous_cli_version"] = run([str(prev_cli), "--version"]).stdout.strip()
    sub["previous_cli_is_previous_stable"] = details["previous_cli_version"] == prev.lstrip("v")
    # Keychain credential store (the mutating updater refuses protected_file
    # by design); no token is configured, the coordinator URL is an unused
    # loopback port, so nothing can join anything.
    (home / ".config/macprovider/config.yaml").write_text(
        f"model: {cfg['model_artifact_path']}\nport: {cfg['updater_port']}\n"
        f"coordinator_url: ws://127.0.0.1:{cfg['updater_port']}/ws/provider\nauto_update_enabled: false\n")
    denies = "\n".join(f'(deny file-write* (subpath "{p}"))' for p in cfg["updater_write_denied_paths"])
    (u / "sandbox.sb").write_text(SANDBOX.format(denies=denies))
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CFFIXED_USER_HOME": str(home), "HOME": str(home),
           "TMPDIR": str(u / "tmp") + "/", "MACPROVIDER_CONFIG": str(home / ".config/macprovider/config.yaml"),
           "MACPROVIDER_LIFECYCLE_ROOT": str(home / "lifecycle"), "MACPROVIDER_CTL_SOCKET_PATH": str(u / "tmp/ctl.sock"),
           "MACPROVIDER_AUTO_UPDATE_ENABLED": "false"}
    sb = ["sandbox-exec", "-f", str(u / "sandbox.sb")]
    check = run(sb + [str(prev_cli), "update", "--check"], env=env, timeout=600, log=r.logs / "updater-check.log")
    sub["update_check_offers_release"] = check.returncode == 0 and f"-> {tag}" in check.stdout
    details["check_stdout"] = check.stdout.strip()[-400:]
    if "Already up to date" in check.stdout:
        # The updater follows the newest signed discovery transport, not the
        # GitHub "latest" flag. Record which release the transport offers.
        details["discovery_transport"] = _latest_transport()
        sub["signed_discovery_transport_offers_release"] = (
            details["discovery_transport"].get("target_compatibility_set_id", "").split(":")[-1].startswith(tag + "@"))
        new_sha = new_version = None
        installed = home / "macprovider/macprovider-cli"
        sub["installed_cli_is_published_release_bytes"] = False
    else:
        apply = run(sb + [str(prev_cli), "update"], env=env, timeout=1800, log=r.logs / "updater-apply.log")
        details["apply_exit"] = apply.returncode
        installed = home / "macprovider/macprovider-cli"
        new_sha = sha256_file(installed) if installed.exists() else None
        new_version = run([str(installed), "--version"]).stdout.strip() if installed.exists() else None
        sub["update_apply_exit_zero"] = apply.returncode == 0
        sub["installed_cli_is_published_release_bytes"] = new_sha == cfg["expected_signed_sha256"]
        sub["installed_cli_version_is_release"] = new_version == tag.lstrip("v")
        sub["no_embedded_cli_mismatch"] = "embedded_cli_mismatch" not in (apply.stdout + apply.stderr)
    details.update({"installed_cli_sha256": new_sha, "installed_cli_version": new_version})
    status = run(sb + [str(installed), "status", "--advanced"], env=env, timeout=120,
                 log=r.logs / "updater-status.log") if new_sha else None
    details["post_update_status_exit"] = status.returncode if status else None
    for name in ("updater-check.log", "updater-apply.log", "updater-status.log"):
        if (r.logs / name).exists():
            r.keep(r.logs / name, name)
    (r.evidence / "records").mkdir(exist_ok=True)
    (r.evidence / "records/updater-path.json").write_text(json.dumps({"sub": sub, "details": details}, indent=2, sort_keys=True) + "\n")
    ok = all(sub.values())
    r.record("item8-updater-path", PASS if ok else FAIL,
             f"{prev} updater, in an isolated home under a launchctl-denying sandbox, discovered and installed "
             f"{tag} from the public signed feed; installed bytes equal the published CLI" if ok else
             (f"{prev} updater reports it is up to date: the newest signed discovery transport "
              f"({details.get('discovery_transport', {}).get('tag')}) still targets "
              f"{details.get('discovery_transport', {}).get('target_compatibility_set_id', '?').split(':')[-1]}, so {tag} is "
              "not offered to the previous stable until the post-publication rollout publishes its transport")
             if "discovery_transport" in details else f"{prev} -> {tag} isolated updater path did not complete (see updater-apply.log)",
             evidence=["records/updater-path.json", "raw/updater-check.log", "raw/updater-apply.log"], sub=sub,
             details=details, binary=f"published {prev} -> {tag}")
    return {"sub": sub, "details": details}
