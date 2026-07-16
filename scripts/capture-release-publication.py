#!/usr/bin/env python3
import hashlib
import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"capture-release-publication: {message}")


arguments = sys.argv[1:]
draft_mode = bool(arguments and arguments[0] == "--draft")
if draft_mode:
    arguments = arguments[1:]
notes_path = None
if arguments[:1] == ["--notes-file"]:
    if len(arguments) < 2:
        fail("--notes-file requires a path")
    notes_path = pathlib.Path(arguments[1])
    arguments = arguments[2:]
if len(arguments) < 4:
    fail("usage: [--draft] [--notes-file PATH] RELEASE_JSON PROVENANCE_JSON OUTPUT RELEASE_ASSET...")

release_path, provenance_path, output_path, *local_asset_names = arguments
release = json.loads(pathlib.Path(release_path).read_text(encoding="utf-8"))
provenance = json.loads(pathlib.Path(provenance_path).read_text(encoding="utf-8"))

tag = provenance.get("tag")
commit = provenance.get("commit")
repository = provenance.get("repository")
prerelease = provenance.get("prerelease")
toolchain = provenance.get("toolchain")
if provenance.get("schema_version") != 1:
    fail("unsupported provenance schema")
if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    fail("invalid provenance tag")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    fail("invalid provenance commit")
if not isinstance(repository, str) or not re.fullmatch(
    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository
):
    fail("invalid provenance repository")
if type(prerelease) is not bool:
    fail("invalid provenance prerelease state")
if not isinstance(toolchain, dict):
    fail("invalid provenance toolchain")
if release.get("tag_name") != tag:
    fail("numeric release tag differs from signed provenance")
if release.get("target_commitish") != commit:
    fail("numeric release target differs from signed provenance")
expected_title = f"macprovider-cli {tag}"
body_sha256 = None
if notes_path is not None:
    if not notes_path.is_file() or notes_path.is_symlink():
        fail(f"release notes are not regular: {notes_path}")
    expected_body = notes_path.read_text(encoding="utf-8")
    if release.get("name") != expected_title:
        fail("numeric release title differs from the reviewed release")
    if release.get("body") != expected_body:
        fail("numeric release body differs from the reviewed release notes")
    body_sha256 = hashlib.sha256(expected_body.encode()).hexdigest()
if draft_mode:
    if release.get("draft") is not True:
        fail("numeric release is not the expected draft")
    if release.get("immutable") is True:
        fail("draft release unexpectedly reports immutable")
else:
    if release.get("draft") is not False:
        fail("numeric release is still a draft")
    if release.get("immutable") is not True:
        fail("numeric release is not immutable")
    if release.get("prerelease") is not prerelease:
        fail("numeric release prerelease state differs from signed provenance")
release_id = release.get("id")
if type(release_id) is not int or release_id <= 0:
    fail("numeric release id is invalid")

local_assets: dict[str, tuple[pathlib.Path, str]] = {}
for value in local_asset_names:
    path = pathlib.Path(value)
    if not path.is_file() or path.is_symlink():
        fail(f"local release asset is not regular: {path}")
    if path.name in local_assets:
        fail(f"duplicate local release asset name: {path.name}")
    local_assets[path.name] = (path, hashlib.sha256(path.read_bytes()).hexdigest())

api_assets: dict[str, dict] = {}
for row in release.get("assets", []):
    if not isinstance(row, dict) or not isinstance(row.get("name"), str):
        fail("numeric release contains an invalid asset row")
    if row["name"] in api_assets:
        fail(f"numeric release has duplicate asset name: {row['name']}")
    api_assets[row["name"]] = row
signed_assets = provenance.get("assets")
if not isinstance(signed_assets, dict) or not all(
    isinstance(name, str) and isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
    for name, digest in signed_assets.items()
):
    fail("signed provenance assets are invalid")
expected_names = set(signed_assets) | {"release-provenance.json", "checksums.txt", "checksums.txt.sig"}
if set(api_assets) != expected_names:
    fail("numeric release asset names differ from the signed release set")
required_local = {
    f"Malibu-{tag}.dmg",
    "compatibility-artifact-index.json",
    "release-provenance.json",
    "checksums.txt",
    "checksums.txt.sig",
}
if not required_local <= set(local_assets):
    fail("captured publication files are incomplete")

manifest_assets: dict[str, dict[str, object]] = {}
for name, row in sorted(api_assets.items()):
    digest = local_assets[name][1] if name in local_assets else signed_assets.get(name)
    if digest is None:
        fail(f"no trusted digest is available for {name}")
    asset_id = row.get("id")
    if type(asset_id) is not int or asset_id <= 0:
        fail(f"numeric asset id is invalid for {name}")
    if row.get("digest") != f"sha256:{digest}":
        fail(f"GitHub digest differs from captured workflow asset: {name}")
    manifest_assets[name] = {"id": asset_id, "sha256": digest}

for name, digest in signed_assets.items():
    if name in local_assets and local_assets[name][1] != digest:
        fail(f"signed provenance hash differs for {name}")

dmg_name = f"Malibu-{tag}.dmg"
index_name = "compatibility-artifact-index.json"
if dmg_name not in local_assets or index_name not in local_assets:
    fail("publication requires Malibu DMG and compatibility artifact index")
publication_content = {
    "compatibility_artifact_index_sha256": local_assets[index_name][1],
    "dmg_sha256": local_assets[dmg_name][1],
}
if "appcast.xml" in local_assets:
    publication_content["appcast_sha256"] = local_assets["appcast.xml"][1]
content = json.dumps(
    publication_content,
    sort_keys=True,
    separators=(",", ":"),
).encode()
publication_id = hashlib.sha256(content).hexdigest()

manifest = {
    "schema_version": 1,
    "repository": repository,
    "tag": tag,
    "commit": commit,
    "prerelease": prerelease,
    "release_id": release_id,
    "publication_id": publication_id,
    "assets": manifest_assets,
}
if body_sha256 is not None:
    manifest["title"] = expected_title
    manifest["body_sha256"] = body_sha256
pathlib.Path(output_path).write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
