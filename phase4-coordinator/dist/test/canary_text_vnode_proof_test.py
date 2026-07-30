#!/usr/bin/env python3
"""Regression tests for both Mac canary running text-vnode proofs."""

from __future__ import annotations

import ast
import os
import pathlib
import subprocess
import types


repo = pathlib.Path(__file__).parents[3]
deploy = repo / "phase4-coordinator/dist/deploy-pearl-vps.sh"
pearl_proof = repo / "ops/pearl-updater/catalog-canary-proof.py"


def load_vnode_function(path: pathlib.Path, source: str):
    tree = ast.parse(source)
    function_node = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "running_text_vnode_path"
    )
    module = ast.Module(body=[function_node], type_ignores=[])
    ast.fix_missing_locations(module)
    namespace = {"os": os, "subprocess": subprocess}
    exec(compile(module, str(path), "exec"), namespace)
    return namespace["running_text_vnode_path"]


deploy_text = deploy.read_text(encoding="utf-8")
start = deploy_text.index("import hashlib, json, os, plistlib, re, stat, subprocess, sys, urllib.request")
end = deploy_text.index("\nPY\n}", start)
implementations = (
    load_vnode_function(deploy, deploy_text[start:end]),
    load_vnode_function(pearl_proof, pearl_proof.read_text(encoding="utf-8")),
)


def runner(output: str):
    def run(*_args, **_kwargs):
        return subprocess.CompletedProcess([], 0, stdout=output, stderr="")

    return run


installed = types.SimpleNamespace(st_dev=0x11, st_ino=42)
path = "/Users/canary/macprovider-cli"

for vnode_path in implementations:
    assert vnode_path(123, installed, path, runner("ftxt\nD0x11\ni42\nn" + path + "\n")) == path

    # Atomic replacement keeps the pathname but changes the live text vnode.
    # Device + inode + path must all identify the inspected installed binary.
    assert vnode_path(123, installed, path, runner("ftxt\nD0x11\ni41\nn" + path + "\n")) is None
    assert vnode_path(123, installed, path, runner("ftxt\nD0x12\ni42\nn" + path + "\n")) is None
    assert vnode_path(123, installed, path, runner("ftxt\nD0x11\ni42\nn/tmp/other\n")) is None

assert "/usr/bin/proc_pidpath" not in deploy_text
assert "/usr/bin/proc_pidpath" not in pearl_proof.read_text(encoding="utf-8")

print("PASS: both Mac canary proofs use lsof device/inode/path and reject stale processes")
