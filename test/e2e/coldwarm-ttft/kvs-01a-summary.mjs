#!/usr/bin/env node
/**
 * KVS-01a nearest-rank TTFT summary. Split out of `kvs-01a.sh` so bash 3.2
 * `node -e` argv layout cannot shadow the work-dir argument, and so a throw
 * cannot take down the driver without a message.
 *
 * Usage: kvs-01a-summary.mjs <work-dir> <warm-ratio-p95> <smoke 0|1> <perf-gate 0|1>
 */
import { readFileSync } from 'node:fs';

const work = process.argv[2];
const ratioP95 = Number(process.argv[3]);
const smoke = process.argv[4] === '1';
const perfGate = process.argv[5] === '1';

const read = (arm) => {
  try {
    return readFileSync(`${work}/ttft.${arm}.txt`, 'utf8')
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
      .map(Number)
      .filter(Number.isFinite)
      .sort((a, b) => a - b);
  } catch {
    return [];
  }
};
const nr = (xs, p) =>
  xs.length ? xs[Math.min(xs.length - 1, Math.max(0, Math.ceil((p / 100) * xs.length) - 1))] : null;

const arms = ['restored', 'warm', 'miss', 'disabled'];
const pct = {};
for (const a of arms) {
  const xs = read(a);
  pct[a] = { n: xs.length, p50: nr(xs, 50), p95: nr(xs, 95), min: xs[0] ?? null, max: xs[xs.length - 1] ?? null };
}

process.stderr.write('kvs-01a: nearest-rank TTFT percentiles (ms):\n');
for (const a of arms) {
  const p = pct[a];
  process.stderr.write(
    `  ${a.padEnd(9)} n=${p.n} p50=${p.p50 ?? '-'} p95=${p.p95 ?? '-'} min=${p.min ?? '-'} max=${p.max ?? '-'}\n`,
  );
}
if (smoke) {
  process.stderr.write('kvs-01a: smoke mode — percentile thresholds skipped (correctness only)\n');
  process.exit(0);
}

// MEDIUM-6: warm-relative thresholds are ADVISORY for KVS-01a (~2.5k) — recorded
// and reported, but they only FAIL the run under an explicit perf-gate mode.
let fail = 0;
const r = pct.restored;
const w = pct.warm;
const m = pct.miss;
const d = pct.disabled;
const tag = perfGate ? 'THRESHOLD FAIL' : 'THRESHOLD ADVISORY';
const note = (msg) => {
  process.stderr.write(`kvs-01a: ${tag} ${msg}\n`);
  if (perfGate) fail = 1;
};
if (r.p95 != null && w.p95 != null && r.p95 > w.p95 * ratioP95) {
  note(`restored p95 ${r.p95} > warm p95 ${w.p95} × ${ratioP95}`);
}
if (r.p95 != null && m.p50 != null && !(r.p95 < m.p50)) {
  note(`restored p95 ${r.p95} !< miss p50 ${m.p50}`);
}
if (r.p95 != null && d.p50 != null && !(r.p95 < d.p50)) {
  note(`restored p95 ${r.p95} !< disabled p50 ${d.p50}`);
}
if (!perfGate) {
  process.stderr.write('kvs-01a: percentile thresholds are advisory for KVS-01a (pass --perf-gate to enforce)\n');
}
process.exit(fail);
