# Two-Mac model split over Tailscale (issue #2417 test)

This folder runs a one-session test: one model, split in two parts, served by
two Macs at two different places. The model is too large for either Mac
alone. The operator's Mac runs the first part (the head). Your Mac runs the
second part (the member). The head sends a fixed set of test prompts and
measures speed. That is all.

MacProvider is open source software for Mac owners. This test is an unpaid
experiment. There is no account, no token, no payment and no sign-up. Your Mac
does not join the MacProvider network and serves no one else.

## What the test shows

The model is `mlx-community/Llama-3.3-70B-Instruct-4bit`: 80 layers, 39.7 GB
of files. A 32 GB Mac cannot hold it. With a 32 GB head and a 32 GB member,
each Mac holds about half, and the two together answer the prompts. If that
works, two Macs served a model that neither could serve alone.

Both scripts print whether each Mac could hold the whole model alone, using
the CLI's own memory rule. `head.sh` writes `fits_alone_head`,
`fits_alone_member` and `neither_alone` into `results.json`. With a 64 GB
member, the member could hold the model alone, and the results say so: such a
run still tests the link, but not "neither alone".

Speed is unknown until it is measured. The link between the two Macs adds a
round trip for every generated token, so expect it to be slower than one Mac
that holds the whole model. The test exists to measure that.

## What you need

- A Mac with Apple Silicon (M1 or later), macOS 14 or later.
- 32 GB of memory or more. During the test your Mac's part needs about 22.5 GiB
  of free memory (its weights, its share of the cache and a margin). Quit
  large apps first. The script checks free memory before it loads and stops
  with a message if there is not enough; it never relies on swap.
- Free disk for your part of the model: about 24 GB with a 32 GB head (the
  script prints the exact amount and checks it).
- Tailscale installed and signed in on that Mac.
- `git` (macOS offers to install it the first time you type `git`). Without
  git, download the repository ZIP from GitHub ("Code", "Download ZIP"), unzip
  it, and run the same `bash .../scripts/lab/shard-poc/member.sh` line from it.

## Tailscale sharing

In the Tailscale admin console, open Machines, pick your Mac, choose
"Share...", and send the invite link to the operator. The operator's account
can then reach that one Mac only, not the rest of your tailnet, and you can
remove the share at any time.

The operator sends you the head Mac's Tailscale address (it starts with `100.`).

## The one command

```bash
git clone -b lab/2417-cross-owner-shard-poc https://github.com/Augustas11/macprovider.git
bash macprovider/scripts/lab/shard-poc/member.sh --peer <head address>
```

If the operator says the head Mac does not have 32 GB, add
`--head-memory-gb <N>` with the number they give you.

Keep the Terminal window open until the operator says the test is done.

## What you will see

1. Checks of your Mac (chip, macOS, memory, disk, Tailscale address), and one
   line that says whether your Mac could hold the whole model alone.
2. The split: which layers your Mac serves, worked out from the two Macs'
   memory, with the memory numbers. A line starting `tell the operator:`
   gives your Mac's memory and layers; send that line to the operator.
3. A download of the public `macprovider-cli` release from GitHub (about
   116 MB). The script checks its signature and checksum the same way the
   public installer does.
4. A download of only the model files your layers need, from HuggingFace:
   about 24 GB of the 39.7 GB with a 32 GB head and a 32 GB member (the
   script prints the exact size and file names). At 100 Mbit/s that takes
   about 32 minutes, at 1 Gbit/s about 4 minutes. An interrupted download
   resumes when you run the command again.
5. A check of every downloaded file's SHA-256 against the list pinned in
   `common.sh` (about a minute per 10 GB).
6. A box that says `RUNNING`: your Mac's part is loaded and waits for the
   head. Before that box, the CLI checks every file again and loads your
   part; that takes a minute or a few. After that, lines appear when the
   head connects.

The test itself takes a few minutes.

Everything goes into `~/shard-poc`. If MacProvider or Malibu is already
installed on your Mac, the script leaves it alone and uses its own folder,
config and ports (18191 and 47101). Do not add files to the model folder:
the CLI refuses any file that is not part of the model.

## How the model is checked

This model is not in MacProvider's signed catalog. The script pins it
instead: the HuggingFace revision, and the size and SHA-256 of every file
(from HuggingFace's own file metadata). From that list it writes the
snapshot manifest, and the CLI checks each file your Mac holds against that
manifest before it loads (`snapshot_manifest`, SPEC-051-R008). The run log
says which check was used.

## Stop and clean up

- Stop: press Ctrl-C in the Terminal window.
- Remove everything the test created: `bash macprovider/scripts/lab/shard-poc/member.sh --cleanup`
  then delete the `macprovider` folder you cloned, and remove the Tailscale share.

## The log

The script writes a log to `~/shard-poc/member/member-<date>.log` and, when it
stops, a copy with your Tailscale addresses and home folder path removed:
`member-<date>.share.log`. Please attach the `.share.log` file to issue #2417.

## What is shared and what is not

- Your Mac only sees fixed prompts: the test prompts in `prompts.json` in this
  folder and one short startup probe built into the CLI. No other prompts are sent.
- Your Mac computes on the model's hidden states for those prompts. Someone who
  runs the member part can reconstruct the prompts from those hidden states.
  That is why only fixed, public test prompts are used.
- The link between the two Macs is not encrypted by the CLI, and in this test
  mode the CLI does not check which Mac connects to yours. Frames carry an
  HMAC, which detects changes but hides nothing. Tailscale encrypts the link and
  limits who can reach your Mac. That is why the script refuses to listen on
  anything but your Tailscale address.
- The script sends nothing anywhere else. It reads from GitHub and HuggingFace
  only to download the CLI and the model.

## For the operator (head side)

```bash
bash scripts/lab/shard-poc/head.sh --member <member address> --member-memory-gb <N>   # the two-Mac test
bash scripts/lab/shard-poc/head.sh --baseline                  # same model, this Mac alone (skipped if it does not fit)
bash scripts/lab/shard-poc/head.sh --rehearse                  # head and member on this Mac
bash scripts/lab/shard-poc/head.sh --cleanup
```

`--member-memory-gb` is the number from the member's `tell the operator:`
line. Both scripts compute the split from the two memory sizes with the same
rule, so they agree; `--split N` (head) and `--layers N:80` (member)
override it, and must match.

The split follows the CLI's own rules: layers in proportion to each Mac's
memory less the 4 GiB reserve (`ShardPlacementPlanner`), then each part is
checked with the rule `serve` applies before it loads a part (stage weights,
KV demand, KV budget in `ShardStageArtifact.fit`). Defaults are 4 requests in
flight and 4096 tokens each. For a 32 GB + 32 GB pair:

| part | layers | weights | KV demand | KV budget | download |
|---|---|---|---|---|---|
| head | 0:41 | 18.9 GiB | 2.6 GiB | 6.8 GiB | 21.2 GB |
| member | 41:80 | 18.0 GiB | 2.4 GiB | 7.5 GiB | 23.8 GB |

For 32 GB + 64 GB the split is 0:26 and 26:80 (head downloads 15.9 GB,
member 29.1 GB), and the 64 GB member could hold the model alone.

Memory on the head: the head Mac usually has its live provider's model
loaded. `head.sh` checks free memory against its part's need (weights, KV and
a 2 GiB margin, about 23.5 GiB on a 32 GB head) and stops with a message if it
is short. It never stops, pauses or restarts the provider; freeing that
memory is the operator's call.

Both scripts warn when a part needs more than 60% of a Mac's memory. The CLI
limits MLX to 90% of the GPU memory macOS allows, and that is below total
memory. Whether a 32 GB Mac loads and runs its half at full speed under that
limit has not been measured yet.

`--baseline` runs the whole model on the head alone. When it does not fit
(any 32 GB Mac), it says so, writes the reason to `results.json` and stops;
it does not load the model into swap.

`--rehearse` needs memory and disk for both parts on one Mac: about 46 GiB
free memory and 45 GB disk for the 70B model, so a 64 GB Mac or larger. A
32 GB Mac cannot rehearse the 70B model.

`--model small` (both sides) uses `mlx-community/Llama-3.2-3B-Instruct-4bit`
(1.8 GB, checked against the signed catalog hash). Any Mac runs it alone, so
it is a quick link check only and does not test the aim.

`head.sh` prints a markdown table (total tok/s, per-request tok/s, TTFT at 1,
2 and 4 requests in flight) and writes `results.json` under
`~/shard-poc/results/`. Neither script pauses, stops or restarts any running
provider; on a Mac that serves live traffic, book the GPU first.

The link round trip in the table is an ICMP ping over Tailscale, plus the
`tailscale ping` path (direct or relayed). The CLI measures the stage link's
own round trip but, in this `--no-join` mode, reports it only to a coordinator.

Link supervision defaults are set for an internet link: heartbeat 250 ms x 8
misses (2 s) and a 1500 ms decode-hop deadline (cable defaults: 100 ms x 3,
500 ms). Change them with `--heartbeat-ms`, `--heartbeat-misses`,
`--decode-hop-ms`, `--prefill-chunk-ms` and `--replay-ms`; both sides must use
the same values, and so must `--model`, `--max-sequences` and `--max-context`.
