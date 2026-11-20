#!/usr/bin/env python3
"""The buyer-UX conformance suite against a loopback lab serve (#2452 step 3; stdlib only).

usage: buyer_ux_local.py --suite-dir DIR --base http://127.0.0.1:PORT/v1 --model ID
                         --served-model ID --catalog-key KEY --out RECORD.json
                         [--samples 3] [--attempts 6] [--retry-budget 300]

scripts/buyer_ux_conformance.py (SPEC-023 §16.11) is the suite. Every record in
phase3-binary/catalog/autotune/buyer-ux-conformance.json was taken through the production
gateway after the key's release (zai-org/glm-5.3-flash-uncensored on 2026-11-09 included;
the MiniMax abliterated row has no record), and its `run` command refuses a non-https
gateway. This driver runs the same checks (`run_checks`, its retrying transport, its
sampling and capability derivation, unchanged) over loopback HTTP against `serve --no-join`,
whose /v1/chat/completions, /v1/messages and /v1/responses are the provider's own
(LocalAnthropicMessagesAdapter, LocalResponsesAdapter), so tools, the reasoning split and
response_format are checked before the CLI cut. Differences from a gateway run: the
coordinator's capability masking and the gateway's own error answers (context_limit_error
here is the provider's 4xx) are not in the path.

--model is the id the serve answers to (its config `model`); --served-model is the id the
coordinator indexes the record by (the artifact's model id, as every gateway record has),
so the advertised capabilities and the gate use it. The record file has the schema of
buyer-ux-conformance.json (one record under --catalog-key, `gateway` naming the loopback
serve) and is checked with the suite's own `require_promotable`: the base checks and every
capability the served model advertises must pass. The listing gate adds the capabilities #2452
step 3 names whether or not the model id advertises them (advertised_capabilities gives a Qwen
id no `reasoning`, so a <think> leak into content would otherwise pass): LISTING_CAPABILITIES
must all be granted. tool_choice required/named stay informational (not advertised for this
model). It is evidence for the listing, never a gateway record: it is not written into the
catalog file.

Prints one `BUX_CHECK <name> <status> <passed>/<samples> <detail>` line per check, then
`BUX_CAPS {...}` and `BUX_GATE pass` or `BUX_GATE fail <reason>`. Exit 0 when the gate
passes, 1 when it fails, 3 when a check stayed inconclusive (no record written), 2 on bad input.
"""
import argparse
import datetime as dt
import importlib.util
import json
import pathlib
import sys

LISTING_CAPABILITIES = ("base", "tools", "reasoning", "response_format", "messages", "responses")


def load_suite(suite_dir):
    path = pathlib.Path(suite_dir) / "buyer_ux_conformance.py"
    spec = importlib.util.spec_from_file_location("buyer_ux_conformance", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_record(suite, result, served_model, base):
    return {
        "model": served_model,
        "gateway": f"{base} (loopback serve --no-join, not the gateway)",
        "checked_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "checks": result["checks"],
        "capabilities": result["capabilities"],
    }


def run(suite, transport, model, served_model, catalog_key, base, out, samples):
    """(exit code, lines) for one suite run over `transport`; writes the record file on a verdict."""
    result = suite.run_checks(transport, model, samples)
    lines = [f"BUX_CHECK {name} {c['status']} {c['passed']}/{c['samples']} {c['detail']}"
             for name, c in result["checks"].items()]
    inconclusive = sorted(n for n, c in result["checks"].items() if c["status"] == suite.INCONCLUSIVE)
    if inconclusive:
        lines.append(f"BUX_GATE fail inconclusive checks {inconclusive}: no record written")
        return 3, lines
    doc = {"schema_version": suite.SCHEMA, "records": {catalog_key: build_record(suite, result, served_model, base)}}
    path = pathlib.Path(out)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    suite.load_records(path)  # the record validates as the catalog file's would
    lines.append("BUX_CAPS " + json.dumps(result["capabilities"], sort_keys=True))
    try:
        suite.require_promotable(catalog_key, served_model, suite.advertised_capabilities(served_model), path)
    except suite.ConformanceError as err:
        lines.append(f"BUX_GATE fail {err}")
        return 1, lines
    missing = [c for c in LISTING_CAPABILITIES if not result["capabilities"][c]]
    if missing:
        lines.append(f"BUX_GATE fail listing capabilities not granted: {missing}")
        return 1, lines
    lines.append("BUX_GATE pass")
    return 0, lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--suite-dir", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--served-model", required=True)
    ap.add_argument("--catalog-key", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--samples", type=int, default=3)
    ap.add_argument("--attempts", type=int, default=6)
    ap.add_argument("--retry-budget", type=float, default=300.0)
    args = ap.parse_args(argv)
    if not args.base.startswith(("http://127.0.0.1:", "http://localhost:")):
        print("--base must be a loopback http URL", file=sys.stderr)
        return 2
    if args.samples < 1:
        print("--samples must be >= 1", file=sys.stderr)
        return 2
    suite = load_suite(args.suite_dir)
    # A loopback serve takes no key; the suite's transport always sends one.
    transport = suite.retrying_transport(suite.http_transport(args.base, "lab-loopback", timeout=1800.0),
                                         args.attempts, args.retry_budget)
    try:
        rc, lines = run(suite, transport, args.model, args.served_model, args.catalog_key, args.base,
                        args.out, args.samples)
    except (suite.ConformanceError, suite.RetryExhausted, OSError) as err:
        print(f"BUX_GATE fail {type(err).__name__}: {err}")
        return 1
    print("\n".join(lines))
    return rc


if __name__ == "__main__":
    sys.exit(main())
