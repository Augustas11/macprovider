#!/usr/bin/env python3
"""#1750 F-3: pool_setup.py create resumes after a partial failure.

A fake coordinator admin surface (same replay rule as the real one: an
operation id reused with a different body is 409 operation_conflict) and a
fake labtool stand in for the lab stack. Each case fails one create step,
either before the coordinator commits it or after (the client dies before it
records anything), then runs create again and requires an active pool with
the member and buyer, no reused operation id, and pool_id written only at
the end.

  python3 scripts/lab/1690-m6/test_pool_setup_resume.py
"""
import importlib.util
import json
import pathlib
import sys
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent


def load_pool_setup(lab):
    spec = importlib.util.spec_from_file_location("pool_setup_under_test", HERE / "pool_setup.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.LAB = lab
    return mod


class FakeCoordinator:
    def __init__(self, fail_step=None, commit_then_fail=False):
        self.pools = {}
        self.ops = {}
        self.fail_step = fail_step
        self.commit_then_fail = commit_then_fail

    def _op(self, op, body):
        raw = json.dumps(body, sort_keys=True)
        seen = self.ops.get(op)
        if seen is not None and seen != raw:
            sys.exit(f"409 operation_conflict {op}")
        self.ops[op] = raw

    def _maybe_fail(self, step, apply):
        if step == self.fail_step:
            self.fail_step = None
            if self.commit_then_fail:
                apply()
            sys.exit(f"injected failure at {step}")
        apply()

    def admin(self, method, path, body=None, expect=(200, 201, 202)):
        if method == "GET" and path.startswith("/admin/trust-pools/pools/"):
            pool = self.pools.get(path.rsplit("/", 1)[1])
            status = 200 if pool else 404
            if status not in expect:
                sys.exit(f"GET {path} -> {status}")
            return status, ({"pool": dict(pool)} if pool else {"error": {"code": "not_found"}})
        self._op(body["operation_id"], body)
        if path == "/admin/trust-pools/root-registration-nonces":
            def apply():
                pass
            self._maybe_fail("nonce", apply)
            return 200, {"root_registration_nonce": {"nonce": "n-" + body["operation_id"], "expires_at_utc": body["expires_at_utc"]}}
        if path.endswith("/promote"):
            pool_id = path.split("/")[-2]
            p = self.pools[pool_id]
            if not (p["manifest_version"] and p["members"] and p["buyer_accounts"]):
                sys.exit("409 promotion_precondition_failed")
            self._maybe_fail("promote", lambda: p.update(lifecycle="active"))
            return 200, {}
        e = body
        p = self.pools.get(e["pool_id"])
        kind = e["event_type"]
        if kind == "pool_created":
            if p is not None:
                sys.exit("400 invalid_event (pool exists)")
            self._maybe_fail(kind, lambda: self.pools.__setitem__(e["pool_id"], {
                "pool_id": e["pool_id"], "lifecycle": "created", "root_issuer_key_id": "", "manifest_version": 0,
                "members": [], "buyer_accounts": []}))
        elif kind == "root_registered":
            if p["root_issuer_key_id"]:
                sys.exit("400 invalid_event (root already registered)")
            self._maybe_fail(kind, lambda: p.update(root_issuer_key_id="root-1"))
        elif kind == "manifest_accepted":
            if p["manifest_version"] >= e["manifest_version"]:
                sys.exit("400 invalid_event (manifest version not increasing)")
            self._maybe_fail(kind, lambda: p.update(manifest_version=e["manifest_version"]))
        elif kind == "member_admitted":
            self._maybe_fail(kind, lambda: p["members"].append(e["provider_id"]))
        elif kind == "buyer_authorized":
            self._maybe_fail(kind, lambda: p["buyer_accounts"].append(e["buyer_account_id"]))
        else:
            sys.exit(f"unexpected event {kind}")
        return 202, {"event": e}


def fake_labtool(*args):
    args = list(args)
    flag = lambda name: args[args.index(name) + 1]
    if args[0] == "pool-keygen":
        out = pathlib.Path(flag("--out"))
        if out.exists():
            raise RuntimeError(f"{out} already exists")
        out.write_text(json.dumps({"pool_id": "POOL" + out.parent.name}))
        return "POOL" + out.parent.name
    pool_id = json.loads(pathlib.Path(flag("--keys")).read_text())["pool_id"]
    if args[0] == "pool-root":
        return json.dumps({"operation_id": flag("--op"), "event_type": "root_registered", "pool_id": pool_id, "nonce": flag("--nonce")})
    if args[0] == "pool-manifest":
        return json.dumps({"operation_id": flag("--op"), "event_type": "manifest_accepted", "pool_id": pool_id,
                           "manifest_version": 1, "manifest_core_digest": "d" * 64})
    raise RuntimeError(args)


STEPS = ["pool_created", "nonce", "root_registered", "manifest_accepted", "member_admitted", "buyer_authorized", "promote"]


class CreateResumes(unittest.TestCase):
    def run_case(self, step, commit_then_fail):
        with tempfile.TemporaryDirectory() as tmp:
            lab = pathlib.Path(tmp)
            mod = load_pool_setup(lab)
            coord = FakeCoordinator(step, commit_then_fail)
            mod.admin, mod.labtool, mod.ensure_creator = coord.admin, fake_labtool, lambda: None
            args = types.SimpleNamespace(name="B", encoding=1, runtime_allowlist="", settlement_mode="enforce", window_seconds=60)
            with self.assertRaises(SystemExit):
                mod.create(args)
            d = lab / "pools" / "B"
            self.assertFalse((d / "pool_id").exists(), "pool_id is written only when the pool is active")
            mod.create(args)
            pool = coord.pools["POOLB"]
            self.assertEqual(pool["lifecycle"], "active")
            self.assertEqual(pool["members"], [mod.PROVIDER])
            self.assertEqual(pool["buyer_accounts"], [mod.BUYER])
            self.assertEqual((d / "pool_id").read_text().strip(), "POOLB")
            self.assertEqual((d / "attempt").read_text().strip(), "2")
            # A third run is a no-op.
            before = dict(coord.ops)
            mod.create(args)
            self.assertEqual(coord.ops, before)

    def test_every_step_before_commit(self):
        for step in STEPS:
            with self.subTest(step=step):
                self.run_case(step, commit_then_fail=False)

    def test_every_step_after_commit(self):
        for step in STEPS:
            with self.subTest(step=step):
                self.run_case(step, commit_then_fail=True)


if __name__ == "__main__":
    unittest.main()
