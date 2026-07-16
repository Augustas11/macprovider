#!/usr/bin/env python3
import base64
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def fail(message: str) -> None:
    raise SystemExit(f"verify-malibu-sparkle-signature: {message}")


if len(sys.argv) != 5:
    fail("usage: TAG DMG APPCAST LEGACY_PUBLIC_KEY")
tag, dmg_name, appcast_name, public_key_name = sys.argv[1:]
dmg = pathlib.Path(dmg_name)
appcast = pathlib.Path(appcast_name)
public_key_path = pathlib.Path(public_key_name)
if tag != "v1.8.39":
    fail("legacy Malibu bootstrap is frozen to v1.8.39")
if any(
    not path.is_file() or path.is_symlink()
    for path in (dmg, appcast, public_key_path)
):
    fail("DMG, appcast, and legacy public key must be regular files")

namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
try:
    root = ET.parse(appcast).getroot()
except ET.ParseError as exc:
    fail(f"invalid appcast XML: {exc}")
items = root.findall("./channel/item")
if len(items) != 1:
    fail("appcast must contain exactly one item")
short_versions = items[0].findall(f"{{{namespace}}}shortVersionString")
if len(short_versions) != 1 or (short_versions[0].text or "").strip() != "1.8.39":
    fail("appcast short version differs from the bootstrap target")
build_versions = items[0].findall(f"{{{namespace}}}version")
if len(build_versions) != 1 or (build_versions[0].text or "").strip() != "39":
    fail("appcast build version differs from the bootstrap target")
enclosures = items[0].findall("enclosure")
if len(enclosures) != 1:
    fail("appcast must contain exactly one enclosure")
enclosure = enclosures[0]
expected_url = f"https://download.malibu.tech/Malibu-{tag}.dmg"
if enclosure.get("url") != expected_url:
    fail("appcast enclosure URL differs from the release tag")
if enclosure.get("length") != str(dmg.stat().st_size):
    fail("appcast enclosure length differs from the DMG")
signature_text = enclosure.get(f"{{{namespace}}}edSignature")
if not signature_text:
    fail("appcast enclosure omits the Sparkle EdDSA signature")
try:
    signature = base64.b64decode(signature_text, validate=True)
except ValueError as exc:
    fail(f"invalid Sparkle signature encoding: {exc}")
if len(signature) != 64:
    fail("Sparkle signature must be 64 bytes")

key_lines = [
    line.strip()
    for line in public_key_path.read_text(encoding="ascii").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
if key_lines != ["JkTDWnRJfOI3YIlpfJKvasWkxb0O1j/7ObGYiIA7big="]:
    fail("legacy public key differs from Malibu v1.8.32")
try:
    public_key = base64.b64decode(key_lines[0], validate=True)
except ValueError as exc:
    fail(f"invalid legacy public key encoding: {exc}")
if len(public_key) != 32:
    fail("legacy public key must be 32 bytes")

if sys.platform == "darwin":
    swift_verifier = pathlib.Path(__file__).with_name("verify-ed25519-signature.swift")
    if not swift_verifier.is_file() or swift_verifier.is_symlink():
        fail("reviewed macOS Ed25519 verifier is missing")
    result = subprocess.run(
        [
            "xcrun",
            "swift",
            str(swift_verifier),
            base64.b64encode(public_key).decode("ascii"),
            base64.b64encode(signature).decode("ascii"),
            str(dmg),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
else:
    # RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
    spki = bytes.fromhex("302a300506032b6570032100") + public_key
    with tempfile.TemporaryDirectory(prefix="sparkle-verify-") as temporary:
        root_path = pathlib.Path(temporary)
        der = root_path / "public.der"
        pem = root_path / "public.pem"
        sig = root_path / "signature.bin"
        der.write_bytes(spki)
        sig.write_bytes(signature)
        subprocess.run(
            ["openssl", "pkey", "-pubin", "-inform", "DER", "-in", str(der), "-out", str(pem)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        result = subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-verify",
                "-pubin",
                "-inkey",
                str(pem),
                "-rawin",
                "-in",
                str(dmg),
                "-sigfile",
                str(sig),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
if result.returncode != 0:
    fail("Sparkle EdDSA signature does not verify against the Malibu v1.8.32 key")

print(f"Sparkle signature verified: {hashlib.sha256(dmg.read_bytes()).hexdigest()}")
