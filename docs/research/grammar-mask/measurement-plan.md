# Grammar-mask measurement plan

Related: #2107. Hardware measurements are deferred by the operator. This is a
plan, not new qualification or evidence of live capability. Run only on the
designated Studio after host identity is verified; no model loads or benchmarks
are authorized by this document alone. Use the existing isolated lab window,
with an unreleased candidate isolated by `--no-join`. Never connect that binary
to Malibu or replace the live provider.

Existing evidence to inspect before scheduling a run:

- `docs/evidence/glm53-flash-t4-2026-10-17/final-mtp/e2e-20261017T103928Z/mtp-e2e.json`
- `docs/evidence/glm53-flash-t4-2026-10-17/final-mtp/journey-20261017T135947Z/mtp-journey.json`
- `docs/evidence/glm53-flash-mtp-gateway-eligibility-2026-10-19/`

Those artifacts establish their recorded tuple only. The changed decode path
is `ContinuousBatchRowSampler.sample`: per-row `grammarConstraint.mask(logits:)`
now precedes penalties and sampling, and its accepting state controls EOS.
Serial generation receives the same request-local constraint. Constrained rows
are excluded from native MTP. This change justifies grammar correctness and
same-row-count end-to-end comparison, not rerunning unrelated qualification.

Use an already-built lab candidate and frozen fixtures; substitute the existing
absolute paths in these environment variables. Keep outputs outside the repo.
No kernel microbenchmark can decide this campaign.

```bash
"$CLI" msb-throughput --model "$MODEL" --engine scheduler --rows 2 \
  --prompt-tokens 1536 --decode-tokens 512 --runs 5 --output "$OUT/cb-s2.json"
"$CLI" msb-throughput --model "$MODEL" --engine scheduler --scenario parity \
  --rows 2 --prompt-tokens 1536 --decode-tokens 512 --parity-tokens 512 \
  --runs 5 --output "$OUT/cb-s2-parity.json"
MACPROVIDER_NATIVE_MTP_E2E=1 "$CLI" native-mtp-bench \
  --root "$FIXTURE_ROOT" --model-id "$MODEL" --policy "$FROZEN_POLICY" \
  --provider-commit "$COMMIT" --out "$OUT/r015.jsonl"
python3 scripts/native_mtp_r015_analyze.py "$OUT/r015.jsonl" "$FROZEN_POLICY"
```

These existing harnesses measure ordinary CB and native-versus-ordinary R015
cells; they do not exercise tool grammar requests. Report output tokens/s,
acceptance, TTFT and token parity at equal row counts from R015. Do not label
the CB harness a grammar throughput measurement. For actual grammar serving,
use the existing buyer conformance entry point against an isolated local
coordinator/gateway and candidate provider, with a lab-only buyer credential:

```bash
python3 scripts/buyer_ux_conformance.py run --gateway "$LAB_GATEWAY/v1" \
  --key-file "$LAB_BUYER_KEY_FILE" --model "$MODEL" --catalog-key "$CATALOG_KEY" \
  --record "$OUT/buyer-ux.json"
python3 scripts/buyer_ux_conformance.py check --catalog-key "$CATALOG_KEY" \
  --model-id "$MODEL" --record "$OUT/buyer-ux.json"
```

Repeat conformance per template family with the exact loaded model identity.
Require valid declared function/arguments in required and named streaming and
non-streaming replies, none without calls, valid tool-result round trips,
bounded 400 compiler rejection, no constrained native-MTP dispatch, and row
isolation. The existing conformance command is a correctness gate; it does not
report end-to-end token throughput or prove real Malibu routing, billing or
settlement. The inline GLM procedure below supplies the request/timing capture for a later
authorized constrained-throughput measurement; do not claim a speed gain until
those paired measurements exist. No catalog/feed changes or live
activation follow from a passing local run.

## Exact GLM-5.3-Flash mask comparison

The catalog's actual loaded identity is `Jundot/GLM-5.3-Flash-oQ4e-mtp`
(`AutotuneCatalog.generated.swift`, catalog key `zai-org/glm-5.3-flash`). Do not
substitute an invented `mlx-community` identity. Freeze baseline `9f8491b34`
and the candidate commit and record both binary hashes. Use already-built
binaries, the same local snapshot, same CB max-batch, same prompt, temperature,
max_tokens and request concurrency. Run the two binaries **sequentially**;
mask-off is the baseline source, not a runtime kill switch. There is no model
load or performance run in this task. In a later authorized Studio window:

```bash
export MODEL=Jundot/GLM-5.3-Flash-oQ4e-mtp
export ROWS=2
export BASE=http://127.0.0.1:18191/v1
# Set CLI to baseline first, then candidate; set LABEL=baseline or candidate.
# MODEL_SNAPSHOT is the already-installed exact catalog-pinned snapshot.
"$CLI" serve --no-join --autotune-candidate --model "$MODEL" \
  --model-artifact-path "$MODEL_SNAPSHOT" --port 18191 --max-batch "$ROWS"
```

Keep that foreground lab-only process in its own terminal. Verify its executable
identity and readiness; never stop or restart the buyer-serving process. Run the
following inline capture from the campaign source root in a second terminal,
then stop only that foreground lab process before launching the other binary.
Use identical commands for both. Run one untimed warmup per mode before capture,
then five capture rounds. All requests in a round begin together. TTFT here is
**buyer-visible first generated delta**, including required/named holdback;
it is not internal first decode latency. Throughput is aggregate completion
tokens divided by round wall time including prefill/holdback. Stream usage is
required; missing usage produces null throughput and an invalid measurement.

```bash
export LABEL=baseline # change to candidate for the second source revision
python3 - <<'PY' > "$OUT/$LABEL-mask.json"
import concurrent.futures, json, os, statistics, threading, time
import urllib.error, urllib.request
from scripts import buyer_ux_conformance as b
base, model, rows = os.environ['BASE'], os.environ['MODEL'], int(os.environ['ROWS'])
# Local no-join provider: no real buyer credential is sent to loopback.
transport = b.http_transport(base, 'lab-only')
conformance = b.run_checks(transport, model)

def request(mode, barrier=None):
    choice = {'type':'function','function':{'name':'read_file'}} if mode == 'named' else mode
    body = {'model':model,'messages':[{'role':'user','content':b.TOOL_PROMPT}],
            'tools':[b.TOOL],'tool_choice':choice,'parallel_tool_calls':False,
            'max_tokens':1024,'temperature':0,'stream':True,
            'stream_options':{'include_usage':True}}
    req = urllib.request.Request(base+'/chat/completions', data=json.dumps(body).encode(),
                                 headers={'Content-Type':'application/json','Authorization':'Bearer lab-only'})
    if barrier: barrier.wait()
    start=time.perf_counter(); first=None; calls={}; finish=None; tokens=None
    try:
        with urllib.request.urlopen(req, timeout=600) as response:
            for raw in response:
                if not raw.startswith(b'data:'): continue
                data=raw[5:].strip()
                if data == b'[DONE]': continue
                event=json.loads(data)
                if event.get('usage'): tokens=event['usage'].get('completion_tokens')
                for choice_event in event.get('choices', []):
                    delta=choice_event.get('delta') or {}
                    if first is None and any(delta.get(k) for k in ('content','reasoning_content','tool_calls')):
                        first=time.perf_counter()-start
                    finish=choice_event.get('finish_reason') or finish
                    for call in delta.get('tool_calls', []):
                        item=calls.setdefault(call.get('index',0), {'type':'function','function':{'name':'','arguments':''}})
                        fn=call.get('function') or {}
                        for key in ('name','arguments'): item['function'][key]+=fn.get(key) or ''
        problem=b._tool_calls_ok({'finish_reason':finish,'message':{'tool_calls':list(calls.values())}})
        if problem is None:
            if len(calls) != 1 or any(not isinstance(json.loads(c['function']['arguments']).get('path'),str) for c in calls.values()):
                problem='expected exactly one call with a required string path'
        return {'status':200,'ttft_s':first,'seconds':time.perf_counter()-start,
                'completion_tokens':tokens,'parsed':problem is None,'parse_error':problem}
    except urllib.error.HTTPError as error:
        detail=json.loads(error.read())
        code=(detail.get('error') or {}).get('code')
        return {'status':error.code,'code':code,'unsupported':code=='unsupported_tool_choice'}

results=[]
for mode in ('auto','required','named'):
    request(mode) # excluded warmup
    for repeat in range(5):
        barrier=threading.Barrier(rows)
        start=time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=rows) as executor:
            replies=list(executor.map(lambda _:request(mode,barrier), range(rows)))
        seconds=time.perf_counter()-start
        ok=[r for r in replies if r['status']==200]
        complete=len(ok)==rows and all(isinstance(r.get('completion_tokens'),int) for r in ok)
        ttft=[r['ttft_s'] for r in ok if r.get('ttft_s') is not None]
        results.append({'mode':mode,'repeat':repeat,'rows':rows,'wall_s':seconds,
                        'output_tokens_per_second':sum(r['completion_tokens'] for r in ok)/seconds if complete else None,
                        'median_ttft_s':statistics.median(ttft) if ttft else None,
                        'parse_rate':sum(r['parsed'] for r in ok)/len(ok) if ok else None,
                        'success_rate':len(ok)/rows,'measurement_valid':complete,'replies':replies})
print(json.dumps({'label':os.environ['LABEL'],'model':model,'rows':rows,
                  'conformance':conformance,'rounds':results},indent=2))
PY
```

Repeat at ROWS=1 and the same authorized multi-row count
for both binaries, restarting only the isolated lab process with matching
`--max-batch`. Do not run both models concurrently.

Report each mode's median round tok/s, median TTFT, successful-call parse rate,
HTTP errors and conformance checks. Baseline may reject required/named with
`unsupported_tool_choice`: report **unsupported**, not 0% parser accuracy or an
acceptance comparison. Only auto is then comparable across source revisions;
candidate required/named correctness and absolute performance remain measurable.
An auto reply without a call is a failed call probe. Retain raw rounds, usage,
errors and source identities; never compare different row counts or omit failed
rounds. This loopback procedure proves provider behavior and buyer-visible timing,
not live Malibu billing, routing or activation.
