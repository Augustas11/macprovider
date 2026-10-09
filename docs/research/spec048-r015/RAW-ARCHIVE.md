# SPEC-048 R015 raw lab data

Raw JSONL, logs and run scripts that earlier READMEs describe as kept "on the
lab host" now live in this repository. The lab host keeps no copies.

| Archive | Contents |
| --- | --- |
| `evidence-2026-10-06-a3b-fused-26a434/raw.tar.gz` | Files listed in that directory's `raw-sha256.txt` |
| `evidence-2026-10-06-a3b-step-overhead-26a434/raw.tar.gz` | Files listed in that directory's `raw-sha256.txt` |
| `evidence-2026-10-06-a3b-amended-gates-quiet-26a434/raw.tar.gz` | Files listed in that directory's `raw-sha256.txt` |
| `evidence-2026-10-06-a3b-amended-gates-quiet-26a434/s2-control/raw.tar.gz` | Files listed in `s2-control/raw-sha256.txt` |
| `evidence-2026-10-06-a3b-amended-gates-quiet-26a434/colcap-control/raw.tar.gz` | Files listed in `colcap-control/raw-sha256.txt` |
| `lab-raw-exploratory-2026-09-30-to-10-03.tar.gz` | Raw runs behind `evidence-2026-10-01/`, `evidence-2026-10-02-a3b-formal/` and `evidence-2026-10-03-a3b-fused-formal/` (directories `mtp-r015-*`) |

Every archived file listed in a `raw-sha256.txt` matches its recorded SHA-256
(`tar -xzf raw.tar.gz && shasum -a 256 -c ../raw-sha256.txt` from an extracted
copy, adjusting relative paths).

Host-operational snapshots (`identity.txt`, `status.txt`, `procs-preflight.txt`,
`live-*.txt`) are not published: they contain provider and host identifiers.
Their digests remain in the `raw-sha256.txt` files.
