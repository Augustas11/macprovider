#!/usr/bin/env python3
import base64
import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def fail(message: str) -> None:
    raise SystemExit(f"verify-malibu-sparkle-signature: {message}")


if len(sys.argv) != 5:
    fail("usage: TAG DMG APPCAST PROJECT_YML")
tag, dmg_name, appcast_name, project_name = sys.argv[1:]
dmg = pathlib.Path(dmg_name)
appcast = pathlib.Path(appcast_name)
project = pathlib.Path(project_name)
if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    fail("invalid tag")
if not dmg.is_file() or dmg.is_symlink() or not appcast.is_file() or appcast.is_symlink():
    fail("DMG and appcast must be regular files")

namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
try:
    root = ET.parse(appcast).getroot()
except ET.ParseError as exc:
    fail(f"invalid appcast XML: {exc}")
items = root.findall("./channel/item")
if len(items) != 1:
    fail("appcast must contain exactly one item")
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

project_text = project.read_text(encoding="utf-8")
matches = re.findall(r"^\s*SUPublicEDKey:\s*([^\s#]+)\s*$", project_text, re.MULTILINE)
if len(matches) != 1:
    fail("project must declare exactly one SUPublicEDKey")
try:
    public_key = base64.b64decode(matches[0], validate=True)
except ValueError as exc:
    fail(f"invalid SUPublicEDKey encoding: {exc}")
if len(public_key) != 32:
    fail("SUPublicEDKey must be 32 bytes")

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
    fail("Sparkle EdDSA signature does not verify against SUPublicEDKey")

print(f"Sparkle signature verified: {hashlib.sha256(dmg.read_bytes()).hexdigest()}")
