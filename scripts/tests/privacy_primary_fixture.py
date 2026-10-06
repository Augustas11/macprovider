"""Synthetic frozen-run fixtures for the privacy-class beta primary-evidence path.

`build_raw()` writes a raw run directory (db/, logs/, evidence/, needles, kit
script) shaped like the #1839 run: the SQLite tables use the cab10eabb column
names (plus the #1851 gateway columns the run kit queried), the logs use the
coordinator's zerolog JSON in -07:00 local time, and every row is consistent
with the committed reviewed bundle's step windows and request ids. Nothing
here is real run data.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import json
import os
import secrets
import shutil
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import privacy_class_beta_journey_evidence as contract

SEED = bytes(range(32))
LOCAL = timezone(timedelta(hours=-7))


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def results(bundle: Path) -> dict[str, int]:
    rows = {}
    for line in (bundle / "results.tsv").read_text().splitlines():
        stamp, step = line.split("\t")[:2]
        rows[step] = int(datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    return rows


def local_time(unix: int) -> str:
    return datetime.fromtimestamp(unix, LOCAL).isoformat()


def utc_text(unix: int) -> str:
    return datetime.fromtimestamp(unix, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rewrite_identity(bundle: Path) -> bytes:
    """Point identity-privacy.json at the fixture's Ed25519 identity key."""
    public, _ = contract.ed25519_sign(SEED, b"")
    path = bundle / "step-01b-isolated-stack/identity-privacy.json"
    doc = json.loads(path.read_text())
    doc["relay_blind_identity_public_key"] = b64url(public)
    path.write_text(json.dumps(doc, separators=(",", ":")))
    return public


def create(db: sqlite3.Connection, table: str, columns: list[str], rows: list[dict]) -> None:
    db.execute(f'CREATE TABLE "{table}" ({", ".join(columns)})')
    names = [column.split()[0] for column in columns]
    for row in rows:
        db.execute(
            f'INSERT INTO "{table}" ({", ".join(names)}) VALUES ({", ".join("?" for _ in names)})',
            [row.get(name) for name in names],
        )


def build_raw(raw: Path, bundle: Path, *, needles: dict[str, str] | None = None) -> dict:
    """Write a synthetic frozen run under `raw`; return the facts tests mutate."""
    t = results(bundle)
    (raw / "db").mkdir(parents=True)
    (raw / "logs").mkdir()
    shutil.copytree(bundle, raw / "evidence", ignore=shutil.ignore_patterns("primary"))
    privacy, plain = "journey-1839-privacy", "journey-1839-plain"
    identity = json.loads((bundle / "step-01b-isolated-stack/identity-privacy.json").read_text())
    binding = contract.Checks(contract.Bundle("x", {"step-01-bind-signed-release/binding.txt": (bundle / "step-01-bind-signed-release/binding.txt").read_bytes()}, b"")).binding()
    start = int(contract.parse_fields((bundle / "step-02-privacy-mode-start/timing.txt").read_text(), "timing")["provider_start_unix"])

    reservations, verdicts, outputs, outbox, snapshots, credits, quotas, usage, proxy = [], [], [], [], [], [], [], [], []
    facts: dict = {"enforce": [], "cases": {}}

    def reservation(created: int, *, privacy_class: int, provider: str, stream: int, dispatched: bool = True, state: str = "terminal", terminal_code: str | None = None, request_id: str | None = None) -> dict:
        request = request_id or f"irid-{len(reservations):03d}-{secrets.token_hex(4)}"
        envelope = secrets.token_bytes(32)
        row = {
            "provider_binding": secrets.token_hex(16), "buyer_binding": secrets.token_hex(16), "account_id": "acct-journey-1839-buyer",
            "wallet_session": "", "provider_id": provider, "assigned_session": "sess-" + provider, "key_record_digest": b64url(secrets.token_bytes(32)),
            "kid": "kid", "model": "mlx-community/Llama-3.2-3B-Instruct-4bit", "provider_model": "m", "stream": stream,
            "max_encrypted_request_bytes": 4096, "max_output_tokens": 64, "input_token_upper_bound": 512, "reservation_token_cap": 576,
            "expires_at_unix": created + 300, "state": state, "envelope_digest": b64url(envelope), "execution_auth_digest": b64url(secrets.token_bytes(32)),
            "request_id": "buyer-" + request, "validated_input_tokens": 40, "effective_privacy_outcome": "privacy_class" if privacy_class else "relay_blind",
            "terminal_code": terminal_code, "internal_request_id": request, "completion_tokens": 8, "created_at_unix": created,
            "consumed_at_unix": created, "dispatched_at_unix": created + 1 if dispatched else None, "validated_at_unix": created + 1 if dispatched else None,
            "terminal_at_unix": created + 2, "privacy_class": privacy_class,
        }
        reservations.append(row)
        return row

    def settle(row: dict, *, outcome: str = contract.RB_SETTLED, reason: str = "relay_blind_settlement", receipt_present: int = 1, version: str | None = contract.RB_PROFILE, mode: str = "observe", tokens: tuple[int, int] = (40, 8), payable: bool = True, gateway_status: str = "settled", chat: bool = True) -> None:
        request, created = row["internal_request_id"], row["created_at_unix"]
        prompt_hash = contract.b64url_hex(row["envelope_digest"])
        canonical = json.dumps({"request_id": request, "prompt_hash": prompt_hash, "mode": mode}, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(canonical.encode()).hexdigest()
        snapshots.append({
            "id": len(snapshots) + 1, "account_scope": "acct", "request_id": request, "attempt_n": 0, "provider_id": row["provider_id"],
            "paid_entrypoint": contract.RB_ENTRYPOINT, "prompt_hash_basis": contract.RB_BASIS, "prompt_hash": prompt_hash,
            "route_snapshot_mode": mode, "route_decision_ts_unix_ms": created * 1000 + 100, "route_snapshot_digest": digest,
            "route_snapshot_json": canonical, "route_snapshot_canonical_json": canonical, "created_at_utc": utc_text(created),
        })
        output_hash = hashlib.sha256(secrets.token_bytes(16)).hexdigest()
        verdict_id = len(verdicts) + 1
        verdicts.append({
            "id": verdict_id, "account_scope_hash": "0" * 64, "request_id": request, "attempt_n": 0, "provider_id": row["provider_id"],
            "receipt_present": receipt_present, "receipt_version": version, "receipt_result": "valid" if outcome == contract.RB_SETTLED else "invalid",
            "settlement_outcome": outcome, "reason": reason, "closed": 1, "terminal_state": "normal_done", "received_at_unix_ms": (created + 2) * 1000,
            "route_snapshot_digest": digest, "route_snapshot_mode": mode, "paid_entrypoint": contract.RB_ENTRYPOINT,
            "receipt_profile": contract.RB_PROFILE, "prompt_hash": prompt_hash, "output_hash": output_hash if receipt_present else None,
            "checks_json": "{}", "verifier_diagnostics_json": "{}",
            "facts_json": json.dumps({"output_hash": output_hash, "output_prefix_end_byte": 512}) if receipt_present else None,
            "created_at_utc": utc_text(created + 2),
        })
        outputs.append({
            "id": len(outputs) + 1, "account_scope": "acct", "request_id": request, "attempt_n": 0, "provider_id": row["provider_id"],
            "terminal_state": "normal_done", "terminal_state_ts_unix_ms": (created + 2) * 1000, "output_available": 1,
            "output_prefix_start_byte": 0, "output_prefix_end_byte": 512, "output_hash": output_hash, "settlement_output_canonical_json": "",
            "usage_hash": "1" * 64, "usage_canonical_json": "{}", "usage_source": "coordinator_observed", "created_at_utc": utc_text(created + 2),
        })
        outbox.append({"id": len(outbox) + 1, "settlement_receipt_verdict_id": verdict_id, "request_id": request, "receipt_version": version, "event_type": "settlement_receipt_verdict"})
        prompt, completion = tokens
        if payable:
            credits.append({"id": len(credits) + 1, "request_id": request, "provider_id": row["provider_id"], "prompt_tokens": prompt, "charged_prompt_tokens": prompt, "completion_tokens": completion, "provider_credits": 2, "settlement_policy_mode": mode})
        quotas.append({
            "account_id": "acct-journey-1839-buyer", "request_id": "gw-" + request, "window_date": "2026-10-06", "reserved_tokens": 576,
            "settled_tokens": prompt + completion if gateway_status == "settled" else 0, "status": gateway_status, "created_at": utc_text(created),
            "relay_blind_envelope_digest": row["envelope_digest"], "relay_blind_internal_request_id": request, "relay_blind_settlement_mode": mode,
            "api_key_hash": "secret-hash-" + secrets.token_hex(8),
        })
        if gateway_status == "settled":
            usage.append({"request_id": "gw-" + request, "account_id": "acct-journey-1839-buyer", "prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion, "token_source": "coordinator_observed", "created_at": utc_text(created + 2)})
        if chat:
            proxy.append({
                "at_unix": created + 2, "mode": "observe", "method": "POST", "path": "/v1/chat/completions", "status": 200, "error_code": "",
                "response_macprovider_headers": {}, "body_len": 900, "mutated": False,
                "usage_macprovider_privacy": {"posture_verified_at_unix": created} if row["privacy_class"] else None,
                "request_envelope_sha256": prompt_hash, "response_body_sha256": hashlib.sha256(secrets.token_bytes(8)).hexdigest(),
            })

    # Steps 02, 03 probes and the step-07/08 canaries (privacy, dispatched by step-09).
    for created, stream in ((start + 10, 0), (t["step-02-privacy-mode-start"] + 20, 0), (t["step-04-core-dump-and-env-refused"] + 1, 1), (t["step-04-core-dump-and-env-refused"] + 2, 0)):
        settle(reservation(created, privacy_class=1, provider=privacy, stream=stream))
    # A plaintext v0.4 verified verdict before the enforce canary.
    verdicts.append({"id": len(verdicts) + 1, "request_id": "plaintext-1", "provider_id": plain, "settlement_outcome": "verified", "closed": 1, "receipt_result": "valid", "received_at_unix_ms": (t["step-12-kill-switch"] - 5) * 1000})
    # Step-12 held privacy reservation, rejected predispatch and refunded.
    held = reservation(t["step-11-stale-posture-and-quarantine"] + 4, privacy_class=1, provider=privacy, stream=0, dispatched=False, state="rejected", terminal_code="privacy_class_disabled")
    quotas.append({"account_id": "acct-journey-1839-buyer", "request_id": "gw-held", "window_date": "2026-10-06", "reserved_tokens": 576, "settled_tokens": 0, "status": "refunded", "created_at": utc_text(held["created_at_unix"]), "relay_blind_envelope_digest": held["envelope_digest"], "relay_blind_internal_request_id": "", "relay_blind_settlement_mode": "enforce", "api_key_hash": "x"})
    facts["held"] = held
    # Step-13 enforce canary: two privacy and one plain relay-blind.
    for offset, privacy_class, provider, stream, tokens in ((5, 1, privacy, 1, (85, 23)), (10, 1, privacy, 0, (85, 8)), (15, 0, plain, 0, (42, 2))):
        row = reservation(t["step-12-kill-switch"] + offset, privacy_class=privacy_class, provider=provider, stream=stream)
        settle(row, mode="enforce", tokens=tokens)
        facts["enforce"].append(row)
    # Step-15 quarantine cases from the bundle's cases.tsv.
    base15 = t["step-14-no-capability-provider-excluded"]
    for index, line in enumerate((bundle / "step-15-tampered-receipt-quarantined/cases.tsv").read_text().splitlines()):
        name, request, _ = line.split("\t")
        privacy_class = 1 if name.startswith("ws-") else 0
        row = reservation(base15 + 30 + index * 30, privacy_class=privacy_class, provider=privacy if privacy_class else plain, stream=0, request_id=request)
        reason = contract.QUARANTINE_CASES[name]
        present = 0 if "missing" in reason else 1
        settle(row, outcome="quarantined", reason=reason, receipt_present=present, version=("4" if name == "fault-v04" else (contract.RB_PROFILE if present else None)), mode="enforce", payable=False, gateway_status="refunded", chat=False)
        facts["cases"][name] = row

    # Key records: one attested privacy key for step-02, plain relay-blind keys.
    public, _ = contract.ed25519_sign(SEED, b"")
    nb = start + 5
    record_digest = b64url(secrets.token_bytes(32))
    record = {"alg": "x25519", "public_key": b64url(secrets.token_bytes(32)), "identity_fingerprint": identity["relay_blind_fingerprint"], "models": ["m"], "max_encrypted_request_bytes": 4096, "endpoint_families": ["chat_completions"], "signature_algorithm": "ed25519", "not_before_unix": nb, "expires_at_unix": nb + 3600, "kid": "kid-privacy-1", "key_record_digest": record_digest, "signature": b64url(b"\0" * 64)}
    attestation = {"version": "privacy-key-attestation-v1", "key_record_digest": record_digest, "privacy_class": contract.PRIVACY_CLASS, "assurance": contract.PRIVACY_ASSURANCE, "binary_version": binding["binary_version"], "code_cdhash": binding["code_cdhash"], "not_before_unix": nb, "expires_at_unix": nb + 3600}
    _, signature = contract.ed25519_sign(SEED, contract.attestation_framing(attestation))
    keys = [
        {"provider_id": privacy, "kid": "kid-privacy-1", "assigned_session": "s", "record_json": json.dumps(record).encode(), "key_record_digest": record_digest, "immutable_digest": "d", "not_before_unix": nb, "expires_at_unix": nb + 3600, "accepted_at_unix": nb + 1, "revoked_at_unix": t["step-11-stale-posture-and-quarantine"] - 80, "key_class": "privacy", "privacy_attestation_json": json.dumps(attestation), "privacy_attestation_signature": b64url(signature)},
        {"provider_id": plain, "kid": "kid-plain-1", "assigned_session": "s", "record_json": json.dumps({"kid": "kid-plain-1"}).encode(), "key_record_digest": "p", "immutable_digest": "d", "not_before_unix": nb, "expires_at_unix": nb + 86400, "accepted_at_unix": nb, "revoked_at_unix": None, "key_class": "relay_blind", "privacy_attestation_json": None, "privacy_attestation_signature": None},
    ]
    facts.update(public=public, attestation=attestation)

    rb_columns = [f"{name}" for name in reservations[0]]
    with contextlib.closing(sqlite3.connect(raw / "db" / "relay-blind.db")) as db, db:
        create(db, "relay_blind_reservations", rb_columns, reservations)
        create(db, "relay_blind_key_records", list(keys[0]), keys)
        create(db, "privacy_class_quarantine", ["provider_id", "reason", "quarantined_at_unix", "expires_at_unix"], [])
        create(db, "privacy_class_control", ["id", "disabled", "reason", "updated_at_unix"], [{"id": 1, "disabled": 0, "reason": "enabled", "updated_at_unix": t["step-12-kill-switch"] - 5}])
        create(db, "relay_blind_replay", ["request_id", "seen_at_unix"], [])
    verdict_columns = sorted({key for row in verdicts for key in row})
    with contextlib.closing(sqlite3.connect(raw / "db" / "coordinator.db")) as db, db:
        create(db, "settlement_route_snapshots", list(snapshots[0]), snapshots)
        create(db, "settlement_receipt_verdicts", verdict_columns, verdicts)
        create(db, "settlement_attempt_outputs", list(outputs[0]), outputs)
        create(db, "settlement_receipt_audit_outbox", list(outbox[0]), outbox)
        create(db, "ledger_request_credits", list(credits[0]), credits)
        create(db, "spec022_payable_request_credits", list(credits[0]), credits)
        create(db, "referral_serving_qualifications", ["id", "account_id", "created_at"], [])
        create(db, "provider_rewards", ["id", "provider_id", "amount", "created_at_utc"], [])
        create(db, "provider_tokens", ["id", "token_hash", "token_prefix", "provider_id"], [{"id": 1, "token_hash": "h" * 40, "token_prefix": "pt", "provider_id": privacy}])
    with contextlib.closing(sqlite3.connect(raw / "db" / "gateway.db")) as db, db:
        create(db, "quota_reservations", list(quotas[0]), quotas)
        create(db, "usage_events", list(usage[0]), usage)
    with contextlib.closing(sqlite3.connect(raw / "db" / "provider_connection_events.db")) as db, db:
        create(db, "provider_connection_events", ["id", "provider_id", "occurred_at_utc", "kind", "outcome", "diagnostic"], [
            {"id": 1, "provider_id": privacy, "occurred_at_utc": utc_text(start + 3), "kind": "connect", "outcome": "accepted", "diagnostic": "dial /Users/a1/journey-1839/state ok"},
        ])
    with contextlib.closing(sqlite3.connect(raw / "db" / "coordinator-audit.db")) as db, db:
        create(db, "settlement_receipt_audit_events", ["id", "request_id"], [])
    (raw / "db" / "coordinator.db.route-snapshots").write_bytes(b"")

    events = [
        {"time": local_time(start + 3), "level": "info", "provider_id": privacy, "reason": "coordinator auth_response accepted", "message": "provider session"},
        {"time": local_time(t["step-11-stale-posture-and-quarantine"] - 60), "level": "warn", "provider_id": privacy, "message": "privacy posture: response timed out"},
        {"time": local_time(base15 + 20), "level": "info", "provider_id": plain, "reason": "coordinator auth_response accepted", "message": "provider session"},
        {"time": local_time(start + 4), "level": "info", "message": "unrelated routine line", "provider_id": privacy},
    ]
    (raw / "logs" / "coordinator.log").write_text("".join(json.dumps(event) + "\n" for event in events))
    (raw / "logs" / "gateway.log").write_text(json.dumps({"time": local_time(start), "level": "info", "message": "privacy class enabled"}) + "\n")
    (raw / "logs" / "provider-privacy.log").write_text("malibu-cli config\n  coordinator_url: ws://127.0.0.1:19302/ws/provider\n  config: /Users/a1/journey-1839/provider/privacy/config.yaml\n")
    (raw / "logs" / "provider-plain.log").write_text("malibu-cli config\n  coordinator_url: ws://127.0.0.1:19302/ws/provider\nmalibu-cli config\n  coordinator_url: ws://127.0.0.1:19302/ws/provider\n")
    (raw / "logs" / "provider-old.log").write_text("malibu-cli config\n  coordinator_url: ws://127.0.0.1:19302/ws/provider\n")
    (raw / "logs" / "unified-provider-96156.log").write_text(
        f"{datetime.fromtimestamp(start, LOCAL).strftime('%Y-%m-%d %H:%M:%S')}.100 Df macprovider-cli[96156:1a2b] [com.apple.network:connection] nw_connection 127.0.0.1:19302 ready\n"
    )
    (raw / "logs" / "proxy-events.jsonl").write_text("".join(json.dumps(event) + "\n" for event in proxy))
    (raw / "logs" / "wsproxy-events.jsonl").write_text(json.dumps({"conn": 1, "event": "mutated", "mode": "corrupt-end", "at_unix": base15 + 30}) + "\n")
    (raw / "logs" / "blackhole.log").write_text("")

    values = needles or {}
    for klass in sorted(contract.REVIEW_NEEDLE_CLASSES):
        values.setdefault(klass, f"NEEDLE-{klass}-{secrets.token_hex(12)}")
    needles_path = raw.parent / "needles.tsv"
    needles_path.write_text("".join(f"{klass}\t{text}\n" for klass, text in sorted(values.items())))
    kit = raw.parent / "run-journey.sh"
    kit.write_text(
        '  with_timeout 30 "${envs[@]}" DYLD_INSERT_LIBRARIES=/nonexistent/journey-1839-inject.dylib DYLD_PRINT_LIBRARIES=1 \\\n'
        '    "$b" --version >"$s/env-dyld/stdout.txt" 2>"$s/env-dyld/stderr.txt"; local drc=$?\n'
    )
    captured = t["step-00a-isolation-preflight"]
    os.utime(kit, (captured - 120, captured - 120))
    facts.update(needles=values, needles_path=needles_path, kit=kit)
    return facts


EXTRACTOR = Path(__file__).resolve().parents[1] / "lab" / "privacy-class-beta" / "extract-primary-evidence.py"


def remanifest(bundle_dir: Path) -> None:
    rows = []
    for path in sorted(bundle_dir.rglob("*"), key=lambda item: ("./" + item.relative_to(bundle_dir).as_posix()).encode()):
        relative = path.relative_to(bundle_dir).as_posix()
        if path.is_file() and relative != contract.MANIFEST_NAME:
            rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  ./{relative}\n")
    (bundle_dir / contract.MANIFEST_NAME).write_text("".join(rows), encoding="utf-8")


def attach_primary(bundle: Path, work: Path) -> dict:
    """Give a copy of the reviewed bundle synthetic primary/ exports via the real extractor."""
    import subprocess
    import sys

    rewrite_identity(bundle)
    facts = build_raw(work / "raw", bundle)
    completed = subprocess.run(
        [sys.executable, str(EXTRACTOR), "--raw", str(work / "raw"), "--out", str(work / "out"), "--needles", str(facts["needles_path"]), "--kit-script", str(facts["kit"])],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise AssertionError(completed.stderr)
    shutil.copytree(work / "out" / "primary", bundle / "primary")
    remanifest(bundle)
    return facts
