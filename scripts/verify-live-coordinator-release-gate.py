#!/usr/bin/env python3
import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


FEEDS = {
    "autotune-candidates.json": "/v1/autotune-candidates",
    "autotune-candidates.json.sig": "/v1/autotune-candidates.sig",
    "demand-rank.json": "/v1/demand-rank",
    "demand-rank.json.sig": "/v1/demand-rank.sig",
    "rate-card.json": "/v1/rate-card",
    "rate-card.json.sig": "/v1/rate-card.sig",
}
PRIMARY_FEEDS = ("autotune-candidates.json", "demand-rank.json", "rate-card.json")
SIG_FEEDS = ("autotune-candidates.json.sig", "demand-rank.json.sig", "rate-card.json.sig")
RELEASE_CATALOG_FILES = tuple(FEEDS) + ("trusted-keys.json",)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_COMPONENT = r"(0|[1-9][0-9]*)"
TAG_RE = re.compile(rf"^v{VERSION_COMPONENT}\.{VERSION_COMPONENT}\.{VERSION_COMPONENT}$")
VERSION_RE = re.compile(
    rf"^v?{VERSION_COMPONENT}\.{VERSION_COMPONENT}\.{VERSION_COMPONENT}"
    r"(?:-[0-9]+-g[0-9a-f]{7,40})?$"
)
ADVERTISED_VERSION_RE = re.compile(
    rf"^{VERSION_COMPONENT}\.{VERSION_COMPONENT}\.{VERSION_COMPONENT}$"
)
ED25519_SPKI_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
TRUSTED_KEY_STATUSES = {"active", "bridge"}
FUTURE_TOLERANCE = datetime.timedelta(minutes=10)
STALE_AFTER = datetime.timedelta(days=30)


class GateError(Exception):
    pass


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fail(message: str) -> None:
    raise GateError(message)


def read_json(path: pathlib.Path, label: str) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"{label} is not valid JSON: {exc}")


def parse_semver(value: object, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        fail(f"{label} is not a version string")
    match = VERSION_RE.fullmatch(value)
    if match is None:
        fail(f"{label} is not vX.Y.Z or X.Y.Z: {value!r}")
    return tuple(int(part) for part in match.groups())


def parse_advertised_version(value: object, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        fail(f"{label} is missing or not a version string")
    match = ADVERTISED_VERSION_RE.fullmatch(value)
    if match is None:
        fail(f"{label} is not X.Y.Z: {value!r}")
    return tuple(int(part) for part in match.groups())


def endpoint_file_name(path: str) -> str:
    return path.removeprefix("/").replace("/", "_")


def load_endpoint(args: argparse.Namespace, path: str) -> bytes:
    if args.coordinator_dir:
        root = pathlib.Path(args.coordinator_dir)
        candidates = [root / endpoint_file_name(path)]
        if path == "/healthz":
            candidates.append(root / "healthz.json")
        for candidate in candidates:
            if candidate.is_file():
                return candidate.read_bytes()
        fail(f"fixture coordinator response is missing for {path}")

    base = args.coordinator_url.rstrip("/")
    if not base.startswith("https://"):
        fail("--coordinator-url must use https:// for live verification")
    url = base + path
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )
    opener = urllib.request.build_opener(NoRedirectHandler)
    try:
        with opener.open(request, timeout=args.timeout_s) as response:
            status = getattr(response, "status", None)
            if status != 200:
                fail(f"{url} returned HTTP {status}, expected 200")
            return response.read(args.max_bytes + 1)
    except urllib.error.HTTPError as exc:
        if exc.code in (301, 302, 303, 307, 308):
            fail(f"{url} redirected with HTTP {exc.code}, expected direct coordinator response")
        fail(f"{url} returned HTTP {exc.code}, expected 200")
    except urllib.error.URLError as exc:
        fail(f"{url} could not be fetched: {exc.reason}")
    except TimeoutError:
        fail(f"{url} timed out")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_json_bytes(data: bytes, label: str) -> object:
    try:
        return json.loads(data.decode("utf-8"))
    except Exception as exc:
        fail(f"{label} response is not valid JSON: {exc}")


def parse_rfc3339(value: str, label: str) -> datetime.datetime:
    try:
        normalized = value.replace("Z", "+00:00")
        parsed = datetime.datetime.fromisoformat(normalized)
    except ValueError:
        fail(f"{label} generated_at must be RFC3339: {value!r}")
    if parsed.tzinfo is None:
        fail(f"{label} generated_at must include a timezone: {value!r}")
    return parsed.astimezone(datetime.timezone.utc)


def parse_now(value: str) -> datetime.datetime:
    parsed = parse_rfc3339(value, "--now")
    return parsed


def decode_canonical_b64(value: object, label: str, expected_len: int) -> bytes:
    if not isinstance(value, str):
        fail(f"{label} is not a string")
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as exc:
        fail(f"{label} is not canonical padded base64: {exc}")
    if base64.b64encode(decoded).decode("ascii") != value:
        fail(f"{label} is not canonical padded base64")
    if len(decoded) != expected_len:
        fail(f"{label} must decode to {expected_len} bytes")
    return decoded


def active_keyring(trusted_keys_path: pathlib.Path) -> dict[str, bytes]:
    value = read_json(trusted_keys_path, "trusted-keys.json")
    if not isinstance(value, dict) or not isinstance(value.get("keys"), dict):
        fail("trusted-keys.json does not contain a keys object")
    if value.get("schema_version") != "macprovider.autotune-keys.v1":
        fail("trusted-keys.json has unsupported schema_version")
    result: dict[str, bytes] = {}
    for key_id, metadata in value["keys"].items():
        if not isinstance(key_id, str) or not isinstance(metadata, dict):
            fail("trusted-keys.json has malformed key metadata")
        if not key_id or key_id.strip() != key_id:
            fail("trusted-keys.json contains an invalid key_id")
        status = metadata.get("status")
        if status in TRUSTED_KEY_STATUSES:
            result[key_id] = decode_canonical_b64(
                metadata.get("public_key_base64"),
                f"trusted-keys.json keys.{key_id}.public_key_base64",
                32,
            )
        elif status != "retired":
            fail(f"trusted-keys.json keys.{key_id}.status is unsupported: {status!r}")
    if not result:
        fail("trusted-keys.json has no non-retired keys")
    return result


def verify_ed25519(
    openssl: str,
    public_key: bytes,
    body: bytes,
    signature: bytes,
    label: str,
) -> None:
    with tempfile.TemporaryDirectory(prefix="macprovider-ed25519-verify.") as root:
        root_path = pathlib.Path(root)
        public_key_path = root_path / "public.der"
        body_path = root_path / "body.json"
        signature_path = root_path / "signature.bin"
        public_key_path.write_bytes(ED25519_SPKI_DER_PREFIX + public_key)
        body_path.write_bytes(body)
        signature_path.write_bytes(signature)
        try:
            result = subprocess.run(
                [
                    openssl,
                    "pkeyutl",
                    "-verify",
                    "-pubin",
                    "-keyform",
                    "DER",
                    "-inkey",
                    str(public_key_path),
                    "-rawin",
                    "-sigfile",
                    str(signature_path),
                    "-in",
                    str(body_path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            fail(f"OpenSSL executable not found: {openssl}")
    if result.returncode != 0:
        fail(f"{label} signature verification failed")


def parse_signature_sidecar(value: object, name: str) -> tuple[str, bytes]:
    if not isinstance(value, dict):
        fail(f"{name} response is not a JSON object")
    if set(value) != {"key_id", "alg", "signature"}:
        fail(f"{name} response has unexpected signature sidecar fields")
    if value.get("alg") != "ed25519":
        fail(f"{name} does not use ed25519")
    key_id = value.get("key_id")
    if not isinstance(key_id, str) or not key_id or key_id.strip() != key_id:
        fail(f"{name} missing key_id")
    signature = decode_canonical_b64(value.get("signature"), f"{name} signature", 64)
    return key_id, signature


def validate_metadata(args: argparse.Namespace) -> tuple[str, dict[str, str]]:
    match = TAG_RE.fullmatch(args.tag)
    if match is None:
        fail("--tag must be vX.Y.Z")
    expected_version = args.tag.removeprefix("v")
    metadata = read_json(pathlib.Path(args.pearl_release_json), "pearl-release.json")
    if not isinstance(metadata, dict) or metadata.get("schema_version") != 1:
        fail("pearl-release.json has unsupported schema")
    if metadata.get("tag") != args.tag:
        fail(f"pearl-release.json tag is {metadata.get('tag')!r}, expected {args.tag!r}")
    if metadata.get("release_version") != expected_version:
        fail("pearl-release.json release_version does not match the tag")
    advertised = metadata.get("provider_advertised_version")
    if advertised is not None and advertised != expected_version:
        fail("pearl-release.json provider_advertised_version does not match the tag")
    catalog = metadata.get("catalog")
    if not isinstance(catalog, dict):
        fail("pearl-release.json does not bind catalog/feed metadata")
    files = catalog.get("files")
    if not isinstance(files, dict):
        fail("pearl-release.json catalog.files is missing")
    expected = {}
    for name in RELEASE_CATALOG_FILES:
        digest = files.get(name)
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            fail(f"pearl-release.json catalog hash is missing or invalid for {name}")
        expected[name] = digest
    trusted_keys_digest = sha256(pathlib.Path(args.trusted_keys).read_bytes())
    if trusted_keys_digest != expected["trusted-keys.json"]:
        fail(
            f"trusted-keys.json sha256 {trusted_keys_digest} does not match "
            f"release metadata {expected['trusted-keys.json']}"
        )
    return expected_version, expected


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the live coordinator serves the feed set required by a CLI release."
    )
    parser.add_argument("--tag", required=True, help="release tag, vX.Y.Z")
    parser.add_argument("--pearl-release-json", required=True, help="release pearl-release.json")
    parser.add_argument("--trusted-keys", required=True, help="release trusted-keys.json")
    parser.add_argument(
        "--coordinator-url",
        default="https://coordinator.streamvc.live",
        help="public coordinator origin",
    )
    parser.add_argument(
        "--coordinator-dir",
        help="fixture directory containing v1_* endpoint files and healthz.json",
    )
    parser.add_argument("--timeout-s", type=float, default=10.0)
    parser.add_argument("--max-bytes", type=int, default=4 * 1024 * 1024)
    parser.add_argument(
        "--openssl",
        default=os.environ.get("OPENSSL_BIN", "openssl"),
        help="OpenSSL executable used for Ed25519 verification",
    )
    parser.add_argument(
        "--publication-phase",
        choices=("pre-publication", "post-publication"),
        default="post-publication",
        help=(
            "pre-publication verifies release-bound feed bytes without requiring "
            "the live recommendation; post-publication requires exact recommendation "
            "equality (default)"
        ),
    )
    parser.add_argument(
        "--expected-previous-recommendation",
        help="pre-publication recommendation that must remain live until publication",
    )
    parser.add_argument(
        "--now",
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    try:
        expected_version, expected_hashes = validate_metadata(args)
        trusted = active_keyring(pathlib.Path(args.trusted_keys))

        bodies: dict[str, bytes] = {}
        parsed: dict[str, object] = {}
        for name, endpoint in FEEDS.items():
            body = load_endpoint(args, endpoint)
            if len(body) > args.max_bytes:
                fail(f"{endpoint} response exceeds {args.max_bytes} bytes")
            digest = sha256(body)
            if digest != expected_hashes[name]:
                fail(
                    f"live coordinator {endpoint} sha256 {digest} does not match "
                    f"release metadata {expected_hashes[name]}"
                )
            bodies[name] = body
            parsed[name] = parse_json_bytes(body, name)

        generated_at = None
        generated_at_instant = None
        policy_version = None
        now = parse_now(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
        for name in PRIMARY_FEEDS:
            value = parsed[name]
            if not isinstance(value, dict):
                fail(f"{name} response is not a JSON object")
            current_generated_at = value.get("generated_at")
            current_policy_version = value.get("policy_version")
            if not isinstance(current_generated_at, str) or not current_generated_at:
                fail(f"{name} missing generated_at")
            if not isinstance(current_policy_version, str) or not current_policy_version:
                fail(f"{name} missing policy_version")
            current_generated_at_instant = parse_rfc3339(current_generated_at, name)
            if current_generated_at_instant > now + FUTURE_TOLERANCE:
                fail(
                    f"{name} generated_at {current_generated_at!r} is more than "
                    "10 minutes in the future"
                )
            if now - current_generated_at_instant > STALE_AFTER:
                fail(f"{name} generated_at {current_generated_at!r} is more than 30 days old")
            if generated_at is None:
                generated_at = current_generated_at
                generated_at_instant = current_generated_at_instant
                policy_version = current_policy_version
            elif (
                current_generated_at != generated_at
                or current_generated_at_instant != generated_at_instant
                or current_policy_version != policy_version
            ):
                fail("live coordinator feed set is not mutually paired by generated_at and policy_version")

        for name in SIG_FEEDS:
            key_id, signature = parse_signature_sidecar(parsed[name], name)
            if key_id not in trusted:
                fail(f"{name} key_id {key_id!r} is not in the release trusted keyring")
            signed_name = name.removesuffix(".sig")
            if signed_name not in bodies:
                fail(f"{name} does not correspond to a fetched feed body")
            verify_ed25519(args.openssl, trusted[key_id], bodies[signed_name], signature, name)

        healthz = parse_json_bytes(load_endpoint(args, "/healthz"), "healthz")
        if not isinstance(healthz, dict):
            fail("/healthz response is not a JSON object")
        if healthz.get("status") != "ok":
            fail(f"/healthz status is {healthz.get('status')!r}, expected 'ok'")
        live_version = parse_semver(healthz.get("version"), "/healthz version")
        required_version = parse_semver(expected_version, "release version")
        if live_version < required_version:
            fail(
                f"/healthz version {healthz.get('version')!r} is older than "
                f"release {expected_version}"
            )
        recommended_value = healthz.get("recommended_binary_version")
        if (
            args.publication_phase == "pre-publication"
            and args.expected_previous_recommendation is not None
            and recommended_value is None
        ):
            fail("/healthz recommended_binary_version is missing or not the expected previous stable version")
        if recommended_value is None and args.publication_phase == "post-publication":
            fail("/healthz recommended_binary_version is missing or not a version string")
        if recommended_value is not None:
            recommended_version = parse_advertised_version(
                recommended_value,
                "/healthz recommended_binary_version",
            )
            if (
                args.publication_phase == "post-publication"
                and (
                    recommended_version != required_version
                    or recommended_value != expected_version
                )
            ):
                fail(
                    f"/healthz recommended_binary_version {recommended_value!r} "
                    f"does not match release {expected_version}"
                )
            if (
                args.publication_phase == "pre-publication"
                and args.expected_previous_recommendation is not None
                and (
                    recommended_value != args.expected_previous_recommendation
                    or recommended_version
                    != parse_advertised_version(
                        args.expected_previous_recommendation,
                        "expected previous recommendation",
                    )
                )
            ):
                fail(
                    f"/healthz recommended_binary_version {recommended_value!r} "
                    f"does not match expected previous stable "
                    f"{args.expected_previous_recommendation}"
                )
        else:
            recommended_value = "<not advertised>"

        print(
            "[verify-live-coordinator-release-gate] ok: "
            f"{args.coordinator_url.rstrip('/')} serves {args.tag} feed set "
            f"generated_at={generated_at} policy_version={policy_version} "
            f"healthz_version={healthz.get('version')} "
            f"recommended_binary_version={recommended_value} "
            f"publication_phase={args.publication_phase}"
        )
        return 0
    except GateError as exc:
        print(f"[verify-live-coordinator-release-gate] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
