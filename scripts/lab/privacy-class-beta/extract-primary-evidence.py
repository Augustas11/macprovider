#!/usr/bin/env python3
"""Post-hoc primary-evidence extractor for the #1839 JOURNEY-PRIVACY-CLASS-BETA run.

Usage:
  extract-primary-evidence.py --raw RAW_DIR --out OUT_DIR --needles NEEDLES.tsv \\
      [--needles MORE.tsv ...] [--kit-script run-journey.sh] \\
      [--home-prefix /Users/a1] [--log-utc-offset=-07:00]

RAW_DIR is the frozen run directory (db/, logs/, evidence/). Every SQLite file is
opened read-only with `file:...?immutable=1`; nothing under RAW_DIR is written.
OUT_DIR must not exist; the extractor writes OUT_DIR/primary/... and the
reviewer merges `primary/` into the reviewed bundle root.

Outputs (all JSON, UTF-8, one object per file):
  primary/db/inventory.json             every table/view of every DB with its row count
  primary/db/<db>/<table>.json          redacted raw rows of the settlement, reservation,
                                        key-record, quarantine, gateway quota/usage,
                                        connection-event, referral and reward tables
  primary/db/request-id-crossref.json   per table.column count of rows naming a
                                        privacy-class request id
  primary/logs/*.json                   bounded, field-allowlisted log events
  primary/procedure/dyld.json           the kit's DYLD invocation lines and script digest
  primary/sweep/salted-needle-digests.json  sha256(salt || needle form) per needle form
  primary/sweep/raw-files.json          per raw file: size, sha256, needle match count
  primary/summary.json                  counts, warnings, and what cannot be recovered

Never written: prompts, completions, ciphertext, private keys, tokens, buyer API
keys, token hashes, or the needles themselves. Before anything is kept, every
output is re-scanned for every needle (raw, JSON-escaped, UTF-16LE) and for home
paths; a hit deletes OUT_DIR and exits non-zero.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

SCHEMA = "macprovider.privacy-class-beta-primary.v1"
MAX_ROWS = 20000
MAX_TEXT = 4096
MAX_FREE_TEXT = 200
MAX_LOG_EVENTS = 50000

# Tables exported row by row (when present). Everything else is counted only.
ROW_TABLES = {
    "relay-blind.db": (
        "relay_blind_reservations",
        "relay_blind_key_records",
        "privacy_class_quarantine",
        "privacy_class_control",
    ),
    "coordinator.db": (
        "settlement_route_snapshots",
        "settlement_route_snapshot_journal",
        "settlement_receipt_verdicts",
        "settlement_attempt_outputs",
        "settlement_attempt_output_journal",
        "settlement_receipt_audit_outbox",
        "settlement_compute_integrity_captures",
        "ledger_request_credits",
        "ledger_quarantine_resolutions",
        "spec022_payable_request_credits",
        "referral_serving_qualifications",
    ),
    "coordinator.db.route-snapshots": (
        "settlement_route_snapshots",
        "settlement_route_snapshot_journal",
    ),
    "gateway.db": ("quota_reservations", "usage_events"),
    "provider_connection_events.db": ("provider_connection_events", "provider_last_known"),
}
# Verified-work reward, emission, unlock and referral tables in any DB.
REWARD_TABLE_RE = re.compile(r"(reward|emission|unlock|verified_work|referral_serving|referral_social_grants)", re.I)
# Column names that can carry a credential: dropped, never exported.
DROP_COLUMN_RE = re.compile(
    r"(^|_)(token|tokens_json|secret|password|passwd|api_key|apikey|key_hash|token_hash|token_prefix|authorization|bearer|private_key|seed)($|_)",
    re.I,
)
# Opaque reservation capabilities: exported as a digest only.
DIGEST_ONLY_COLUMN_RE = re.compile(r"(^|_)binding$", re.I)
# Columns that may hold response or prompt content: digest and length only.
CONTENT_COLUMNS = {
    "settlement_output_canonical_json",
    "body",
    "content",
    "prompt",
    "completion",
    "ciphertext",
    "plaintext",
    "envelope_json",
    "request_json",
    "response_json",
}
# Short free-text diagnostics: truncated.
FREE_TEXT_COLUMNS = {"diagnostic", "close_reason", "failure_reason", "last_materialize_error", "poison_reason", "poison_acknowledge_reason"}
DECODE_JSON_BLOB_COLUMNS = {"record_json"}

LOG_KEYS = {
    "time", "level", "message", "msg", "reason", "provider_id", "assigned_id", "session_id", "remote_addr",
    "request_id", "internal_request_id", "kid", "code", "error_code", "status", "path", "outcome", "state",
    "key_class", "close_code", "binary_version", "privacy_class", "quarantine_reason", "settlement_outcome",
}
COORDINATOR_LOG_RE = re.compile(r"privacy|posture|auth_response|quarantin|key record|disconnect", re.I)
GATEWAY_LOG_RE = re.compile(r"privacy|refund", re.I)
PROVIDER_LINE_RE = re.compile(
    r"^\s*(coordinator_url|provider_id|port|model|log_level|log_format):|^malibu-cli config$|coordinator|privacy|FATAL|WARN|session accepted|reconnect",
    re.I,
)
UNIFIED_LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\s+(?P<type>\S+)\s+(?P<proc>[^\[\s]+)\[(?P<pid>\d+):[0-9a-fx]+\]\s+(?:\[(?P<sub>[^\]]+)\]\s+)?(?P<msg>.*)$"
)
NETWORK_RE = re.compile(r"nw_|connection|socket|tcp|websocket|ws://|127\.0\.0\.1", re.I)
HOME_RE = re.compile(r"(?<![A-Za-z0-9_.>-])/(?:Users|home)/[^/\s\"'\\<>]+")
ESCAPED_HOME_RE = re.compile(r"(?<![A-Za-z0-9_.>-])\\/(?:Users|home)\\/[^\\\s\"'<>]+")


RAW_ROOT: pathlib.Path | None = None


def contained(path: pathlib.Path) -> bool:
    """A raw input must be a regular file under RAW_ROOT reached without symlinks."""
    if RAW_ROOT is None:
        return False
    try:
        relative = path.relative_to(RAW_ROOT)
    except ValueError:
        return False
    candidate = RAW_ROOT
    for part in relative.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            return False
    return path.is_file() and path.resolve().is_relative_to(RAW_ROOT)


def die(message: str) -> None:
    print(f"extract-primary-evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


class Redactor:
    def __init__(self, home_prefix: str) -> None:
        self.home = home_prefix.rstrip("/")
        self.escaped = self.home.replace("/", "\\/")

    def text(self, value: str) -> str:
        if self.home:
            value = value.replace(self.escaped, "<lab-home>").replace(self.home, "<lab-home>")
        value = ESCAPED_HOME_RE.sub("<home>", value)
        return HOME_RE.sub("<home>", value)

    def value(self, value):
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.value(item) for item in value]
        if isinstance(value, dict):
            return {self.text(str(key)): self.value(item) for key, item in value.items()}
        return value


def digest_only(data) -> dict:
    raw = data if isinstance(data, (bytes, bytearray)) else str(data).encode("utf-8")
    return {"omitted_sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}


def open_db(path: pathlib.Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?immutable=1", uri=True)


def table_names(db: sqlite3.Connection) -> list[tuple[str, str]]:
    return [(row[0], row[1]) for row in db.execute("SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")]


def export_cell(column: str, value, redactor: Redactor):
    lowered = column.lower()
    if value is None or isinstance(value, (int, float)):
        return value
    if lowered in CONTENT_COLUMNS:
        return digest_only(value) if value not in ("", b"") else ""
    if DIGEST_ONLY_COLUMN_RE.search(lowered):
        return {"sha256": hashlib.sha256(value if isinstance(value, bytes) else str(value).encode()).hexdigest()}
    if isinstance(value, (bytes, bytearray)):
        if lowered in DECODE_JSON_BLOB_COLUMNS:
            try:
                return redactor.value(json.loads(bytes(value).decode("utf-8")))
            except (UnicodeDecodeError, ValueError):
                pass
        return digest_only(value)
    text = str(value)
    if lowered in FREE_TEXT_COLUMNS:
        return redactor.text(text[:MAX_FREE_TEXT])
    if lowered.endswith("canonical_json"):
        # Exact bytes: a validator recomputes the stored digest over them.
        return text if len(text) <= 256 * MAX_TEXT and redactor.text(text) == text else digest_only(text)
    if lowered.endswith("_json") or lowered in DECODE_JSON_BLOB_COLUMNS:
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        if parsed is not None and len(text) <= 64 * MAX_TEXT:
            return redactor.value(parsed)
    if len(text) > MAX_TEXT:
        return digest_only(text)
    return redactor.text(text)


def export_table(db: sqlite3.Connection, table: str, redactor: Redactor) -> dict:
    cursor = db.execute(f'SELECT * FROM "{table}" LIMIT {MAX_ROWS + 1}')
    columns = [item[0] for item in cursor.description]
    kept = [column for column in columns if not DROP_COLUMN_RE.search(column)]
    dropped = [column for column in columns if column not in kept]
    rows = []
    for raw in cursor.fetchall():
        record = dict(zip(columns, raw))
        rows.append({column: export_cell(column, record[column], redactor) for column in kept})
    truncated = len(rows) > MAX_ROWS
    return {"table": table, "columns": kept, "dropped_columns": dropped, "row_count": len(rows[:MAX_ROWS]), "truncated": truncated, "rows": rows[:MAX_ROWS]}


def export_databases(raw: pathlib.Path, out: pathlib.Path, redactor: Redactor, warnings: list[str]) -> tuple[dict, set[str]]:
    inventory: dict[str, dict[str, int | str]] = {}
    privacy_ids: set[str] = set()
    db_dir = raw / "db"
    files = sorted(path for path in db_dir.iterdir() if contained(path) and not path.name.endswith(("-wal", "-shm", "-journal"))) if db_dir.is_dir() else []
    for path in sorted(db_dir.iterdir()) if db_dir.is_dir() else []:
        if path.is_symlink():
            warnings.append(f"db/{path.name}: symlink refused")
    for path in files:
        try:
            db = open_db(path)
            names = table_names(db)
        except sqlite3.Error as exc:
            warnings.append(f"{path.name}: not an SQLite database ({exc.__class__.__name__})")
            continue
        counts: dict[str, int | str] = {}
        for name, _kind in names:
            try:
                counts[name] = db.execute(f'SELECT COUNT(*) FROM "{name}"').fetchone()[0]
            except sqlite3.Error as exc:
                counts[name] = f"error:{exc.__class__.__name__}"
        inventory[path.name] = counts
        wanted = list(ROW_TABLES.get(path.name, ()))
        wanted += [name for name, _ in names if REWARD_TABLE_RE.search(name) and name not in wanted]
        for table in wanted:
            if table not in counts:
                continue
            try:
                exported = export_table(db, table, redactor)
            except sqlite3.Error as exc:
                warnings.append(f"{path.name}:{table}: export failed ({exc})")
                continue
            target = out / "db" / path.name / f"{table}.json"
            write_json(target, exported)
        if path.name == "relay-blind.db" and "relay_blind_reservations" in counts:
            for request_id, internal_id in db.execute(
                "SELECT request_id, internal_request_id FROM relay_blind_reservations WHERE privacy_class = 1"
            ):
                privacy_ids.update(value for value in (request_id, internal_id) if value)
        db.close()
    write_json(out / "db" / "inventory.json", {"schema_version": SCHEMA, "databases": inventory})
    return inventory, privacy_ids


def crossref(raw: pathlib.Path, out: pathlib.Path, privacy_ids: set[str], warnings: list[str]) -> None:
    hits: dict[str, int] = {}
    for path in sorted((raw / "db").iterdir()) if (raw / "db").is_dir() else []:
        if not contained(path) or path.name.endswith(("-wal", "-shm", "-journal")):
            continue
        try:
            db = open_db(path)
            names = [name for name, kind in table_names(db) if kind == "table"]
        except sqlite3.Error:
            continue
        for table in names:
            try:
                columns = [row[1] for row in db.execute(f'PRAGMA table_info("{table}")')]
            except sqlite3.Error:
                continue
            for column in columns:
                if "request_id" not in column.lower():
                    continue
                total = 0
                for chunk_start in range(0, len(privacy_ids), 500):
                    chunk = sorted(privacy_ids)[chunk_start : chunk_start + 500]
                    marks = ",".join("?" for _ in chunk)
                    try:
                        total += db.execute(f'SELECT COUNT(*) FROM "{table}" WHERE "{column}" IN ({marks})', chunk).fetchone()[0]
                    except sqlite3.Error as exc:
                        warnings.append(f"{path.name}:{table}.{column}: crossref failed ({exc})")
                        break
                if total:
                    hits[f"{path.name}:{table}.{column}"] = total
        db.close()
    write_json(out / "db" / "request-id-crossref.json", {"schema_version": SCHEMA, "privacy_request_ids": sorted(privacy_ids), "hits": hits})


def parse_local(ts: str, offset: timedelta) -> str | None:
    match = re.match(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$", ts.strip())
    if not match:
        return None
    base = datetime.strptime(f"{match.group(1)}T{match.group(2)}", "%Y-%m-%dT%H:%M:%S")
    zone = match.group(4)
    if zone in (None, ""):
        tz = timezone(offset)
    elif zone == "Z":
        tz = timezone.utc
    else:
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        tz = timezone(sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:])))
    frac = match.group(3) or ""
    micro = int((frac[1:] + "000000")[:6]) if frac else 0
    return base.replace(tzinfo=tz, microsecond=micro).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def json_log_events(path: pathlib.Path, pattern: re.Pattern[str], offset: timedelta, redactor: Redactor, warnings: list[str]) -> list[dict]:
    events: list[dict] = []
    if not contained(path):
        warnings.append(f"logs/{path.name}: absent or not a regular contained file")
        return events
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            text = " ".join(str(record.get(key, "")) for key in ("message", "msg", "reason", "error"))
            if not pattern.search(text):
                continue
            event = {"line": number}
            for key in sorted(LOG_KEYS & set(record)):
                value = record[key]
                if isinstance(value, (int, float, bool)) or value is None:
                    event[key] = value
                else:
                    event[key] = redactor.text(str(value)[:MAX_FREE_TEXT])
            if isinstance(record.get("time"), str):
                event["time_utc"] = parse_local(record["time"], offset)
            if isinstance(record.get("error"), str):
                event["error"] = redactor.text(record["error"][:MAX_FREE_TEXT])
            events.append(event)
            if len(events) >= MAX_LOG_EVENTS:
                warnings.append(f"logs/{path.name}: event cap reached")
                break
    return events


def provider_lines(path: pathlib.Path, redactor: Redactor) -> list[dict]:
    lines: list[dict] = []
    if not contained(path):
        return lines
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.rstrip("\n")
            if PROVIDER_LINE_RE.search(line):
                lines.append({"line": number, "text": redactor.text(line[:MAX_FREE_TEXT])})
    return lines


def unified_events(path: pathlib.Path, offset: timedelta, redactor: Redactor) -> dict:
    first = last = None
    network: list[dict] = []
    total = 0
    if contained(path):
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = UNIFIED_LINE_RE.match(line.rstrip("\n"))
                if not match:
                    continue
                total += 1
                stamp = parse_local(match.group("ts"), offset)
                first = first or stamp
                last = stamp
                if NETWORK_RE.search(match.group("msg")) or NETWORK_RE.search(match.group("sub") or ""):
                    network.append({
                        "time_utc": stamp,
                        "type": match.group("type"),
                        "pid": int(match.group("pid")),
                        "subsystem": redactor.text(match.group("sub") or ""),
                        "message": redactor.text(match.group("msg")[:MAX_FREE_TEXT]),
                    })
                    if len(network) >= 2000:
                        break
    return {"source": path.name, "entries": total, "first_entry_utc": first, "last_entry_utc": last, "network_events": network}


def jsonl(path: pathlib.Path, redactor: Redactor) -> list:
    rows: list = []
    if not contained(path):
        return rows
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            rows.append(redactor.value(json.loads(line)))
        except ValueError:
            continue
    return rows


def export_logs(raw: pathlib.Path, out: pathlib.Path, offset: timedelta, redactor: Redactor, warnings: list[str]) -> None:
    logs = raw / "logs"
    write_json(out / "logs" / "coordinator-events.json", {"schema_version": SCHEMA, "events": json_log_events(logs / "coordinator.log", COORDINATOR_LOG_RE, offset, redactor, warnings)})
    write_json(out / "logs" / "gateway-events.json", {"schema_version": SCHEMA, "events": json_log_events(logs / "gateway.log", GATEWAY_LOG_RE, offset, redactor, warnings)})
    for instance in ("privacy", "plain", "old"):
        write_json(out / "logs" / f"provider-{instance}-lines.json", {"schema_version": SCHEMA, "lines": provider_lines(logs / f"provider-{instance}.log", redactor)})
    for path in sorted(logs.glob("unified-provider-*.log")) if logs.is_dir() else []:
        write_json(out / "logs" / f"{path.stem}.json", {"schema_version": SCHEMA, **unified_events(path, offset, redactor)})
    write_json(out / "logs" / "proxy-events.json", {"schema_version": SCHEMA, "events": jsonl(logs / "proxy-events.jsonl", redactor)})
    write_json(out / "logs" / "wsproxy-events.json", {"schema_version": SCHEMA, "events": jsonl(logs / "wsproxy-events.jsonl", redactor)})
    blackhole = logs / "blackhole.log"
    write_json(out / "logs" / "blackhole.json", {
        "schema_version": SCHEMA,
        "present": contained(blackhole),
        "lines": [line for line in (blackhole.read_text(errors="replace").splitlines() if contained(blackhole) else []) if re.fullmatch(r"\d+ connection", line)],
    })


def export_dyld_procedure(kit_script: pathlib.Path | None, out: pathlib.Path, redactor: Redactor, warnings: list[str]) -> None:
    record: dict = {"schema_version": SCHEMA, "recoverable_from_run_data": False}
    if kit_script is None or not kit_script.is_file():
        warnings.append("kit script not supplied: DYLD procedure record is empty")
        record["kit_script"] = None
    else:
        data = kit_script.read_bytes()
        lines = data.decode("utf-8", errors="replace").splitlines()
        selected = [{"line": index + 1, "text": redactor.text(text.strip()[:MAX_TEXT])} for index, text in enumerate(lines) if "DYLD_" in text or "env-dyld" in text]
        record["kit_script"] = {
            "sha256": hashlib.sha256(data).hexdigest(),
            "mtime_utc": datetime.fromtimestamp(kit_script.stat().st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "dyld_lines": selected,
        }
    write_json(out / "procedure" / "dyld.json", record)


def load_needles(paths: list[pathlib.Path]) -> list[tuple[str, str]]:
    needles: dict[str, str] = {}
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            if "\t" not in line:
                continue
            klass, text = line.split("\t", 1)
            if len(text) >= 8:
                needles[text] = klass
    if not needles:
        die("no needles loaded")
    return [(klass, text) for text, klass in needles.items()]


def needle_forms(text: str) -> list[tuple[str, bytes]]:
    forms = [("raw", text.encode("utf-8")), ("json", json.dumps(text)[1:-1].encode("utf-8")), ("utf16le", text.encode("utf-16-le"))]
    seen: set[bytes] = set()
    unique = []
    for name, data in forms:
        if data and data not in seen:
            seen.add(data)
            unique.append((name, data))
    return unique


def count_hits(data: bytes, needles: list[tuple[str, str]]) -> int:
    return sum(1 for _klass, text in needles if any(form in data for _name, form in needle_forms(text)))


def export_sweep(raw: pathlib.Path, out: pathlib.Path, needles: list[tuple[str, str]], redactor: Redactor) -> None:
    salt = secrets.token_hex(32)
    digests = []
    for klass, text in sorted(needles):
        for form, data in needle_forms(text):
            digests.append({"class": klass, "form": form, "length": len(data), "sha256": hashlib.sha256(bytes.fromhex(salt) + data).hexdigest()})
    write_json(out / "sweep" / "salted-needle-digests.json", {
        "schema_version": SCHEMA,
        "construction": "sha256(bytes.fromhex(salt) || needle_form_bytes); forms raw UTF-8, JSON-escaped, UTF-16LE",
        "salt": salt,
        "digests": sorted(digests, key=lambda item: (item["length"], item["sha256"])),
    })
    files = []
    for root_name in ("db", "logs", "evidence"):
        base = raw / root_name
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not contained(path):
                continue
            data = path.read_bytes()
            files.append({
                "path": redactor.text(path.relative_to(raw).as_posix()),
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "needle_matches": count_hits(data, needles),
            })
    write_json(out / "sweep" / "raw-files.json", {"schema_version": SCHEMA, "files": files, "total_needle_matches": sum(item["needle_matches"] for item in files)})


def write_json(path: pathlib.Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def final_scan(out: pathlib.Path, needles: list[tuple[str, str]], home_prefix: str) -> list[str]:
    problems = []
    for path in sorted(out.rglob("*")):
        if not path.is_file():
            continue
        data = path.read_bytes()
        if count_hits(data, needles):
            problems.append(f"{path.relative_to(out)}: needle present")
        text = data.decode("utf-8", errors="replace")
        if (home_prefix and home_prefix in text) or HOME_RE.search(text) or ESCAPED_HOME_RE.search(text):
            problems.append(f"{path.relative_to(out)}: home path present")
        if re.search(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", text):
            problems.append(f"{path.relative_to(out)}: private key block present")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--needles", action="append", required=True, help="CLASS<TAB>TEXT file (repeatable); never copied")
    parser.add_argument("--kit-script", default=None)
    parser.add_argument("--home-prefix", default="/Users/a1")
    parser.add_argument("--log-utc-offset", default="-07:00")
    args = parser.parse_args(argv)

    if pathlib.Path(args.raw).is_symlink():
        die("raw directory must not be a symlink")
    raw = pathlib.Path(args.raw).resolve()
    out_root = pathlib.Path(args.out)
    if not raw.is_dir():
        die(f"raw directory absent: {raw}")
    global RAW_ROOT
    RAW_ROOT = raw
    if out_root.exists():
        die(f"output directory must not exist: {out_root}")
    if out_root.resolve().is_relative_to(raw):
        die("output directory must be outside the raw directory")
    match = re.fullmatch(r"([+-])(\d{2}):?(\d{2})", args.log_utc_offset)
    if not match:
        die("--log-utc-offset must look like -07:00")
    offset = (1 if match.group(1) == "+" else -1) * timedelta(hours=int(match.group(2)), minutes=int(match.group(3)))
    needles = load_needles([pathlib.Path(item) for item in args.needles])
    redactor = Redactor(args.home_prefix)
    out = out_root / "primary"
    warnings: list[str] = []
    os.umask(0o022)
    try:
        inventory, privacy_ids = export_databases(raw, out, redactor, warnings)
        crossref(raw, out, privacy_ids, warnings)
        export_logs(raw, out, offset, redactor, warnings)
        export_dyld_procedure(pathlib.Path(args.kit_script) if args.kit_script else None, out, redactor, warnings)
        export_sweep(raw, out, needles, redactor)
        write_json(out / "summary.json", {
            "schema_version": SCHEMA,
            "databases": sorted(inventory),
            "privacy_request_ids": len(privacy_ids),
            "log_utc_offset": args.log_utc_offset,
            "warnings": warnings,
            "not_recoverable": [
                "hardening-complete timestamp: the 1.8.215 CLI logs no hardening success line",
                "privacy frame sequence and final-frame count: neither proxy recorded frames",
                "posture challenge/acceptance rows: the coordinator persists no posture and logs only rejections and timeouts",
                "P_TRACED/CS_DEBUGGED: never logged; only posture acceptance after the attach attempts exists",
                "DYLD invocation environment: not logged; procedure/dyld.json holds the kit lines only",
            ],
        })
        problems = final_scan(out_root, needles, args.home_prefix)
    except BaseException:
        shutil.rmtree(out_root, ignore_errors=True)
        raise
    if problems:
        shutil.rmtree(out_root, ignore_errors=True)
        for problem in problems:
            print(f"extract-primary-evidence: refused: {problem}", file=sys.stderr)
        return 1
    print(f"extract-primary-evidence: wrote {out} ({len(list(out.rglob('*.json')))} files, {len(warnings)} warnings)")
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
