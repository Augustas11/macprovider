#!/usr/bin/env python3
"""Rank OpenRouter demand rows by (payout x MLX-servability), review-only.

Non-money-path operator tool. It reads a committed OpenRouter pricing snapshot,
takes the demand rows NOT already in the pricing policy, and for each asks
HuggingFace whether a fleet-fitting MLX text-generation build exists. It emits a
review-only candidate list so additions are driven by real market payout and
MLX-servability, not a hand-curated allowlist.

It has NO apply mode. It never writes the pricing policy or the rate card, and
it refuses --output targets that would overwrite an input or a money-path file.
A candidate here is a proposal for human verification; the money-path apply stays
with Component 3.

Fail-closed like the pricing fetcher: any network error, schema drift, missing
size, loose identity match, or unconfirmable serving path yields "unresolved" (a
human check) or "not_servable" (positively disqualified) -- never a false
"servable". Heuristic evidence (name match, architecture suffix, weight bytes)
never yields a clean "servable" on its own: a null-pipeline causal-LM build is
downgraded to "review", and residency is gated with a conservative runtime
headroom rather than raw weight bytes.

Verdicts (the strongest positive outcome is a review CANDIDATE -- HF metadata
cannot certify servability, only loading on hardware can, so the tool nominates
and a human confirms the serving path before Component 3 prices it):
  review        canonical MLX build fits the band and is plausibly a text model;
                a human must confirm the serving path before pricing.
  not_servable  no MLX build / oversized / closed-weight / wrong modality (ASR).
  unresolved    a build exists and fits, but text-servability or identity could
                not be positively confirmed (ambiguous match, adapter/LoRA-only,
                multimodal architecture, unrecognised quant, or a fetch failure).
  skipped       no paid OpenRouter payout, so no undercut market to price against.

The network layer is an injectable ``client`` callable (url -> parsed JSON) so
the core is deterministic and unit-testable offline.
"""

from __future__ import annotations

import argparse
import http.client
import json
import math
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Callable

HF_API = "https://huggingface.co/api/models"
MLX_NAMESPACE = "mlx-community"
Client = Callable[[str], object]

# Vendors whose flagship rows are closed-weight API models with no possible
# local build. Every other vendor is probed and fails closed if no build exists,
# so open-weight lines from mixed vendors (openai/gpt-oss, google/gemma) are not
# pre-excluded here -- only the fully-closed houses are.
CLOSED_WEIGHT_VENDORS = frozenset({"anthropic", "x-ai"})
# MLX-loadable text quant tags, in fleet preference order.
MLX_QUANT_TAGS = ("4bit", "mxfp4", "5bit", "6bit", "8bit")
# Repo-name tokens that mark a repo as NOT the canonical base model -- reject it
# entirely rather than price a re-headed or partial derivative.
DISQUALIFYING_TOKENS = frozenset({"lora", "adapter", "merge", "draft", "abliterated", "uncensored", "heretic"})
# ALLOWLIST: repo-name tokens (after the model stem) that are recognised as pure
# packaging/quantization/canonical-variant metadata. A clean "servable" verdict
# requires EVERY residual token to be recognised here (or a numeric/size/version
# token). Any unrecognised token means the build is an unknown derivative, not
# provably the canonical model, so it is downgraded to review. This is a positive
# allowlist by design: a denylist cannot prove an unknown suffix is canonical.
PACKAGING_TOKENS = frozenset({
    "4bit", "5bit", "6bit", "8bit", "3bit", "2bit", "mxfp4", "nvfp4", "mixed",
    "bf16", "fp16", "fp32", "f16", "f32", "q4", "q5", "q6", "q8", "dwq", "gs",
    "it", "instruct", "chat", "mlx", "hf", "text",
})
TEXT_PIPELINE_TAGS = frozenset({"text-generation"})
# Multimodal tags that DO emit text but are not a pure text serving path.
VISION_TEXT_PIPELINE_TAGS = frozenset({"image-text-to-text", "any-to-any"})
# Architecture / model-type substrings that mark a multimodal (non-text-only)
# model even when the class name ends in ForCausalLM (e.g. LlavaLlamaForCausalLM,
# FuyuForCausalLM). A match here refuses the causal-LM text fallback.
MULTIMODAL_ARCH_MARKERS = frozenset({"llava", "fuyu", "vision", "clip", "whisper", "audio", "speech", "mllama", "idefics", "pixtral", "molmo", "aria"})
# Compound architecture suffixes that mark a multimodal model even when the class
# name ends in ForCausalLM and carries no name marker (e.g. Qwen2VLForCausalLM,
# ...OmniForCausalLM, ...AudioForCausalLM).
MULTIMODAL_ARCH_PATTERNS = ("vlfor", "omnifor", "audiofor", "visionfor", "speechfor", "imagefor")
CAUSAL_LM_ARCH_SUFFIX = "forcausallm"
# Conservative multiplier over safetensors weight bytes to cover loader,
# activation, and KV-cache residency (weight bytes are file size, not runtime RAM).
RESIDENCY_OVERHEAD = Decimal("1.3")


class ResolveError(Exception):
    """Fail-closed condition while resolving a single candidate row."""


def real_client(timeout: float) -> Client:
    def fetch(url: str) -> object:
        request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "macprovider-mlx-candidates"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status != 200:
                    raise ResolveError(f"HuggingFace returned HTTP {response.status}")
                payload = response.read()
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError) as error:
            raise ResolveError(f"HuggingFace request failed: {error}") from error
        try:
            return json.loads(payload)
        except json.JSONDecodeError as error:
            raise ResolveError(f"HuggingFace response was not valid JSON: {error}") from error
    return fetch


def model_stem(source_model_id: str) -> str:
    """The model portion of an OpenRouter slug, minus any :free/:batch variant."""
    tail = source_model_id.split("/", 1)[-1]
    return tail.split(":", 1)[0]


def repo_owner(repo_id: str) -> str:
    return repo_id.split("/", 1)[0] if "/" in repo_id else ""


def repo_name(repo_id: str) -> str:
    return repo_id.split("/", 1)[-1]


def anchored_match(name: str, stem: str) -> bool:
    """True only if name begins with the complete stem at a token boundary.

    'gemma-4-31b-it' matches 'gemma-4-31b-it-4bit' but not 'other-gemma-4-31b-it-4bit'
    (prefixed different model) nor 'gemma-4-31b-it2' (different suffix). An anchored
    prefix match is required so a repository whose name merely CONTAINS the stem
    cannot be mistaken for the model; ambiguous/prefixed names fail closed.
    """
    lowered_name = name.lower()
    lowered_stem = stem.lower()
    if not lowered_name.startswith(lowered_stem):
        return False
    after = lowered_name[len(lowered_stem)] if len(lowered_name) > len(lowered_stem) else ""
    # The stem must be followed by a repo separator or end of name. A version
    # continuation like '.' (glm-5 vs glm-5.2) or an alphanumeric (glm-5 vs
    # glm-50b) is a DIFFERENT model and must not alias.
    return after in ("", "-", "_")


def quant_of(repo_id: str) -> str | None:
    # Match a quant tag only as a whole hyphen/underscore-delimited token, so
    # 'foo-14bit' or 'foo-4bitten' are NOT read as a '4bit' build.
    tokens = set(re.split(r"[^0-9a-z]+", repo_id.lower()))
    for tag in MLX_QUANT_TAGS:
        if tag in tokens:
            return tag
    return None


def is_protected_component(target: Path) -> bool:
    """True if any path component names a rate-card file/dir, case/underscore-insensitively."""
    return any("rate-card" in component.casefold().replace("_", "-") for component in target.parts)


def validated_residency(raw: str) -> Decimal:
    """Parse --max-residency-gb, rejecting non-finite or non-positive ceilings.

    Infinity would pass every model; NaN would raise mid-comparison. Both must be
    rejected before any classification runs.
    """
    try:
        value = Decimal(str(raw))
    except InvalidOperation as error:
        raise SystemExit(f"--max-residency-gb must be a number: {raw!r}") from error
    if not value.is_finite() or value <= 0:
        raise SystemExit(f"--max-residency-gb must be a finite positive number: {raw!r}")
    return value


def search_builds(stem: str, client: Client) -> list[dict]:
    query = urllib.parse.urlencode({"author": MLX_NAMESPACE, "search": stem, "limit": "30"})
    result = client(f"{HF_API}?{query}")
    if not isinstance(result, list):
        raise ResolveError("HuggingFace search response was not a list")
    return [item for item in result if isinstance(item, dict)]


def _is_packaging_token(token: str) -> bool:
    """True for recognised packaging/quant/size/version tokens (allowlist)."""
    if token in PACKAGING_TOKENS:
        return True
    if token.isdigit():  # date/version like 2407, or a bare number
        return True
    if re.fullmatch(r"v?\d+(\.\d+)*", token):  # v0.1, 3.1, v2
        return True
    if re.fullmatch(r"\d+(\.\d+)?[bmk]", token):  # 7b, 30b, 3.6b, 500m sizes
        return True
    return False


def unrecognised_suffix_tokens(name: str, stem: str) -> list[str]:
    """Residual repo-name tokens after the stem that are NOT recognised packaging.

    Empty means the suffix is pure packaging/quant/version metadata and the build
    is provably the canonical model. Any element means an unknown derivative
    ('...-math-...', '...-coder-...', '...-base-...') -- never a clean servable.
    """
    residual = (token for token in re.split(r"[^0-9a-z]+", name.lower()[len(stem.lower()):]) if token)
    return [token for token in residual if not _is_packaging_token(token)]


def pick_canonical_build(builds: list[dict], stem: str) -> tuple[dict | None, bool]:
    """Choose the most canonical fleet-quant build, or None with a matched flag.

    Requires the mlx-community namespace and an anchored (prefix) identity match,
    rejects adapter/LoRA/merge/modified derivatives outright, and orders the rest
    by fewest variant tokens, then fleet quant preference, then shortest name.
    Records the selected build's variant tokens so a variant-only match is never
    reported as a clean canonical "servable". Returns (picked_or_None, matched_any)
    so the caller can distinguish "no build at all" from "matched but nothing usable".
    """
    matched_any = False
    scored: list[tuple] = []
    for item in builds:
        repo_id = item.get("modelId") or item.get("id") or ""
        if not isinstance(repo_id, str) or repo_owner(repo_id).lower() != MLX_NAMESPACE:
            continue
        name = repo_name(repo_id).lower()
        if not anchored_match(name, stem):
            continue
        matched_any = True
        if any(token in name for token in DISQUALIFYING_TOKENS):
            continue
        quant = quant_of(repo_id)
        if quant is None:
            continue
        variant = unrecognised_suffix_tokens(name, stem)
        scored.append((len(variant), MLX_QUANT_TAGS.index(quant), len(name), repo_id, quant, item.get("pipeline_tag"), variant))
    if not scored:
        return None, matched_any
    scored.sort()
    _, _, _, repo_id, quant, list_pipeline_tag, variant = scored[0]
    return {"repo": repo_id, "quant": quant, "list_pipeline_tag": list_pipeline_tag, "variant_tokens": variant}, matched_any


def build_residency_and_pipeline(repo_id: str, client: Client) -> tuple[Decimal, str | None, dict | None]:
    detail = client(f"{HF_API}/{repo_id}?{urllib.parse.urlencode({'blobs': 'true'})}")
    if not isinstance(detail, dict):
        raise ResolveError(f"{repo_id}: detail response was not an object")
    siblings = detail.get("siblings")
    if not isinstance(siblings, list) or not siblings:
        raise ResolveError(f"{repo_id}: no file listing")
    filenames = [s.get("rfilename") for s in siblings if isinstance(s, dict)]
    if any(name == "adapter_config.json" for name in filenames if isinstance(name, str)):
        raise ResolveError(f"{repo_id}: PEFT/LoRA adapter repository (adapter_config.json present), not a base checkpoint")
    weight_bytes = 0
    saw_full_checkpoint = False
    for sibling in siblings:
        if not isinstance(sibling, dict):
            raise ResolveError(f"{repo_id}: malformed file entry")
        name = sibling.get("rfilename")
        if not isinstance(name, str):
            raise ResolveError(f"{repo_id}: malformed file name")
        if name.endswith(".safetensors"):
            size = sibling.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                raise ResolveError(f"{repo_id}: missing or invalid safetensors size (fail closed)")
            if "adapter" in name.lower():
                continue  # adapter shard, not a full checkpoint -- do not count it
            saw_full_checkpoint = True
            weight_bytes += size
    if not saw_full_checkpoint or weight_bytes <= 0:
        raise ResolveError(f"{repo_id}: no complete (non-adapter) safetensors checkpoint")
    pipeline_tag = detail.get("pipeline_tag")
    if pipeline_tag is not None and not isinstance(pipeline_tag, str):
        raise ResolveError(f"{repo_id}: pipeline_tag is not a string")
    config = detail.get("config")
    return Decimal(weight_bytes) / Decimal(10 ** 9), pipeline_tag, config if isinstance(config, dict) else None


def _arch_blob(config: dict | None) -> str:
    architectures = (config or {}).get("architectures")
    parts = [arch for arch in architectures if isinstance(arch, str)] if isinstance(architectures, list) else []
    model_type = (config or {}).get("model_type")
    if isinstance(model_type, str):
        parts.append(model_type)
    return " ".join(parts).lower()


def is_multimodal_arch(config: dict | None) -> bool:
    blob = _arch_blob(config)
    if any(marker in blob for marker in MULTIMODAL_ARCH_MARKERS):
        return True
    return any(pattern in blob for pattern in MULTIMODAL_ARCH_PATTERNS)


def is_causal_lm(config: dict | None) -> bool:
    architectures = (config or {}).get("architectures")
    if not isinstance(architectures, list):
        return False
    return any(isinstance(arch, str) and arch.lower().endswith(CAUSAL_LM_ARCH_SUFFIX) for arch in architectures)


def classify(repo_id: str, quant: str | None, residency_gb: Decimal, pipeline_tag: str | None, config: dict | None, max_residency: Decimal, variant_tokens: list[str] | tuple = ()) -> dict:
    required_gb = residency_gb * RESIDENCY_OVERHEAD
    evidence = {"mlx_repo": repo_id, "quant": quant, "residency_gb": f"{residency_gb:.1f}", "required_gb": f"{required_gb:.1f}", "pipeline_tag": pipeline_tag}
    architectures = (config or {}).get("architectures")
    if required_gb > max_residency:
        return {**evidence, "verdict": "not_servable", "reasons": [f"conservative runtime residency {required_gb:.1f} GB (weights {residency_gb:.1f} GB x {RESIDENCY_OVERHEAD} headroom) exceeds the {max_residency} GB fleet band"]}
    # Architecture evidence VETOES a clean text verdict: a multimodal-shaped
    # architecture conflicts with a text-only serving path even when the HF
    # pipeline_tag claims text-generation (stale/mistagged repositories exist).
    if is_multimodal_arch(config):
        return {**evidence, "verdict": "unresolved", "reasons": [f"config architecture {architectures} is multimodal-shaped and conflicts with any text-only serving path (pipeline_tag {pipeline_tag!r})"]}
    # The strongest positive verdict this tool emits is "review": HuggingFace
    # metadata cannot PROVE a build serves text on the fleet (only loading it on
    # hardware can), so a build that fits and is plausibly a text model is
    # nominated as a review candidate for a human to confirm the serving path
    # before Component 3 prices it. There is deliberately no "servable" verdict --
    # that removes any path to a false clean claim from remote metadata.
    has_arch_metadata = isinstance(architectures, list) and any(isinstance(arch, str) for arch in architectures)
    if pipeline_tag in TEXT_PIPELINE_TAGS:
        if has_arch_metadata and not is_causal_lm(config):
            return {**evidence, "verdict": "unresolved", "reasons": [f"pipeline_tag text-generation but config architecture {architectures} is not a recognised causal-LM text form; cannot confirm a text-only serving path"]}
        reason = "mlx-community text-generation build fits the fleet residency band; confirm the serving path before pricing"
    elif pipeline_tag in VISION_TEXT_PIPELINE_TAGS:
        # A vision-language pipeline is not positive evidence of a text-only serving
        # path, so it is not nominated as a review candidate: it is unresolved,
        # visible in the audit trail for a human to investigate a text-tower path.
        return {**evidence, "verdict": "unresolved", "reasons": [f"pipeline_tag {pipeline_tag!r} is a vision-language pipeline, not a confirmed text-only serving path"]}
    elif pipeline_tag is None and is_causal_lm(config):
        reason = f"no HF pipeline_tag; config architecture {architectures} is a causal LM; confirm the text-only serving path before pricing"
    elif pipeline_tag is None:
        return {**evidence, "verdict": "unresolved", "reasons": ["no pipeline_tag and no causal-LM architecture in config; cannot confirm the text serving path"]}
    else:
        return {**evidence, "verdict": "not_servable", "reasons": [f"pipeline_tag {pipeline_tag!r} is not a text-generation serving path"]}
    # A build reachable only through a non-canonical variant repo (unrecognised
    # suffix tokens) is a different derivative -- keep it a review candidate but
    # flag the identity question explicitly.
    if variant_tokens:
        reason = f"candidate via a non-canonical variant repo (unrecognised tokens {list(variant_tokens)}); confirm base-model identity AND the serving path before pricing"
    return {**evidence, "verdict": "review", "reasons": [reason]}


def resolve_row(source_model_id: str, max_residency: Decimal, client: Client) -> dict:
    vendor = source_model_id.split("/", 1)[0].lower()
    if vendor in CLOSED_WEIGHT_VENDORS:
        return {"verdict": "not_servable", "reasons": [f"{vendor} publishes closed-weight API models; no local MLX build is possible"]}
    stem = model_stem(source_model_id)
    builds = search_builds(stem, client)
    picked, matched_any = pick_canonical_build(builds, stem)
    if picked is None:
        if matched_any:
            return {"verdict": "unresolved", "reasons": [f"mlx-community has {stem!r} builds but only adapter/LoRA/merge/modified or unrecognised-quant repositories; none is a canonical fleet build"]}
        return {"verdict": "not_servable", "reasons": [f"no mlx-community build matches {stem!r}"]}
    residency_gb, pipeline_tag, config = build_residency_and_pipeline(picked["repo"], client)
    return classify(picked["repo"], picked["quant"], residency_gb, pipeline_tag, config, max_residency, picked["variant_tokens"])


def payout_decimal(row: dict) -> Decimal:
    pricing = row.get("pricing")
    if isinstance(pricing, dict) and pricing.get("completion_per_mtok") is not None:
        try:
            return Decimal(str(pricing["completion_per_mtok"]))
        except (InvalidOperation, ValueError):
            return Decimal(0)
    return Decimal(0)


def rank_key(candidate: dict) -> tuple:
    payout = Decimal(candidate["payout_completion_per_mtok"])
    rank = candidate.get("demand_rank") or 999
    # Higher payout and stronger demand (lower rank) sort first.
    return (-(payout * (Decimal(1000) / Decimal(rank))), rank)


def build_candidates(snapshot: dict, policy: dict, max_residency: Decimal, client: Client) -> dict:
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("rows"), list):
        raise ResolveError("snapshot must be an object with a rows array")
    if not isinstance(policy, dict) or not isinstance(policy.get("models"), list):
        raise ResolveError("policy must be an object with a models array")
    mapped = {model.get("source_model_id") for model in policy["models"] if isinstance(model, dict)}
    candidates: list[dict] = []
    for row in snapshot["rows"]:
        if not isinstance(row, dict):
            raise ResolveError("snapshot row must be an object")
        source_model_id = row.get("source_model_id")
        if source_model_id in mapped:
            continue
        payout = payout_decimal(row)
        demand = row.get("demand") if isinstance(row.get("demand"), dict) else {}
        record = {"source_model_id": source_model_id, "demand_rank": demand.get("rank"), "payout_completion_per_mtok": str(payout)}
        if payout <= 0:
            record.update({"verdict": "skipped", "reasons": ["no paid completion payout on OpenRouter; no undercut market to price against"]})
        else:
            try:
                record.update(resolve_row(source_model_id, max_residency, client))
            except ResolveError as error:
                record.update({"verdict": "unresolved", "reasons": [str(error)]})
        candidates.append(record)

    candidates.sort(key=lambda c: (c["source_model_id"] or ""))
    buckets = ("review", "not_servable", "unresolved", "skipped")
    summary = {"probed": len(candidates)}
    summary.update({bucket: sum(1 for c in candidates if c["verdict"] == bucket) for bucket in buckets})
    return {
        "schema_version": 1,
        "artifact_type": "openrouter-mlx-candidates",
        "max_residency_gb": str(max_residency),
        "policy_version": policy.get("policy_version"),
        "snapshot_digest": snapshot.get("content_digest"),
        "summary": summary,
        "review": sorted([c for c in candidates if c["verdict"] == "review"], key=rank_key),
        "candidates": candidates,
    }


def render(result: dict) -> str:
    summary = result["summary"]
    lines = [f"probed {summary['probed']} unmapped demand rows -> "
             f"{summary['review']} review candidate(s), {summary['unresolved']} unresolved", ""]
    for c in result["review"]:
        lines.append(f"  REVIEW  rank {str(c['demand_rank']):>3}  ${c['payout_completion_per_mtok']}/Mtok  {c['source_model_id']}")
        lines.append(f"          {c.get('mlx_repo')}  ({c.get('quant')}, {c.get('residency_gb')} GB weights / {c.get('required_gb')} GB required, {c.get('pipeline_tag')})")
        for reason in c["reasons"]:
            lines.append(f"          - {reason}")
    lines.append("\n--- not_servable / unresolved / skipped (audit trail) ---")
    for c in result["candidates"]:
        if c["verdict"] != "review":
            lines.append(f"  {c['verdict']:12} rank {str(c['demand_rank']):>3}  {c['source_model_id']}  :: {c['reasons'][0]}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Rank OpenRouter demand rows by payout x MLX-servability (review-only).")
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--max-residency-gb", default="45", help="fleet residency band ceiling in GB (default 45 = coding/M-Max tier)")
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    parser.add_argument("--output", help="optional path to write the review-only candidate JSON artifact (refuses inputs and money-path files, never overwrites)")
    args = parser.parse_args(argv)

    with open(args.snapshot, encoding="utf-8") as handle:
        snapshot = json.load(handle)
    with open(args.policy, encoding="utf-8") as handle:
        policy = json.load(handle)
    # Operationally, reuse the pricing engine's strict snapshot/policy validators
    # so a malformed or untrusted input cannot reach the servability logic.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import openrouter_pricing_engine as engine
    engine.validate_snapshot(snapshot)
    engine.validate_policy(policy)

    max_residency = validated_residency(args.max_residency_gb)
    timeout = args.timeout_seconds
    if not (isinstance(timeout, (int, float)) and math.isfinite(timeout) and timeout > 0):
        raise SystemExit(f"--timeout-seconds must be a finite positive number: {timeout!r}")
    result = build_candidates(snapshot, policy, max_residency, real_client(timeout))
    print(render(result))
    if args.output:
        target = Path(args.output).resolve()
        protected = {Path(args.snapshot).resolve(), Path(args.policy).resolve()}
        if target in protected or is_protected_component(target):
            raise SystemExit("refusing to write to an input or protected money-path file")
        if target.exists():
            raise SystemExit(f"refusing to overwrite existing file: {target}")
        with open(target, "x", encoding="utf-8") as handle:
            json.dump(result, handle, sort_keys=True, indent=2)
            handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
