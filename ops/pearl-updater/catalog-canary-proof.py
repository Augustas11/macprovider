#!/usr/bin/env python3
"""Emit a no-follow proof for one live catalog-aware macprovider installation.

This program is streamed over an already host-key-pinned SSH connection by the
Pearl updater. It intentionally accepts no credentials and performs only local,
read-only inspection on the selected canary Mac.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import urllib.request


CATALOG_FILES = (
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "rate-card.json",
    "rate-card.json.sig",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW


def fail(message: str) -> None:
    raise SystemExit(message)


def open_dir(path: str) -> int:
    if os.path.isabs(path):
        current = os.open("/", DIRECTORY_FLAGS)
        parts = [part for part in path.split("/") if part]
    else:
        current = os.open(os.path.expanduser("~"), DIRECTORY_FLAGS)
        parts = [part for part in path.split("/") if part]
    try:
        for part in parts:
            if part in {".", ".."}:
                fail(f"unsafe canary path component: {part}")
            next_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=current)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise


def read_regular_at(directory_fd: int, name: str, limit: int) -> bytes:
    descriptor = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=directory_fd)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            fail(f"unsafe canary file: {name}")
        if info.st_size > limit:
            fail(f"oversized canary file: {name}")
        chunks: list[bytes] = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > limit:
            fail(f"oversized canary file: {name}")
        return payload
    finally:
        os.close(descriptor)


def open_parent_and_name(path: str) -> tuple[int, str]:
    normalized = os.path.normpath(path)
    parent, name = os.path.split(normalized)
    if not name or name in {".", ".."}:
        fail(f"unsafe canary file path: {path}")
    return open_dir(parent or "."), name


def running_text_vnode_path(
    pid: int,
    binary_info: os.stat_result,
    expected_binary: str,
    runner=subprocess.run,
) -> str | None:
    fields = runner(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-F", "Dfin"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    ).stdout.splitlines()
    text_device = text_inode = None
    text_path = None
    for field in fields:
        if field.startswith("f"):
            text_device = text_inode = None
            text_path = None
        elif field.startswith("D"):
            try:
                text_device = int(field[1:], 0)
            except ValueError:
                fail("lsof returned an invalid text-vnode device")
        elif field.startswith("i"):
            try:
                text_inode = int(field[1:])
            except ValueError:
                fail("lsof returned an invalid text-vnode inode")
        elif field.startswith("n"):
            text_path = field[1:]
        normalized_text_path = (
            os.path.normpath(text_path.removesuffix(" (deleted)"))
            if text_path is not None
            else None
        )
        if (
            text_device == binary_info.st_dev
            and text_inode == binary_info.st_ino
            and normalized_text_path == expected_binary
        ):
            return normalized_text_path
    return None


def main() -> int:
    if len(sys.argv) != 7:
        fail("usage: catalog-canary-proof.py INSTALL_DIR PROVIDER_ID RELEASE_ID POLICY DIGEST SIGNER")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("this Mac cannot perform no-follow catalog proof")
    catalog_path, provider_id, release_id, policy_version, digest, signer = sys.argv[1:]
    home = os.path.expanduser("~")
    catalog_fd = open_dir(catalog_path)
    install_path = os.path.dirname(os.path.normpath(catalog_path)) or "."
    install_fd = open_dir(install_path)
    config_fd = provider_config_fd = binary_fd = None
    try:
        provider_config_fd = open_dir(".config/macprovider")
        installed_provider_id = read_regular_at(provider_config_fd, "provider_id", 1024).decode("utf-8").strip()
        if installed_provider_id != provider_id:
            fail("canary provider identity does not match the selected provider")

        plist_dir_fd = open_dir("Library/LaunchAgents")
        try:
            plist_bytes = read_regular_at(plist_dir_fd, "live.streamvc.macprovider.plist", 1024 * 1024)
        finally:
            os.close(plist_dir_fd)
        plist = plistlib.loads(plist_bytes)
        arguments = plist.get("ProgramArguments")
        if not isinstance(arguments, list) or len(arguments) < 4 or arguments[1:3] != ["serve", "--config"]:
            fail("canary provider LaunchAgent has unexpected ProgramArguments")

        binary_fd = os.open("macprovider-cli", os.O_RDONLY | NOFOLLOW, dir_fd=install_fd)
        binary_info = os.fstat(binary_fd)
        if not stat.S_ISREG(binary_info.st_mode) or binary_info.st_uid != os.getuid() or binary_info.st_mode & 0o111 == 0:
            fail("canary installation binary is not a safe executable")
        install_absolute = install_path if os.path.isabs(install_path) else os.path.join(home, install_path)
        expected_binary = os.path.normpath(os.path.join(install_absolute, "macprovider-cli"))
        if os.path.normpath(arguments[0]) != expected_binary:
            fail("canary LaunchAgent does not use the catalog installation root")

        launchd = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/live.streamvc.macprovider"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        ).stdout
        match = re.search(r"(?m)^\s*pid = ([0-9]+)\s*$", launchd)
        if match is None:
            fail("canary provider LaunchAgent has no live PID")
        pid = int(match.group(1))
        process_path = running_text_vnode_path(pid, binary_info, expected_binary)
        if process_path is None:
            fail("live canary provider text vnode is stale or not the verified installation binary")

        config_fd, config_name = open_parent_and_name(arguments[3])
        config_text = read_regular_at(config_fd, config_name, 1024 * 1024).decode("utf-8")
        port_match = re.search(r'(?m)^\s*port:\s*"?([0-9]+)"?\s*(?:#.*)?$', config_text)
        if port_match is None or not 1 <= int(port_match.group(1)) <= 65535:
            fail("canary provider config has no valid local status port")
        port = int(port_match.group(1))
        listener = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        if str(pid) not in listener.stdout.split():
            fail("live canary provider PID does not own its configured status port")

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, _request, _fp, _code, _message, _headers, _new_url):
                return None

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        status_url = f"http://127.0.0.1:{port}/v1/status"
        with opener.open(status_url, timeout=10) as response:
            if response.status != 200 or response.geturl() != status_url:
                fail("canary local status did not return an exact HTTP 200")
            status_payload = response.read(1024 * 1024 + 1)
        if len(status_payload) > 1024 * 1024:
            fail("canary local status exceeds the safety limit")
        local_status = json.loads(status_payload)
        catalog = local_status.get("catalog") if isinstance(local_status, dict) else None
        coordinator = local_status.get("coordinator") if isinstance(local_status, dict) else None
        assigned_id = coordinator.get("session") if isinstance(coordinator, dict) else None
        model_id = local_status.get("model") if isinstance(local_status, dict) else None
        catalog_key = catalog.get("catalog_key") if isinstance(catalog, dict) else None
        catalog_model_id = catalog.get("model_id") if isinstance(catalog, dict) else None
        if (
            not isinstance(local_status, dict)
            or local_status.get("provider_id") != provider_id
            or local_status.get("network_state") != "buyer_serving"
            or local_status.get("model_loaded") is not True
            or not isinstance(model_id, str)
            or not model_id
            or len(model_id) > 512
            or model_id.strip() != model_id
            or not isinstance(coordinator, dict)
            or coordinator.get("connected") is not True
            or not isinstance(assigned_id, str)
            or not assigned_id
            or not isinstance(catalog, dict)
            or catalog.get("release_id") != release_id
            or catalog.get("policy_version") != policy_version
            or catalog.get("digest") != digest
            or catalog.get("signer_key_id") != signer
            or re.fullmatch(r"[0-9a-f]{64}", str(catalog.get("row_identity", "")).lower()) is None
            or catalog_key != model_id
            or not isinstance(catalog_model_id, str)
            or not catalog_model_id
            or len(catalog_model_id) > 512
            or catalog_model_id.strip() != catalog_model_id
        ):
            fail("live canary status does not match the expected provider and catalog")

        hashes = {
            name: hashlib.sha256(read_regular_at(catalog_fd, name, 2 * 1024 * 1024)).hexdigest()
            for name in CATALOG_FILES
        }
        print(json.dumps({
            "provider_id": installed_provider_id,
            "assigned_id": assigned_id,
            "catalog_key": model_id,
            "model_id": catalog_model_id,
            "launchd_pid": pid,
            "executable_path": process_path,
            "local_status": local_status,
            "files": hashes,
        }, sort_keys=True))
        return 0
    finally:
        for descriptor in (config_fd, provider_config_fd, binary_fd, install_fd, catalog_fd):
            if descriptor is not None:
                os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
