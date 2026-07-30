#!/usr/bin/env python3
"""Emit hash-only proof of Pearl's next deploy credential pairing."""

from __future__ import annotations

import hashlib
import hmac
import math
from pathlib import Path
import re
import subprocess
import sys


TOKEN = re.compile(r"[0-9a-fA-F]{64}")
PLACEHOLDER = re.compile(r"REPLACE|change-me|<required>|placeholder|xxx", re.I)
WEAK_DENYLIST = {"changeme", "placeholder", "test", "secret", "password", "admin"}
COORDINATOR_ENV = Path("/etc/macprovider/coordinator.env")
GATEWAY_ENV = Path("/etc/macprovider/gateway.env")
COORDINATOR_SERVICE = "macprovider-coordinator.service"
GATEWAY_SERVICE = "macprovider-gateway.service"


def entropy_bits_per_char(value: str) -> float:
    counts = {ch: value.count(ch) for ch in set(value)}
    total = len(value)
    return -sum((count / total) * math.log2(count / total) for count in counts.values())


def validate_credential(value: str | None, source: str) -> str:
    if value is None:
        raise ValueError(f"missing requested runtime credential in {source}")
    if PLACEHOLDER.search(value):
        raise ValueError(f"placeholder requested runtime credential in {source}")
    if not TOKEN.fullmatch(value):
        raise ValueError(f"invalid requested runtime credential in {source}: expected 64-hex")
    lowered = value.lower()
    if lowered in WEAK_DENYLIST:
        raise ValueError(f"weak requested runtime credential in {source}: denylisted")
    if all(ch == "0" for ch in value):
        raise ValueError(f"weak requested runtime credential in {source}: repeated_zero")
    if len(set(value)) == 1 or entropy_bits_per_char(value) < 3.5:
        raise ValueError(f"weak requested runtime credential in {source}: low_entropy")
    return value


def effective_env_value(path: Path, name: str) -> str:
    """Return systemd EnvironmentFile's effective value for one variable.

    The last assignment wins. Shell-only ``export`` syntax is rejected because
    systemd EnvironmentFile does not interpret the file as a shell script.
    """

    found: str | None = None
    with path.open(encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                raise ValueError(f"unsupported export syntax in {path}")
            key, sep, value = line.partition("=")
            if not sep or key.strip() != name:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            found = value
    return validate_credential(found, str(path))


def effective_process_env_value(environ: bytes, name: str, service: str) -> str:
    """Return the last matching value from a running process environment."""

    found: str | None = None
    for entry in environ.split(b"\0"):
        key, sep, value = entry.partition(b"=")
        if not sep:
            continue
        try:
            decoded_key = key.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if decoded_key == name:
            try:
                found = value.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise ValueError(f"invalid requested runtime credential encoding in {service}") from exc
    return validate_credential(found, service)


def service_main_pid(service: str) -> int:
    result = subprocess.run(
        ["systemctl", "show", "--property=MainPID", "--value", service],
        check=True,
        capture_output=True,
        text=True,
    )
    raw = result.stdout.strip()
    if not raw.isdigit() or int(raw) <= 1:
        raise ValueError(f"{service} has no running main process")
    return int(raw)


def running_service_env_values(service: str, names: tuple[str, ...]) -> tuple[str, ...]:
    """Read credentials from one stable running-process environment snapshot."""

    before = service_main_pid(service)
    environ = Path(f"/proc/{before}/environ").read_bytes()
    after = service_main_pid(service)
    if before != after:
        raise ValueError(f"{service} restarted during runtime credential proof")
    return tuple(effective_process_env_value(environ, name, service) for name in names)


def credential_digest(path: Path, name: str) -> str:
    if name == "-":
        return "-"
    value = effective_env_value(path, name)
    return hashlib.sha256(value.encode()).hexdigest()


def service_credential_digests(service: str, names: tuple[str, ...]) -> tuple[str, ...]:
    values = running_service_env_values(service, names)
    return tuple(hashlib.sha256(value.encode()).hexdigest() for value in values)


def require_process_env_names(mode: str, fields: tuple[tuple[str, str], ...]) -> None:
    for label, name in fields:
        if name == "-":
            raise ValueError(
                f"{mode} requires {label} to use env:NAME so the running peer can be attested"
            )


def require_peer_file_matches_process(label: str, file_digest: str, process_digest: str) -> None:
    """Refuse a deploy while the peer's env file and process have drifted."""

    if not hmac.compare_digest(file_digest, process_digest):
        raise ValueError(f"{label} differs between its EnvironmentFile and running process")


def deployment_digests(
    mode: str,
    coord_operator_name: str,
    coord_service_name: str,
    gateway_service_name: str,
    gateway_operator_name: str,
) -> tuple[str, str, str, str]:
    if mode == "coordinator-deploy":
        # The coordinator will restart and consume coordinator.env. The gateway
        # remains running. Require its file and process to agree so a peer
        # restart during this deploy cannot silently change the proven state.
        require_process_env_names(
            mode,
            (
                ("gateway coordinator.service_token", gateway_service_name),
                ("gateway coordinator.operator_key", gateway_operator_name),
            ),
        )
        gateway_service_file = credential_digest(GATEWAY_ENV, gateway_service_name)
        gateway_operator_file = credential_digest(GATEWAY_ENV, gateway_operator_name)
        gateway_service_process, gateway_operator_process = service_credential_digests(
            GATEWAY_SERVICE, (gateway_service_name, gateway_operator_name)
        )
        require_peer_file_matches_process(
            "gateway service credential", gateway_service_file, gateway_service_process
        )
        require_peer_file_matches_process(
            "gateway operator credential", gateway_operator_file, gateway_operator_process
        )
        return (
            credential_digest(COORDINATOR_ENV, coord_operator_name),
            credential_digest(COORDINATOR_ENV, coord_service_name),
            gateway_service_process,
            gateway_operator_process,
        )
    if mode == "gateway-deploy":
        # The gateway will restart and consume gateway.env. The coordinator
        # remains running. Require its file and process to agree so a peer
        # restart during this deploy cannot silently change the proven state.
        require_process_env_names(
            mode,
            (
                ("coordinator auth.operator_key", coord_operator_name),
                ("coordinator auth.gateway_service_token", coord_service_name),
            ),
        )
        coordinator_operator_file = credential_digest(COORDINATOR_ENV, coord_operator_name)
        coordinator_service_file = credential_digest(COORDINATOR_ENV, coord_service_name)
        coordinator_operator_process, coordinator_service_process = service_credential_digests(
            COORDINATOR_SERVICE, (coord_operator_name, coord_service_name)
        )
        require_peer_file_matches_process(
            "coordinator operator credential", coordinator_operator_file, coordinator_operator_process
        )
        require_peer_file_matches_process(
            "coordinator service credential", coordinator_service_file, coordinator_service_process
        )
        return (
            coordinator_operator_process,
            coordinator_service_process,
            credential_digest(GATEWAY_ENV, gateway_service_name),
            credential_digest(GATEWAY_ENV, gateway_operator_name),
        )
    raise ValueError("deployment mode must be coordinator-deploy or gateway-deploy")


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print(
            "usage: c2c_runtime_proof.py <coordinator-deploy|gateway-deploy> "
            "<coord-operator-env> <coord-service-env> <gateway-service-env> <gateway-operator-env>",
            file=sys.stderr,
        )
        return 2
    try:
        print(*deployment_digests(argv[1], argv[2], argv[3], argv[4], argv[5]))
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
