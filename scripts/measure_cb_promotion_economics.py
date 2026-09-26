#!/usr/bin/env python3
"""Calculate deterministic modeled continuous-batching promotion economics."""

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
from decimal import Decimal, InvalidOperation
from fractions import Fraction
from pathlib import Path


REPORT_SCHEMA = "malibu.cb_promotion_economics"
REPORT_VERSION = 2
CALCULATOR_REVISION = "cb-promotion-economics-modeled-v2"
TOKENS_PER_MILLION = 1_000_000
PPM_DENOMINATOR = 1_000_000
BPS_DENOMINATOR = 10_000
MAX_INPUT_BYTES = 4 << 20
MAX_LINE_BYTES = 256 << 10
MAX_ROWS = 4096
MAX_TOKENS_PER_REQUEST = 10_000_000
MAX_SECONDS = Decimal("1000000000")
MAX_RATE = (1 << 63) - 1
# Campaign inputs are bounded to signed-64-bit integer precision and nanounit
# decimal scale; the schema has no legitimate need for larger JSON numerics.
MAX_JSON_SIGNIFICANT_DIGITS = 19
MAX_JSON_FRACTIONAL_DIGITS = 9
MAX_JSON_DECIMAL_EXPONENT = 9
# Matrix rows need one level and rate-card rows need three; leave bounded headroom.
MAX_JSON_NESTING = 8

MATRIX_FIELDS = frozenset(
    {
        "L_target",
        "rows",
        "mode",
        "prompt_tokens",
        "completion_tokens",
        "ttft_median_s",
        "ttft_max_s",
        "prefill_tok_s_median",
        "decode_tok_s_per_request_median",
        "aggregate_decode_tok_s",
        "wall_s",
    }
)
RATE_CARD_FIELDS = frozenset(
    {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"}
)
RATE_ROW_FIELDS = frozenset(
    {
        "prompt_rate_per_mtok",
        "prompt_cache_hit_rate_per_mtok",
        "completion_rate_per_mtok",
        "provider_share_bps",
        "global_multiplier_ppm",
    }
)


class ValidationError(ValueError):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValidationError(f"non-finite JSON number: {value}")


def parse_json_int(value):
    digits = value.removeprefix("-")
    if len(digits) > MAX_JSON_SIGNIFICANT_DIGITS:
        raise ValidationError("JSON integer literal has too many digits")
    return int(value)


def parse_json_decimal(value):
    coefficient, marker, exponent = value.lower().partition("e")
    unsigned_coefficient = coefficient.removeprefix("-")
    integer, point, fractional = unsigned_coefficient.partition(".")
    significant_digits = (integer + fractional).lstrip("0") or "0"
    if len(significant_digits) > MAX_JSON_SIGNIFICANT_DIGITS:
        raise ValidationError("JSON decimal literal has too many significant digits")
    if point and len(fractional) > MAX_JSON_FRACTIONAL_DIGITS:
        raise ValidationError("JSON decimal literal has too many fractional digits")
    if marker:
        exponent_digits = exponent.lstrip("+-")
        if len(exponent_digits) > len(str(MAX_JSON_DECIMAL_EXPONENT)):
            raise ValidationError("JSON decimal literal exponent is out of range")
        if abs(int(exponent)) > MAX_JSON_DECIMAL_EXPONENT:
            raise ValidationError("JSON decimal literal exponent is out of range")
    result = Decimal(value)
    if abs(result.as_tuple().exponent) > MAX_JSON_DECIMAL_EXPONENT:
        raise ValidationError("JSON decimal literal scale is out of range")
    return result


def reject_excessive_json_nesting(payload):
    depth = 0
    in_string = False
    escaped = False
    for character in payload:
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif character in "[{":
            depth += 1
            if depth > MAX_JSON_NESTING:
                raise ValidationError("JSON nesting is too deep")
        elif character in "]}":
            depth -= 1


def load_json_bytes(payload, label):
    try:
        decoded = payload.decode("utf-8")
        reject_excessive_json_nesting(decoded)
        return json.loads(
            decoded,
            parse_float=parse_json_decimal,
            parse_int=parse_json_int,
            parse_constant=reject_constant,
            object_pairs_hook=reject_duplicate_keys,
        )
    except ValidationError:
        raise
    except UnicodeDecodeError as exc:
        raise ValidationError(f"{label}: input must be UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{label}: invalid JSON: {exc.msg}") from exc
    except RecursionError as exc:
        raise ValidationError(f"{label}: JSON nesting is too deep") from exc
    except ValueError as exc:
        raise ValidationError(f"{label}: invalid JSON numeric literal") from exc


def read_bounded(path, label):
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise ValidationError(f"{label}: platform lacks no-follow input support")
    flags = os.O_RDONLY | nofollow
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValidationError(
            f"{label}: cannot open no-follow regular file {path}: {exc}"
        ) from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValidationError(f"{label}: input must be a regular file")
        if metadata.st_size > MAX_INPUT_BYTES:
            raise ValidationError(f"{label}: input exceeds {MAX_INPUT_BYTES} bytes")
        chunks = []
        remaining = MAX_INPUT_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(64 << 10, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > MAX_INPUT_BYTES:
            raise ValidationError(f"{label}: input exceeds {MAX_INPUT_BYTES} bytes")
        return payload
    except OSError as exc:
        raise ValidationError(f"{label}: cannot read {path}: {exc}") from exc
    finally:
        os.close(descriptor)


def exact_fields(value, expected, label):
    if not isinstance(value, dict):
        raise ValidationError(f"{label}: must be an object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValidationError(f"{label}: fields mismatch; missing={missing}, extra={extra}")


def require_int(value, label, minimum=0, maximum=None):
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValidationError(f"{label}: must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        bound = f"[{minimum},{maximum}]" if maximum is not None else f">= {minimum}"
        raise ValidationError(f"{label}: must be {bound}")
    return value


def require_decimal(value, label, positive=False, nonnegative=False, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (int, Decimal)):
        raise ValidationError(f"{label}: must be a JSON number")
    try:
        result = Decimal(value)
    except (InvalidOperation, ValueError) as exc:
        raise ValidationError(f"{label}: invalid numeric value") from exc
    if not result.is_finite():
        raise ValidationError(f"{label}: must be finite")
    if positive and result <= 0:
        raise ValidationError(f"{label}: must be > 0")
    if nonnegative and result < 0:
        raise ValidationError(f"{label}: must be >= 0")
    if maximum is not None and result > maximum:
        raise ValidationError(f"{label}: must be <= {maximum}")
    return result


def require_string(value, label):
    if not isinstance(value, str) or not value or value.strip() != value:
        raise ValidationError(f"{label}: must be a non-empty trimmed string")
    return value


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def json_number(value):
    decimal = require_decimal(value, "rate-card numeric projection", nonnegative=True)
    if decimal == decimal.to_integral_value():
        return str(decimal.quantize(Decimal(1)))
    return format(decimal.normalize(), "f")


def rate_card_projection_hash(card):
    default_row = card["rows"]["default"]
    parts = [
        '{"global_multiplier_ppm":',
        str(default_row["global_multiplier_ppm"]),
        ',"provider_share_bps":',
        str(default_row["provider_share_bps"]),
        ',"rows":{',
    ]
    for index, key in enumerate(sorted(card["rows"])):
        if index:
            parts.append(",")
        row = card["rows"][key]
        parts.extend(
            [
                json.dumps(key, ensure_ascii=False, separators=(",", ":")),
                ':{"completion_rate_per_mtok":',
                str(row["completion_rate_per_mtok"]),
                ',"global_multiplier_ppm":',
                str(row["global_multiplier_ppm"]),
                ',"prompt_cache_hit_rate_per_mtok":',
                str(row["prompt_cache_hit_rate_per_mtok"]),
                ',"prompt_rate_per_mtok":',
                str(row["prompt_rate_per_mtok"]),
                ',"provider_share_bps":',
                str(row["provider_share_bps"]),
                "}",
            ]
        )
    parts.extend(
        ['},"usd_per_million_credits":', json_number(card["usd_per_million_credits"]), "}"]
    )
    return sha256("".join(parts).encode("utf-8"))


def validate_rate_card(card, selected_key):
    exact_fields(card, RATE_CARD_FIELDS, "rate-card")
    require_string(card["version"], "rate-card.version")
    require_string(card["policy_version"], "rate-card.policy_version")
    require_string(card["generated_at"], "rate-card.generated_at")
    require_decimal(
        card["usd_per_million_credits"],
        "rate-card.usd_per_million_credits",
        nonnegative=True,
        maximum=MAX_RATE,
    )
    rows = card["rows"]
    if not isinstance(rows, dict) or not rows or "default" not in rows:
        raise ValidationError("rate-card.rows: non-empty object with default row required")
    for key, row in rows.items():
        require_string(key, "rate-card row key")
        exact_fields(row, RATE_ROW_FIELDS, f"rate-card row {key}")
        for field in (
            "prompt_rate_per_mtok",
            "prompt_cache_hit_rate_per_mtok",
            "completion_rate_per_mtok",
            "global_multiplier_ppm",
        ):
            require_int(row[field], f"rate-card row {key}.{field}", maximum=MAX_RATE)
        require_int(
            row["provider_share_bps"],
            f"rate-card row {key}.provider_share_bps",
            maximum=BPS_DENOMINATOR,
        )
        if row["prompt_cache_hit_rate_per_mtok"] > row["prompt_rate_per_mtok"]:
            raise ValidationError(
                f"rate-card row {key}: prompt cache-hit rate exceeds prompt rate"
            )
    default = rows["default"]
    for key, row in rows.items():
        for field in ("provider_share_bps", "global_multiplier_ppm"):
            if row[field] != default[field]:
                raise ValidationError(
                    f"rate-card row {key}: {field} differs from release-global default"
                )
    expected_version = rate_card_projection_hash(card)
    if card["version"] != expected_version:
        raise ValidationError(
            f"rate-card.version: expected projection hash {expected_version}"
        )
    if selected_key not in rows:
        raise ValidationError(f"rate-card: selected row not found: {selected_key}")
    return rows[selected_key]


def parse_matrix(payload):
    if not payload:
        raise ValidationError("matrix: empty input")
    observations = []
    seen = set()
    for line_number, raw_line in enumerate(payload.splitlines(), 1):
        if not raw_line.strip():
            raise ValidationError(f"matrix line {line_number}: blank lines are not allowed")
        if len(raw_line) > MAX_LINE_BYTES:
            raise ValidationError(f"matrix line {line_number}: exceeds {MAX_LINE_BYTES} bytes")
        row = load_json_bytes(raw_line, f"matrix line {line_number}")
        exact_fields(row, MATRIX_FIELDS, f"matrix line {line_number}")
        target = require_int(
            row["L_target"],
            f"matrix line {line_number}.L_target",
            1,
            MAX_TOKENS_PER_REQUEST,
        )
        rows = require_int(row["rows"], f"matrix line {line_number}.rows", 1, MAX_ROWS)
        mode = row["mode"]
        if mode not in ("serial", "batched"):
            raise ValidationError(f"matrix line {line_number}.mode: must be serial or batched")
        if mode == "serial" and rows != 1:
            raise ValidationError(f"matrix line {line_number}: serial control must have rows=1")
        key = (target, rows, mode)
        if key in seen:
            raise ValidationError(f"matrix line {line_number}: duplicate observation {key}")
        seen.add(key)

        prompt_median = require_decimal(
            row["prompt_tokens"],
            f"matrix line {line_number}.prompt_tokens",
            nonnegative=True,
            maximum=MAX_TOKENS_PER_REQUEST,
        )
        modeled_prompt_total = prompt_median * rows
        total_completion_decimal = require_decimal(
            row["completion_tokens"],
            f"matrix line {line_number}.completion_tokens",
            nonnegative=True,
            maximum=MAX_TOKENS_PER_REQUEST * rows,
        )
        if total_completion_decimal != total_completion_decimal.to_integral_value():
            raise ValidationError(
                f"matrix line {line_number}: completion_tokens must be integral"
            )
        wall = require_decimal(
            row["wall_s"],
            f"matrix line {line_number}.wall_s",
            positive=True,
            maximum=MAX_SECONDS,
        )
        ttft_max = require_decimal(
            row["ttft_max_s"],
            f"matrix line {line_number}.ttft_max_s",
            positive=True,
            maximum=MAX_SECONDS,
        )
        for field in (
            "ttft_median_s",
            "prefill_tok_s_median",
            "decode_tok_s_per_request_median",
            "aggregate_decode_tok_s",
        ):
            require_decimal(
                row[field],
                f"matrix line {line_number}.{field}",
                nonnegative=True,
                maximum=MAX_SECONDS,
            )
        observations.append(
            {
                "L_target": target,
                "rows": rows,
                "mode": mode,
                "median_prompt_tokens_per_request": prompt_median,
                "modeled_prompt_tokens": modeled_prompt_total,
                "aggregate_completion_tokens": int(total_completion_decimal),
                "wall_s": wall,
                "worst_ttft_s": ttft_max,
            }
        )

    serial_by_target = {}
    batched_targets = set()
    for row in observations:
        target = row["L_target"]
        if row["mode"] == "serial":
            if target in serial_by_target:
                raise ValidationError(f"matrix: ambiguous serial controls for L_target={target}")
            serial_by_target[target] = row
        else:
            batched_targets.add(target)
    for target in sorted(batched_targets):
        if target not in serial_by_target:
            raise ValidationError(f"matrix: missing serial control for L_target={target}")
    for target in sorted(serial_by_target):
        if target not in batched_targets:
            raise ValidationError(f"matrix: serial control has no batched rows for L_target={target}")
    for row in observations:
        serial = serial_by_target[row["L_target"]]
        expected = serial["aggregate_completion_tokens"] * row["rows"]
        if row["aggregate_completion_tokens"] != expected:
            raise ValidationError(
                "matrix: inconsistent completion token total for "
                f"L_target={row['L_target']} rows={row['rows']} mode={row['mode']}; "
                f"got {row['aggregate_completion_tokens']}, expected {expected}"
            )
    return observations, serial_by_target


def compute_modeled_credits(prompt_tokens, completion_tokens, rate):
    base = (
        Fraction(prompt_tokens) * rate["prompt_rate_per_mtok"]
        + Fraction(completion_tokens) * rate["completion_rate_per_mtok"]
    )
    if base > MAX_RATE or base * rate["global_multiplier_ppm"] > MAX_RATE:
        raise ValidationError("credit arithmetic exceeds signed 64-bit range")
    gross = (
        base
        * rate["global_multiplier_ppm"]
        / (TOKENS_PER_MILLION * PPM_DENOMINATOR)
    )
    provider = gross * rate["provider_share_bps"] / BPS_DENOMINATOR
    return gross, provider


def decimal_text(value, places=6):
    fraction = Fraction(value)
    sign = "-" if fraction < 0 else ""
    numerator = abs(fraction.numerator) * (10**places)
    quotient, remainder = divmod(numerator, fraction.denominator)
    twice = remainder * 2
    if twice > fraction.denominator or (
        twice == fraction.denominator and quotient % 2
    ):
        quotient += 1
    if places == 0:
        return f"{sign}{quotient}"
    whole, fractional = divmod(quotient, 10**places)
    return f"{sign}{whole}.{fractional:0{places}d}"


def build_report(matrix_payload, rate_card_payload, selected_key):
    card = load_json_bytes(rate_card_payload, "rate-card")
    selected_rate = validate_rate_card(card, selected_key)
    observations, serial_by_target = parse_matrix(matrix_payload)
    usd_peg = require_decimal(
        card["usd_per_million_credits"],
        "rate-card.usd_per_million_credits",
        nonnegative=True,
        maximum=MAX_RATE,
    )

    computed = []
    by_identity = {}
    for observation in observations:
        gross, provider = compute_modeled_credits(
            observation["modeled_prompt_tokens"],
            observation["aggregate_completion_tokens"],
            selected_rate,
        )
        provider_per_hour = provider * 3600 / Fraction(observation["wall_s"])
        result = {
            **observation,
            "gross_credits": gross,
            "provider_credits": provider,
            "provider_credits_per_wall_hour": provider_per_hour,
            "provider_usd_per_wall_hour": (
                provider_per_hour * Fraction(usd_peg) / TOKENS_PER_MILLION
            ),
        }
        computed.append(result)
        by_identity[(observation["L_target"], observation["rows"], observation["mode"])] = result

    report_rows = []
    for row in sorted(computed, key=lambda item: (item["L_target"], item["mode"] != "serial", item["rows"])):
        serial_source = serial_by_target[row["L_target"]]
        serial = by_identity[(row["L_target"], serial_source["rows"], "serial")]
        if serial["provider_credits_per_wall_hour"] == 0:
            raise ValidationError(
                f"serial control for L_target={row['L_target']} has zero modeled provider earnings"
            )
        earnings_ratio = (
            row["provider_credits_per_wall_hour"] / serial["provider_credits_per_wall_hour"]
        )
        ttft_ratio = row["worst_ttft_s"] / serial["worst_ttft_s"]
        report_rows.append(
            {
                "L_target": row["L_target"],
                "rows": row["rows"],
                "mode": row["mode"],
                "median_prompt_tokens_per_request": decimal_text(
                    row["median_prompt_tokens_per_request"], 3
                ),
                "modeled_prompt_tokens": decimal_text(row["modeled_prompt_tokens"], 3),
                "aggregate_completion_tokens": row["aggregate_completion_tokens"],
                "wall_s": decimal_text(row["wall_s"], 3),
                "worst_ttft_s": decimal_text(row["worst_ttft_s"], 3),
                "modeled_gross_credits": decimal_text(row["gross_credits"], 9),
                "modeled_provider_credits": decimal_text(row["provider_credits"], 9),
                "modeled_provider_credits_per_wall_hour": decimal_text(
                    row["provider_credits_per_wall_hour"]
                ),
                "modeled_provider_usd_per_wall_hour": decimal_text(
                    row["provider_usd_per_wall_hour"]
                ),
                "modeled_earnings_hour_ratio_vs_serial": decimal_text(earnings_ratio),
                "worst_ttft_ratio_vs_serial": decimal_text(ttft_ratio),
            }
        )

    return {
        "schema": REPORT_SCHEMA,
        "version": REPORT_VERSION,
        "calculator_revision": CALCULATOR_REVISION,
        "inputs": {
            "matrix_sha256": sha256(matrix_payload),
            "rate_card_sha256": sha256(rate_card_payload),
        },
        "rate_card": {
            "projection_hash": card["version"],
            "signature_verified": False,
            "policy_version": card["policy_version"],
            "row_key": selected_key,
            "row": dict(selected_rate),
            "usd_per_million_credits": json_number(usd_peg),
        },
        "method": {
            "classification": "deterministic_modeled_proxy_not_ledger_settlement",
            "prompt_model": "median_prompt_tokens_per_request_times_rows",
            "completion_input": "aggregate_completion_tokens",
            "credit_model": "published_rates_multiplier_and_unrounded_provider_share",
            "rate_card_validation": "projection_hash_only_no_signature_verification",
            "comparison": "same_L_target_serial_control",
            "limitations": [
                "individual_request_prompt_and_completion_token_counts_not_retained",
                "SPEC-005_section_5.3_rounds_gross_and_provider_credits_per_request",
                "exact_settled_credits_cannot_be_reconstructed_for_multi_request_rows",
            ],
        },
        "observations": report_rows,
    }


def canonical_json(value):
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def write_create_only(path, payload):
    parent = path.parent
    if not parent.is_dir():
        raise ValidationError(f"output parent does not exist: {parent}")
    if path.exists() or path.is_symlink():
        raise ValidationError(f"output already exists: {path}")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=parent, prefix=f".{path.name}.", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path, follow_symlinks=False)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except FileExistsError as exc:
        raise ValidationError(f"output already exists: {path}") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=(
            "Offline deterministic modeled earnings/hour proxy for a CB matrix; "
            "not an exact SPEC-005 settlement reconstruction."
        )
    )
    parser.add_argument("matrix", type=Path, help="input JSONL matrix")
    parser.add_argument(
        "rate_card",
        type=Path,
        help="catalog rate-card JSON (projection hash validated; signature not verified)",
    )
    parser.add_argument("--rate-card-row", required=True, help="exact rate-card row key")
    parser.add_argument("--output", type=Path, help="create-only canonical JSON report path")
    return parser.parse_args(argv)


def main(argv=None):
    try:
        args = parse_args(argv)
        matrix_payload = read_bounded(args.matrix, "matrix")
        rate_card_payload = read_bounded(args.rate_card, "rate-card")
        payload = canonical_json(
            build_report(matrix_payload, rate_card_payload, args.rate_card_row)
        )
        if args.output:
            write_create_only(args.output, payload)
        else:
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.flush()
        return 0
    except BrokenPipeError:
        return 1
    except (ValidationError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
