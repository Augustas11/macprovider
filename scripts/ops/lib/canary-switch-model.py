#!/usr/bin/env python3
"""Rewrite the canary provider's served-model identity block (canary-swap.sh switch-model).

Runs on the canary as the provider user, fed on stdin over STUDIO_SSH. The
caller has already checked the signed catalog row against the repo bytes and
`models verify-artifact`; this resolves the verified local snapshot path,
rewrites exactly the nine identity fields under the provider CLI's config lock,
validates the candidate with the installed CLI, keeps a timestamped backup and
replaces the config atomically. Every field must already be present once as a
single-line scalar: a config missing one is refused (never appended), because a
half-written block (model_catalog_key forgotten, 1.8.280) serves the wrong row.
Exit 0 ok (JSON on stdout); 3 refused, nothing changed.
"""
import base64
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

FIELDS = (
    "model",
    "model_artifact_path",
    "model_artifact_sha256",
    "model_catalog_key",
    "model_catalog_model_id",
    "model_catalog_revision",
    "model_catalog_sha256",
    "model_catalog_version",
    "model_catalog_hash",
)
PLAIN = re.compile(r"^[A-Za-z0-9._/@+-]+$")
TOP = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(?:[ \t](.*))?$")


class Refusal(Exception):
    pass


def owned_regular(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
            or info.st_mode & 0o022):
        raise Refusal("unsafe file: %s" % path)
    return info


@contextlib.contextmanager
def config_lock(config):
    # The provider CLI's own config lock (ConfigApplier / qwen-provider-transaction.py).
    fd = os.open(config.with_name(".%s.lock" % config.name), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise Refusal("unsafe config lock file")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def scalar_text(raw):
    value = raw.split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def top_level(text):
    lines = text.splitlines(keepends=True)
    found = {}
    for i, line in enumerate(lines):
        m = TOP.match(line.rstrip("\r\n"))
        if not m:
            continue
        key = m.group(1)
        if key in found:
            raise Refusal("duplicate top-level config key: %s" % key)
        found[key] = i
    return lines, found


def expand(redacted, override, root_value):
    home = Path.home()
    if redacted.startswith("<external>/"):
        if not override:
            raise Refusal("the verified snapshot lies outside the known model roots; pass --artifact-path")
        if Path(override).name != redacted.split("/", 1)[1]:
            raise Refusal("--artifact-path does not name the verified snapshot")
        path = Path(override)
    elif override:
        raise Refusal("--artifact-path applies only to a snapshot outside the known model roots")
    elif redacted.startswith("<hf_cache>/"):
        hf = os.environ.get("HF_HOME")
        path = (Path(hf) / "hub" if hf else home / ".cache/huggingface/hub") / redacted.split("/", 1)[1]
    elif redacted.startswith("<durable_store>/"):
        env_root = os.environ.get("MACPROVIDER_MODEL_ARTIFACT_ROOT", "")
        if root_value.startswith("/"):
            root = Path(root_value)
        elif env_root.startswith("/"):
            root = Path(env_root)
        else:
            root = home / "Library/Application Support/macprovider/models"
        path = root / redacted.split("/", 1)[1]
    elif redacted.startswith("~/"):
        path = home / redacted[2:]
    else:
        raise Refusal("unrecognized verified snapshot location")
    if not path.is_absolute() or ".." in path.parts or not path.is_dir():
        raise Refusal("verified snapshot directory not found on the canary")
    return str(path)


def render(value):
    if not isinstance(value, str) or not value or "\n" in value:
        raise Refusal("invalid identity value")
    return value if PLAIN.fullmatch(value) else json.dumps(value)


def apply(config, cli, request):
    owned_regular(config)
    owned_regular(cli)
    if not os.access(cli, os.X_OK):
        raise Refusal("installed CLI is not executable")
    with config_lock(config):
        info = owned_regular(config)
        raw = config.read_bytes()
        text = raw.decode("utf-8")
        lines, found = top_level(text)
        missing = [f for f in FIELDS if f not in found]
        if missing:
            raise Refusal("config lacks identity field(s) %s; nothing written" % ", ".join(missing))
        for f in FIELDS:
            i = found[f]
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if nxt[:1] in (" ", "\t") and nxt.strip():
                raise Refusal("config field %s is not a single-line scalar" % f)
        root_line = lines[found["model_artifact_root"]] if "model_artifact_root" in found else ""
        root_value = scalar_text(TOP.match(root_line.rstrip("\r\n")).group(2) or "") if root_line else ""
        values = dict(request["values"])
        values["model_artifact_path"] = expand(request["local_path"], request.get("artifact_path") or "", root_value)
        if set(values) != set(FIELDS):
            raise Refusal("identity values incomplete")
        previous = {f: scalar_text(TOP.match(lines[found[f]].rstrip("\r\n")).group(2) or "") for f in FIELDS}
        if previous == values:
            return {"changed": False, "previous_key": previous["model_catalog_key"],
                    "artifact_path": values["model_artifact_path"]}
        for f in FIELDS:
            ending = "\r\n" if lines[found[f]].endswith("\r\n") else "\n"
            lines[found[f]] = "%s: %s%s" % (f, render(values[f]), ending)
        candidate = "".join(lines).encode("utf-8")
        mode = stat.S_IMODE(info.st_mode)
        fd, tmp = tempfile.mkstemp(prefix=".%s.switch-model." % config.name, dir=config.parent)
        try:
            with os.fdopen(fd, "wb") as f:
                os.fchmod(f.fileno(), mode)
                f.write(candidate)
                f.flush()
                os.fsync(f.fileno())
            check = subprocess.run([str(cli), "models", "list", "--json", "--config", tmp],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=60, check=False)
            if check.returncode != 0:
                raise Refusal("installed CLI rejected the switched config; nothing written")
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup = config.with_name("%s.bak-switch-model-%s" % (config.name, stamp))
            bfd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
            with os.fdopen(bfd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, config)
            directory = os.open(config.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    return {"changed": True, "backup": str(backup), "previous_key": previous["model_catalog_key"],
            "artifact_path": values["model_artifact_path"]}


def main(argv):
    if len(argv) != 4 or argv[0] != "apply":
        print("usage: canary-switch-model.py apply CONFIG CLI REQUEST_BASE64", file=sys.stderr)
        return 2
    try:
        request = json.loads(base64.b64decode(argv[3], validate=True))
        print(json.dumps(apply(Path(argv[1]), Path(argv[2]), request)))
        return 0
    except Refusal as exc:
        print("switch-model refused on the canary: %s" % exc, file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
